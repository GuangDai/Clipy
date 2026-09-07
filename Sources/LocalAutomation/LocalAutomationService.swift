import Darwin
import Dispatch
import Foundation
import HistoryStorage

/// The one app-owned Local Automation listener. It receives at most four
/// requests concurrently and never opens History; every operation uses the
/// ingress built from the application's existing SwiftDataHistory owner.
public actor LocalAutomationService {
    private let ingress: LocalAutomationIngress
    private let endpointURL: URL
    private var listener: Int32?
    private var endpointIdentity: (device: dev_t, inode: ino_t)?
    private var readSource: (any DispatchSourceRead)?
    private var suspendedSource: (any DispatchSourceRead)?
    private var sourceTermination: AsyncStream<Void>?
    private var connections: [UUID: Task<Void, Never>] = [:]

    public init(ingress: LocalAutomationIngress, endpointURL: URL) {
        self.ingress = ingress
        self.endpointURL = endpointURL
    }

    public func start() async throws {
        guard listener == nil else { return }
        try LocalAutomationSocket.withAddress(endpointURL) { _, _ in () }
        try prepareDirectory()
        let descriptor = try LocalAutomationSocket.make()
        do {
            let bound = try LocalAutomationSocket.withAddress(endpointURL) {
                Darwin.bind(descriptor, $0, $1)
            }
            if bound != 0 {
                guard errno == EADDRINUSE else { throw LocalAutomationSocket.Failure.unavailable }
                try removeStaleEndpoint()
                let rebound = try LocalAutomationSocket.withAddress(endpointURL) {
                    Darwin.bind(descriptor, $0, $1)
                }
                guard rebound == 0 else { throw LocalAutomationSocket.Failure.unavailable }
            }
            var status = stat()
            guard Darwin.lstat(endpointURL.path, &status) == 0 else {
                throw LocalAutomationSocket.Failure.unavailable
            }
            endpointIdentity = (status.st_dev, status.st_ino)
            guard Darwin.chmod(endpointURL.path, 0o600) == 0,
                  Darwin.listen(descriptor, 4) == 0 else {
                throw LocalAutomationSocket.Failure.unavailable
            }
            listener = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor)
            let termination = AsyncStream<Void>.makeStream()
            source.setCancelHandler {
                _ = Darwin.close(descriptor)
                termination.continuation.finish()
            }
            source.setEventHandler { [weak self, weak source] in
                guard let source else { return }
                // One event owns one suspension. The actor either drains
                // accepts and resumes it, or holds it while all four request
                // slots are occupied. There are no idle timer wakeups.
                source.suspend()
                Task {
                    guard let self else {
                        source.cancel()
                        source.resume()
                        return
                    }
                    await self.acceptConnections(source)
                }
            }
            readSource = source
            sourceTermination = termination.stream
            source.activate()
        } catch {
            _ = Darwin.close(descriptor)
            removeBoundEndpoint()
            throw error
        }
    }

    public func stop() async {
        // Cancellation wakes every bounded read/write wait. Each connection
        // task is its descriptor's sole closer; stop joins them before return.
        let source = readSource
        let termination = sourceTermination
        let identity = endpointIdentity
        let pending = Array(connections.values)
        readSource = nil
        sourceTermination = nil
        listener = nil
        endpointIdentity = nil
        source?.cancel()
        if let suspendedSource {
            suspendedSource.resume()
            self.suspendedSource = nil
        }
        for task in pending { task.cancel() }
        if let termination {
            for await _ in termination {}
        }
        removeEndpoint(matching: identity)
        for task in pending { await task.value }
    }

    private func acceptConnections(_ source: any DispatchSourceRead) {
        guard readSource === source, let descriptor = listener else {
            source.resume()
            return
        }
        while connections.count < 4 {
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { source.cancel() }
                source.resume()
                return
            }
            guard LocalAutomationSocket.sameUser(connection) else {
                _ = Darwin.close(connection)
                continue
            }
            do { try LocalAutomationSocket.configure(connection) }
            catch { _ = Darwin.close(connection); continue }
            let id = UUID()
            connections[id] = Task { await self.handle(connection, id: id) }
        }
        suspendedSource = source
    }

    private func handle(_ descriptor: Int32, id: UUID) async {
        defer {
            _ = Darwin.close(descriptor)
            connections.removeValue(forKey: id)
            if let suspendedSource {
                self.suspendedSource = nil
                suspendedSource.resume()
            }
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            let header = try await LocalAutomationSocket.receive(
                LocalAutomationFrames.requestHeaderBytes, from: descriptor, deadline: deadline
            )
            let shape = try LocalAutomationFrames.decodeRequestHeader(header)
            let json = try await LocalAutomationSocket.receive(shape.count, from: descriptor, deadline: deadline)
            try Task.checkCancellation()
            let output = await LocalAutomationReplyMapping.execute(json: json, credential: shape.credential, ingress: ingress)
            try await LocalAutomationSocket.send(LocalAutomationFrames.responseHeader(output), to: descriptor, deadline: deadline)
            try await LocalAutomationSocket.send(output.stdout, to: descriptor, deadline: deadline)
            try await LocalAutomationSocket.send(output.stderr, to: descriptor, deadline: deadline)
        } catch {
            // A disconnected or malformed private stream receives no partial
            // JSON. The client owns timeout/outcome_unknown reporting.
        }
    }

    private func prepareDirectory() throws {
        let directory = endpointURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        var status = stat()
        guard Darwin.lstat(directory.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == Darwin.geteuid(),
              status.st_mode & 0o777 == 0o700 else {
            throw LocalAutomationSocket.Failure.unavailable
        }
    }

    private func removeStaleEndpoint() throws {
        var before = stat()
        guard Darwin.lstat(endpointURL.path, &before) == 0,
              before.st_mode & S_IFMT == S_IFSOCK,
              before.st_uid == Darwin.geteuid() else {
            throw LocalAutomationSocket.Failure.unavailable
        }
        let probe = try LocalAutomationSocket.make()
        defer { _ = Darwin.close(probe) }
        let result = try LocalAutomationSocket.withAddress(endpointURL) {
            Darwin.connect(probe, $0, $1)
        }
        // A live or still-starting endpoint belongs to its current process.
        // Only a refused, still-identical owned socket is stale. No lock file
        // or cross-process service ownership machinery is introduced.
        guard result != 0, errno == ECONNREFUSED else {
            throw LocalAutomationSocket.Failure.unavailable
        }
        var after = stat()
        guard Darwin.lstat(endpointURL.path, &after) == 0,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              Darwin.unlink(endpointURL.path) == 0 else {
            throw LocalAutomationSocket.Failure.unavailable
        }
    }

    private func removeBoundEndpoint() {
        removeEndpoint(matching: endpointIdentity)
        endpointIdentity = nil
    }

    private func removeEndpoint(matching identity: (device: dev_t, inode: ino_t)?) {
        guard let identity else { return }
        var status = stat()
        if Darwin.lstat(endpointURL.path, &status) == 0,
           status.st_dev == identity.device, status.st_ino == identity.inode {
            _ = Darwin.unlink(endpointURL.path)
        }
    }
}
