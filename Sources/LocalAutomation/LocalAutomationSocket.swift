import Darwin
import Foundation

/// Private pathname-stream mechanics shared by the app listener and bundled
/// client. Descriptors are nonblocking; waits suspend their task, never the
/// main actor or a cooperative-executor thread (07 §6/§7).
package enum LocalAutomationSocket {
    package enum Failure: Error, Sendable, Equatable {
        case unavailable
        case timeout
        case disconnected
        case invalidFrame
    }

    package static func make() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable }
        do {
            try configure(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    package static func configure(_ descriptor: Int32) throws {
        var suppressSignal: Int32 = 1
        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                                &suppressSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Failure.unavailable
        }
    }

    package static func withAddress<T>(
        _ url: URL,
        body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        let bytes = Array(url.path.utf8)
        guard url.isFileURL, url.path.hasPrefix("/"), !bytes.contains(0),
              !bytes.isEmpty, bytes.count <= 103 else { throw Failure.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: 104) { storage in
                for index in bytes.indices { storage[index] = bytes[index] }
                storage[bytes.count] = 0
            }
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    package static func connect(
        _ descriptor: Int32, to endpoint: URL,
        deadline: ContinuousClock.Instant
    ) async throws {
        let result = try withAddress(endpoint) {
            Darwin.connect(descriptor, $0, $1)
        }
        if result == 0 { return }
        guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else {
            throw Failure.unavailable
        }
        while true {
            try Task.checkCancellation()
            var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&readiness, 1, 0)
            if ready > 0 {
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR,
                                        &socketError, &length) == 0,
                      socketError == 0 else { throw Failure.unavailable }
                return
            }
            if ready < 0, errno != EINTR { throw Failure.unavailable }
            try await pause(until: deadline)
        }
    }

    package static func sameUser(_ descriptor: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        return Darwin.getpeereid(descriptor, &user, &group) == 0
            && user == Darwin.geteuid()
    }

    package static func receive(
        _ count: Int, from descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) async throws -> Data {
        guard count >= 0 else { throw Failure.invalidFrame }
        var bytes = Data(count: count)
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.recv(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received > 0 { offset += received; continue }
            if received == 0 { throw Failure.disconnected }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw Failure.disconnected }
            try await pause(until: deadline)
        }
        return bytes
    }

    package static func send(
        _ bytes: Data, to descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) async throws {
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            let sent = bytes.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent > 0 { offset += sent; continue }
            if sent == 0 { throw Failure.disconnected }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw Failure.disconnected }
            try await pause(until: deadline)
        }
    }

    package static func pause(until deadline: ContinuousClock.Instant) async throws {
        guard ContinuousClock.now < deadline else { throw Failure.timeout }
        try await Task.sleep(until: min(deadline, .now.advanced(by: .milliseconds(5))), clock: .continuous)
    }
}
