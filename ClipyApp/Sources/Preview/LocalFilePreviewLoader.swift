import Darwin
import Foundation
import HistoryCore

#if DEBUG
enum LocalFilePreviewDebugInstrumentation {
    /// Observe the real read after one bounded chunk. Tests may park here to
    /// cancel the request or grow its actual file; no I/O is substituted.
    @TaskLocal static var didReadChunk: (@Sendable (Int) async -> Void)?
}
#endif

/// Explicit file-preview I/O lives in the app, apart from the inert copied
/// URL renderer. Constructing this actor reads nothing. Only the UI's two
/// confirmed actions call load; the result never enters History storage.
actor LocalFilePreviewLoader {
    static let maximumBytes = 64 * 1_048_576
    private static let chunkBytes = 64 * 1_024

    func load(_ address: String) async throws -> HistoryRepresentation {
        try Task.checkCancellation()
        guard address.utf8.count <= 16 * 1_024,
              let url = URL(string: address, encodingInvalidCharacters: false),
              url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else {
            throw FilePreviewFailure.invalidReference
        }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw FilePreviewFailure.invalidReference
        }
        let type = try Self.typeIdentifier(forExtension: url.pathExtension)

        // lstat reads metadata, not file contents. Dataless placeholders and
        // symlinks are not regular local-file input for this explicit action;
        // in particular, never open a cloud placeholder to materialize it.
        var initialStatus = stat()
        guard Darwin.lstat(path, &initialStatus) == 0 else {
            throw Self.failure(for: errno)
        }
        try Self.checkFile(initialStatus)
        let isLocalVolume: Bool?
        do {
            isLocalVolume = try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
        } catch {
            throw Self.failure(for: error)
        }
        guard let isLocalVolume else { throw FilePreviewFailure.unavailable }
        guard isLocalVolume else {
            throw FilePreviewFailure.unsupported
        }
        try Task.checkCancellation()
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.failure(for: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0 else {
            throw Self.failure(for: errno)
        }
        try Self.checkFile(openedStatus)

        var bytes = Data()
        bytes.reserveCapacity(Int(openedStatus.st_size))
        while true {
            try Task.checkCancellation()
            let allowance = Self.maximumBytes + 1 - bytes.count
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(Self.chunkBytes, allowance)) ?? Data()
            } catch {
                try Task.checkCancellation()
                throw Self.failure(for: error)
            }
            guard !chunk.isEmpty else { break }
            try Task.checkCancellation()
            // Read the one excess byte to distinguish exact-limit EOF from
            // growth, but reject it before appending can grow Data's storage.
            guard chunk.count <= Self.maximumBytes - bytes.count else {
                throw FilePreviewFailure.tooLarge
            }
            bytes.append(chunk)
#if DEBUG
            if let didReadChunk = LocalFilePreviewDebugInstrumentation.didReadChunk {
                await didReadChunk(bytes.count)
            }
#endif
            await Task.yield()
        }
        try Task.checkCancellation()
        let finalType = type == "public.utf8-plain-text"
            && (bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]))
            ? "public.utf16-external-plain-text" : type
        return HistoryRepresentation(typeIdentifier: finalType, bytes: bytes)
    }

    private static func checkFile(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG else { throw FilePreviewFailure.unsupported }
        guard status.st_flags & UInt32(SF_DATALESS) == 0 else { throw FilePreviewFailure.unavailable }
        guard status.st_size >= 0, status.st_size <= Int64(maximumBytes) else {
            throw FilePreviewFailure.tooLarge
        }
    }

    private static func failure(for code: Int32) -> FilePreviewFailure {
        code == EACCES || code == EPERM ? .permissionDenied : .unavailable
    }

    private static func failure(for error: any Error) -> FilePreviewFailure {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
            return .permissionDenied
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(EACCES) || error.code == Int(EPERM) {
            return .permissionDenied
        }
        return .unavailable
    }

    /// The formats the existing renderer consumes; no system app launch,
    /// extension handler, dynamic registry, or fallback decoder is involved.
    private static func typeIdentifier(forExtension suffix: String) throws -> String {
        switch suffix.lowercased() {
        case "txt", "text": "public.utf8-plain-text"
        case "png": "public.png"
        case "jpg", "jpeg": "public.jpeg"
        case "tif", "tiff": "public.tiff"
        case "heic": "public.heic"
        case "heif": "public.heif"
        case "gif": "com.compuserve.gif"
        case "bmp": "com.microsoft.bmp"
        case "pdf": "com.adobe.pdf"
        case "rtf": "public.rtf"
        case "html", "htm": "public.html"
        default: throw FilePreviewFailure.unsupported
        }
    }
}
