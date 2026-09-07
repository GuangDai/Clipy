import Darwin
import Foundation
import HistoryCore

internal struct ImmutableBlobReference: Sendable, Equatable {
    internal let id: UUID
    internal let byteCount: Int
}

internal struct BlobCleanupBatchResult: Sendable, Equatable {
    internal let removedCount: Int
    /// Both blobs and staging have been visited; no enumerator is retained.
    internal let completedPass: Bool
}

/// Concrete file implementation owned by the sole HistoryAuthority. Calls are
/// synchronous: publication/reference commits and cleanup cannot interleave.
/// V2-09 §§3/5/6: random identity, immutable files, database references last.
internal final class ImmutableBlobStore {
    private let root: URL
    private let synchronize: (Int32, Bool) throws -> Void
    private let files = FileManager()
    private var cleanupEnumerator: FileManager.DirectoryEnumerator?
    private var cleaningStaging = false

    internal init(
        root: URL,
        synchronize: @escaping (Int32, Bool) throws -> Void = ImmutableBlobStore.synchronizeDescriptor
    ) throws {
        self.root = root
        self.synchronize = synchronize
        do {
            try files.createDirectory(at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
            try files.createDirectory(at: root.appendingPathComponent("staging"), withIntermediateDirectories: true)
            try synchronizeDirectory(root)
            try synchronizeDirectory(root.deletingLastPathComponent())
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw PersistenceErrorClassification.transactionFailure(for: error)
        }
    }

    /// Writes and synchronizes a private staging file, then publishes using a
    /// hard link: the final directory entry is atomic and never overwrites.
    /// A later SQL rollback may leave this published file for bounded cleanup.
    internal func write(
        _ bytes: Data, id: UUID = UUID(), didPublish: () -> Void = {}
    ) throws -> ImmutableBlobReference {
        let temporary = root.appendingPathComponent("staging/\(id.uuidString).partial")
        let destination = blobURL(id)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw posixFailure() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            // This invocation exclusively created this exact staging path.
            _ = Darwin.unlink(temporary.path)
        }
        do {
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Persist the shard's directory entry before publishing inside it.
            try synchronizeDirectory(root.appendingPathComponent("blobs"))
            guard Darwin.link(temporary.path, destination.path) == 0 else {
                throw posixFailure()
            }
            didPublish()
            try synchronizeDirectory(destination.deletingLastPathComponent())
            // fsync moves data to the drive; F_FULLFSYNC also flushes its
            // buffered writes. Neither failure permits a database reference.
            try synchronize(descriptor, true)
            return ImmutableBlobReference(id: id, byteCount: bytes.count)
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw PersistenceErrorClassification.transactionFailure(for: error)
        }
    }

    /// Mapping is only a hint for these app-private immutable files. Returned
    /// Data owns its bytes/mapping independently of the directory entry.
    internal func read(id: UUID, expectedByteCount: Int) throws -> Data {
        try Task.checkCancellation()
        guard expectedByteCount >= 0 else { throw corruptValue }
        do {
            let url = blobURL(id)
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == expectedByteCount else {
                throw corruptValue
            }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard bytes.count == expectedByteCount else { throw corruptValue }
            // Foundation's synchronous read cannot be preempted. A task
            // cancelled during it must still discard the completed value.
            try Task.checkCancellation()
            return bytes
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw readFailure(for: error)
        }
    }

    /// One logical range read holds one descriptor throughout all chunks.
    /// Unlink cannot invalidate an already-open read; a subsequent read must
    /// first pass the Authority's current-reference check again (V2-09 §5).
    internal func read(id: UUID, expectedByteCount: Int, range: Range<Int>) throws -> Data {
        try Task.checkCancellation()
        guard expectedByteCount >= 0, range.lowerBound >= 0,
              range.upperBound <= expectedByteCount else { throw corruptValue }
        do {
            let handle = try FileHandle(forReadingFrom: blobURL(id))
            defer { try? handle.close() }
            guard try handle.seekToEnd() == UInt64(expectedByteCount) else { throw corruptValue }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            var bytes = Data()
            bytes.reserveCapacity(range.count)
            while bytes.count < range.count {
                // V2-09 §5: cancellation ends this logical read and closes
                // its single descriptor without returning partial bytes.
                try Task.checkCancellation()
                let amount = min(64 * 1_024, range.count - bytes.count)
                guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else {
                    throw corruptValue
                }
                bytes.append(chunk)
            }
            try Task.checkCancellation()
            return bytes
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw readFailure(for: error)
        }
    }

