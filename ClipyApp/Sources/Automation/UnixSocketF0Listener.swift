#if CLIPY_UDS_F0
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Compile-time-isolated app-side discriminator for PLAY-PY-F0. It proves
/// only that a same-EUID process can reach this signed app artifact through a
/// bounded Unix-domain socket handshake. It is not a product transport and
/// deliberately has no route to History, Gateway, credentials, or X.8 JSON.
final class UnixSocketF0Listener: Sendable {
    enum StartError: Error {
        case invalidEndpoint
        case endpointAlreadyLive
        case endpointNotOwned
        case posix(Int32)
    }

    private struct SocketIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
    }

    private static let connectionDeadlineNanoseconds: UInt64 = 2_000_000_000
    private static let acceptPollMilliseconds: Int32 = 100

    private let endpointPath: String
    private let boundIdentity: SocketIdentity
    private let listenerDescriptor: Int32
    private let lockDescriptor: Int32
    private let generation: [UInt8]
    private let stopping = Mutex(false)
    private let finished = DispatchSemaphore(value: 0)

    private init(
        endpointPath: String,
        boundIdentity: SocketIdentity,
        listenerDescriptor: Int32,
        lockDescriptor: Int32,
        generation: [UInt8]
    ) {
        self.endpointPath = endpointPath
        self.boundIdentity = boundIdentity
        self.listenerDescriptor = listenerDescriptor
        self.lockDescriptor = lockDescriptor
        self.generation = generation
    }

    static func start(endpointPath: String) throws -> UnixSocketF0Listener {
        guard endpointPath.hasPrefix("/") else {
            throw StartError.invalidEndpoint
        }

        // Validate the socket path before creating either its directory or
        // lock file; `withSocketAddress` owns the one pathname-size rule.
        try UnixSocketF0Protocol.withSocketAddress(path: endpointPath) { _, _ in () }
        try prepareEndpointDirectory(for: endpointPath)

        let lockDescriptor = Darwin.open(
            endpointPath + ".lock",
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard lockDescriptor >= 0 else {
            throw StartError.posix(errno)
        }

        var listenerDescriptor: Int32 = -1
        var createdIdentity: SocketIdentity?
        do {
            try validateAndLock(lockDescriptor)
            listenerDescriptor = try makeSocket()
            try bindWithStaleRecovery(
                descriptor: listenerDescriptor,
                endpointPath: endpointPath
            )
            createdIdentity = try ownedSocketIdentity(
                at: endpointPath,
                requiredMode: nil
            )
            guard Darwin.chmod(endpointPath, mode_t(0o600)) == 0 else {
                throw StartError.posix(errno)
            }
            let boundIdentity = try ownedSocketIdentity(at: endpointPath)
            guard Darwin.listen(listenerDescriptor, 4) == 0 else {
                throw StartError.posix(errno)
            }

            var uuid = UUID().uuid
            let generation = withUnsafeBytes(of: &uuid) { Array($0) }
            let listener = UnixSocketF0Listener(
                endpointPath: endpointPath,
                boundIdentity: boundIdentity,
                listenerDescriptor: listenerDescriptor,
                lockDescriptor: lockDescriptor,
                generation: generation
            )
            Thread.detachNewThread {
                listener.run()
            }
            return listener
        } catch {
            if listenerDescriptor >= 0 {
                _ = Darwin.close(listenerDescriptor)
            }
            if let createdIdentity,
               let currentIdentity = try? ownedSocketIdentity(
                   at: endpointPath,
                   requiredMode: nil
               ),
               currentIdentity == createdIdentity {
                _ = Darwin.unlink(endpointPath)
            }
            _ = Darwin.flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
            throw error
        }
    }

    /// Requests shutdown and waits long enough for independent two-second
    /// read and write deadlines plus the accept poll. The listener thread
    /// remains the sole closer of its descriptors, avoiding close/reuse races.
    func stop() {
        let wasStopping = stopping.withLock { value in
            let previous = value
            value = true
            return previous
        }
        guard !wasStopping else { return }
        _ = finished.wait(timeout: .now() + .seconds(5))
    }

    private func run() {
        defer {
            _ = Darwin.close(listenerDescriptor)
            unlinkBoundEndpointIfStillOwned()
            _ = Darwin.flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
            finished.signal()
        }

        while !stopping.withLock({ $0 }) {
            var readiness = pollfd(
                fd: listenerDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let result = Darwin.poll(&readiness, 1, Self.acceptPollMilliseconds)
            if result == 0 {
                continue
            }
            if result < 0 {
                if errno == EINTR { continue }
                return
            }
            guard readiness.revents & Int16(POLLIN) != 0 else {
                continue
            }

            let connection = Darwin.accept(listenerDescriptor, nil, nil)
            if connection < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            handle(connection)
        }
    }

    private func handle(_ descriptor: Int32) {
        defer { _ = Darwin.close(descriptor) }

        // Peer identity is checked before the first byte is read. This is only
        // same-account evidence; it does not identify a script or code signer.
        var peerUserID: uid_t = 0
        var peerGroupID: gid_t = 0
        guard Darwin.getpeereid(descriptor, &peerUserID, &peerGroupID) == 0,
              peerUserID == Darwin.geteuid() else {
            return
        }

        guard configureConnectedSocket(descriptor) else { return }
        let readDeadline = DispatchTime.now().uptimeNanoseconds
            + Self.connectionDeadlineNanoseconds
        guard let requestData = receiveExactly(
            UnixSocketF0Protocol.requestByteCount,
            from: descriptor,
            deadline: readDeadline
        ),
              let request = try? UnixSocketF0Protocol.decodeRequest(requestData),
              let reply = try? UnixSocketF0Protocol.encodeReply(
                  nonce: request.nonce,
                  generation: generation,
                  effectiveUserID: UInt32(Darwin.geteuid()),
                  effectiveGroupID: UInt32(Darwin.getegid()),
                  processID: UInt32(Darwin.getpid())
        ) else {
            return
        }
        let writeDeadline = DispatchTime.now().uptimeNanoseconds
            + Self.connectionDeadlineNanoseconds
        _ = sendExactly(reply, to: descriptor, deadline: writeDeadline)
    }

    private static func prepareEndpointDirectory(for endpointPath: String) throws {
        let directory = (endpointPath as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { throw StartError.invalidEndpoint }

        var status = Darwin.stat()
        if Darwin.lstat(directory, &status) != 0 {
            guard errno == ENOENT else { throw StartError.posix(errno) }
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw StartError.posix(EIO)
            }
            guard Darwin.chmod(directory, mode_t(0o700)) == 0,
                  Darwin.lstat(directory, &status) == 0 else {
                throw StartError.posix(errno)
            }
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == Darwin.geteuid(),
              status.st_mode & mode_t(0o777) == mode_t(0o700) else {
            throw StartError.endpointNotOwned
        }
    }

    private static func validateAndLock(_ descriptor: Int32) throws {
        var status = Darwin.stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw StartError.posix(errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw StartError.endpointNotOwned
        }
        guard Darwin.flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK {
                throw StartError.endpointAlreadyLive
            }
            throw StartError.posix(errno)
        }
    }

    private static func makeSocket(nonblocking: Bool = true) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartError.posix(errno) }

        let closeOnExec = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let nonblockingResult = nonblocking
            ? Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK)
            : 0
        guard closeOnExec == 0, nonblockingResult == 0 else {
            let failure = errno
            _ = Darwin.close(descriptor)
            throw StartError.posix(failure)
        }
        return descriptor
    }

    private static func bindWithStaleRecovery(
        descriptor: Int32,
        endpointPath: String
    ) throws {
        let firstBind = try UnixSocketF0Protocol.withSocketAddress(path: endpointPath) {
            Darwin.bind(descriptor, $0, $1)
        }
        guard firstBind != 0 else { return }
        let bindFailure = errno
        guard bindFailure == EADDRINUSE else {
            throw StartError.posix(bindFailure)
        }

        let probe = try makeSocket(nonblocking: false)
        let connectResult = try UnixSocketF0Protocol.withSocketAddress(path: endpointPath) {
            Darwin.connect(probe, $0, $1)
        }
        let connectFailure = errno
        _ = Darwin.close(probe)
        if connectResult == 0 {
            throw StartError.endpointAlreadyLive
        }
        guard connectFailure == ECONNREFUSED else {
            throw StartError.posix(connectFailure)
        }

        // The lifetime flock is already held. Two independent lstat reads must
        // still identify the same same-owner socket before stale removal.
        let firstIdentity = try ownedSocketIdentity(at: endpointPath)
        let secondIdentity = try ownedSocketIdentity(at: endpointPath)
        guard firstIdentity == secondIdentity else {
            throw StartError.endpointNotOwned
        }
        guard Darwin.unlink(endpointPath) == 0 else {
            throw StartError.posix(errno)
        }

        let retry = try UnixSocketF0Protocol.withSocketAddress(path: endpointPath) {
            Darwin.bind(descriptor, $0, $1)
        }
        guard retry == 0 else { throw StartError.posix(errno) }
    }

    private static func ownedSocketIdentity(
        at path: String,
        requiredMode: mode_t? = mode_t(0o600)
    ) throws -> SocketIdentity {
        var status = Darwin.stat()
        guard Darwin.lstat(path, &status) == 0 else {
            throw StartError.posix(errno)
        }
        guard status.st_mode & S_IFMT == S_IFSOCK,
              status.st_uid == Darwin.geteuid() else {
            throw StartError.endpointNotOwned
        }
        if let requiredMode,
           status.st_mode & mode_t(0o777) != requiredMode {
            throw StartError.endpointNotOwned
        }
        return SocketIdentity(
            device: status.st_dev,
            inode: status.st_ino,
            owner: status.st_uid
        )
    }

    private static func configureConnectedSocket(_ descriptor: Int32) -> Bool {
        var enabled: Int32 = 1
        let noSignal = Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let nonblocking = Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let closeOnExec = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        return noSignal == 0 && nonblocking == 0 && closeOnExec == 0
    }

    private static func receiveExactly(
        _ count: Int,
        from descriptor: Int32,
        deadline: UInt64
    ) -> Data? {
        var data = Data(count: count)
        let completed = data.withUnsafeMutableBytes {
            (storage: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = storage.baseAddress else { return false }
            var offset = 0
            while offset < count {
                guard waitUntilReady(
                    descriptor,
                    events: Int16(POLLIN),
                    deadline: deadline
                ) else { return false }
                let received = Darwin.recv(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset,
                    0
                )
                if received > 0 {
                    offset += received
                } else if received == 0 {
                    return false
                } else if errno != EINTR && errno != EAGAIN {
                    return false
                }
            }
            return true
        }
        return completed ? data : nil
    }

    private static func sendExactly(
        _ data: Data,
        to descriptor: Int32,
        deadline: UInt64
    ) -> Bool {
        data.withUnsafeBytes { (storage: UnsafeRawBufferPointer) -> Bool in
            guard let base = storage.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                guard waitUntilReady(
                    descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline
                ) else { return false }
                let sent = Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset,
                    0
                )
                if sent > 0 {
                    offset += sent
                } else if sent == 0 {
                    return false
                } else if errno != EINTR && errno != EAGAIN {
                    return false
                }
            }
            return true
        }
    }

    private static func waitUntilReady(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64
    ) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = deadline - now
            let roundedMilliseconds = (remaining + 999_999) / 1_000_000
            let timeout = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var readiness = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&readiness, 1, timeout)
            if result > 0 {
                return readiness.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0
            }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    private func unlinkBoundEndpointIfStillOwned() {
        guard let current = try? Self.ownedSocketIdentity(at: endpointPath),
              current == boundIdentity else {
            return
        }
        _ = Darwin.unlink(endpointPath)
    }
}
#endif
