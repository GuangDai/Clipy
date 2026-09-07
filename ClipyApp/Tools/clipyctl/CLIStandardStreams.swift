import Darwin
import Foundation
import LocalAutomation

/// Standard streams use pipes as well as files, so the socket transport's
/// recv/send operations do not apply. One deadline covers the complete read
/// or output, including a producer that never closes stdin or a full pipe.
enum CLIStandardStreams {
    enum Failure: Error { case timeout, unavailable }

    static func readRequest() async throws -> Data {
        let descriptor = STDIN_FILENO
        let originalFlags = try makeNonblocking(descriptor)
        defer { _ = Darwin.fcntl(descriptor, F_SETFL, originalFlags) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let maximum = LocalAutomationClient.maximumRequestBytes
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 8_192)
        while bytes.count <= maximum {
            try await wait(descriptor, for: Int16(POLLIN), until: deadline)
            let capacity = min(chunk.count, maximum + 1 - bytes.count)
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!, capacity)
            }
            if count == 0 { return bytes }
            if count > 0 {
                bytes.append(contentsOf: chunk.prefix(count))
                continue
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw Failure.unavailable
            }
        }
        return bytes
    }

    static func write(
        _ bytes: Data, to descriptor: Int32, deadline: ContinuousClock.Instant
    ) async throws {
        guard !bytes.isEmpty else { return }
        let originalFlags = try makeNonblocking(descriptor)
        defer { _ = Darwin.fcntl(descriptor, F_SETFL, originalFlags) }
        var offset = 0
        while offset < bytes.count {
            try await wait(descriptor, for: Int16(POLLOUT), until: deadline)
            let count = bytes.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count; continue }
            guard count < 0,
                  errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw Failure.unavailable
            }
        }
    }

    private static func makeNonblocking(_ descriptor: Int32) throws -> Int32 {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.unavailable
        }
        return flags
    }

    private static func wait(
        _ descriptor: Int32, for events: Int16, until deadline: ContinuousClock.Instant
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            var readiness = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = Darwin.poll(&readiness, 1, 0)
            if ready > 0 {
                guard readiness.revents & Int16(POLLNVAL) == 0 else {
                    throw Failure.unavailable
                }
                return
            }
            if ready < 0, errno != EINTR { throw Failure.unavailable }
            try await Task.sleep(
                until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))), clock: .continuous
            )
        }
    }
}