    /// Caller has already committed removal of the last database reference.
    internal func remove(id: UUID) throws {
        guard Darwin.unlink(blobURL(id).path) == 0 else {
            if errno == ENOENT { return }
            throw posixFailure()
        }
    }

    /// Limits visited directory entries, including directories. The enumerator
    /// advances across calls; no complete live-ID collection or startup scan.
    /// The synchronous SQL callback and unlink run in one Authority interval.
    @discardableResult
    internal func cleanupBatch(
        limit: Int = 64, isReferenced: (UUID) throws -> Bool
    ) throws -> BlobCleanupBatchResult {
        guard limit > 0 else { return BlobCleanupBatchResult(removedCount: 0, completedPass: false) }
        var removed = 0
        for _ in 0..<limit {
            if cleanupEnumerator == nil {
                let directory = root.appendingPathComponent(cleaningStaging ? "staging" : "blobs")
                guard let enumerator = files.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
                    throw HistoryFailure.persistence(.transaction)
                }
                cleanupEnumerator = enumerator
            }
            guard let url = cleanupEnumerator?.nextObject() as? URL else {
                cleanupEnumerator = nil
                if cleaningStaging {
                    cleaningStaging = false
                    return BlobCleanupBatchResult(removedCount: removed, completedPass: true)
                }
                cleaningStaging = true
                continue
            }
            let suffix = cleaningStaging ? "partial" : "blob"
            guard url.pathExtension == suffix,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let referenced: Bool
            if cleaningStaging {
                referenced = false
            } else {
                referenced = try isReferenced(id)
            }
            if !referenced {
                do { try files.removeItem(at: url) }
                catch { throw PersistenceErrorClassification.transactionFailure(for: error) }
                removed += 1
            }
        }
        return BlobCleanupBatchResult(removedCount: removed, completedPass: false)
    }

    /// Cancellation and failed passes release directory traversal immediately.
    /// The next work request starts a fresh finite pass rather than resuming
    /// past entries whose database references may since have been removed.
    internal func cancelCleanupPass() {
        cleanupEnumerator = nil
        cleaningStaging = false
    }

    private var corruptValue: HistoryFailure { .persistence(.corruptStoredValue) }

    /// Apple fsync(2)/open(2): open directories read-only and require fsync
    /// success. Unsupported filesystems fail explicitly, including EINVAL.
    /// https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html
    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixFailure() }
        defer { _ = Darwin.close(descriptor) }
        try synchronize(descriptor, false)
    }

    /// The concrete syscall closure also gives real-file tests one focused
    /// failure injection point; no filesystem or writer double is introduced.
    private static func synchronizeDescriptor(_ descriptor: Int32, _ fully: Bool) throws {
        let result = fully ? Darwin.fcntl(descriptor, F_FULLFSYNC) : Darwin.fsync(descriptor)
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func readFailure(for error: any Error) -> HistoryFailure {
        if let failure = error as? HistoryFailure { return failure }
        let platform = error as NSError
        let underlying = platform.userInfo[NSUnderlyingErrorKey] as? NSError
        if isMissingFile(platform) || underlying.map(isMissingFile) == true {
            return corruptValue
        }
        return PersistenceErrorClassification.transactionFailure(for: error)
    }

    private func isMissingFile(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain { return error.code == ENOENT }
        return error.domain == NSCocoaErrorDomain
            && (error.code == CocoaError.Code.fileNoSuchFile.rawValue
                || error.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
    }

    private func blobURL(_ id: UUID) -> URL {
        let name = id.uuidString
        return root.appendingPathComponent("blobs/\(name.prefix(2))/\(name).blob")
    }

    private func posixFailure() -> HistoryFailure {
        let code = errno
        if code == EEXIST { return .persistence(.invariantViolation) }
        return PersistenceErrorClassification.transactionFailure(
            for: NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        )
    }
}
