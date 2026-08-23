#if CLIPY_UDS_F0
import AppKit
import Darwin
import Foundation

/// Signed-runtime discriminator for the main-app-owned AF_UNIX F0 only.
/// It deliberately has no History, Gateway, credential, or X.8 JSON access.
@main
@MainActor
struct ClipyUDSF0Client {
    private static let totalDeadlineSeconds = 10.0
    private static let socketOperationDeadlineSeconds = 2.0

    static func main() {
        guard let invocation = parseInvocation(Array(CommandLine.arguments.dropFirst())) else {
            emit("ClipyUDSF0Client: usage\n", descriptor: STDERR_FILENO)
            Darwin.exit(2)
        }

        do {
            switch invocation {
            case let .exchange(appURL, endpointPath, launchAllowed, halfFrame):
                try runExchange(
                    appURL: appURL,
                    endpointPath: endpointPath,
                    launchAllowed: launchAllowed,
                    halfFrame: halfFrame
                )
            case let .terminate(appURL, endpointPath, processID):
                try terminateApplication(
                    appURL: appURL,
                    endpointPath: endpointPath,
                    processID: processID
                )
            case let .kill(appURL, endpointPath, processID):
                try killApplication(
                    appURL: appURL,
                    endpointPath: endpointPath,
                    processID: processID
                )
            }
        } catch {
            emit("ClipyUDSF0Client: failed\n", descriptor: STDERR_FILENO)
            Darwin.exit(1)
        }
    }

    private enum Invocation {
        case exchange(
            appURL: URL,
            endpointPath: String,
            launchAllowed: Bool,
            halfFrame: Bool
        )
        case terminate(appURL: URL, endpointPath: String, processID: pid_t)
        case kill(appURL: URL, endpointPath: String, processID: pid_t)
    }

    private enum ClientFailure: Error {
        case connectionFailed
        case socketOperationFailed
        case invalidReply
        case processControlFailed
    }

    private enum ConnectAttempt {
        case connected(Int32)
        case unavailable
        case pending
    }

    private static func parseInvocation(_ arguments: [String]) -> Invocation? {
        guard !arguments.isEmpty,
              let appURL = containingApplicationURL(),
              endpointIsValid(arguments[0]) else {
            return nil
        }

        let endpointPath = arguments[0]
        let options = Array(arguments.dropFirst())
        if options.count == 2,
           (options[0] == "--terminate" || options[0] == "--kill"),
           let processID = parseProcessID(options[1]) {
            if options[0] == "--terminate" {
                return .terminate(
                    appURL: appURL,
                    endpointPath: endpointPath,
                    processID: processID
                )
            }
            return .kill(
                appURL: appURL,
                endpointPath: endpointPath,
                processID: processID
            )
        }

        var launchAllowed = true
        var halfFrame = false
        var sawConnectOnly = false
        var sawHalfFrame = false
        for option in options {
            switch option {
            case "--connect-only" where !sawConnectOnly:
                sawConnectOnly = true
                launchAllowed = false
            case "--half-frame" where !sawHalfFrame:
                sawHalfFrame = true
                halfFrame = true
            default:
                return nil
            }
        }
        return .exchange(
            appURL: appURL,
            endpointPath: endpointPath,
            launchAllowed: launchAllowed,
            halfFrame: halfFrame
        )
    }

    private static func containingApplicationURL() -> URL? {
        guard let executableArgument = CommandLine.arguments.first else {
            return nil
        }
        let executableURL = normalizedFileURL(
            URL(fileURLWithPath: executableArgument)
        )
        let applicationURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard applicationURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: applicationURL.path) else {
            return nil
        }
        return applicationURL
    }

    private static func endpointIsValid(_ endpointPath: String) -> Bool {
        let bytes = Array(endpointPath.utf8)
        return endpointPath.hasPrefix("/")
            && !bytes.isEmpty
            && bytes.count <= UnixSocketF0Protocol.maximumEndpointUTF8ByteCount
            && !bytes.contains(0)
    }

    private static func parseProcessID(_ argument: String) -> pid_t? {
        guard let value = Int32(argument), value > 1 else {
            return nil
        }
        return pid_t(value)
    }

    private static func runExchange(
        appURL: URL,
        endpointPath: String,
        launchAllowed: Bool,
        halfFrame: Bool
    ) throws {
        let deadline = monotonicTime() + totalDeadlineSeconds
        let descriptor = try connect(
            appURL: appURL,
            endpointPath: endpointPath,
            launchAllowed: launchAllowed,
            deadline: deadline
        )
        defer { Darwin.close(descriptor) }
        try configureOperationDeadline(descriptor: descriptor, deadline: deadline)

        let nonce = nonceBytes()
        let request = try UnixSocketF0Protocol.encodeRequest(nonce: nonce)
        if halfFrame {
            let prefixLength = max(1, UnixSocketF0Protocol.requestByteCount / 2)
            try writeExactly(request.prefix(prefixLength), to: descriptor)
            guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
                throw ClientFailure.socketOperationFailed
            }
            try requirePeerClosure(descriptor: descriptor)
            emit("HALF_FRAME_CLOSED\n", descriptor: STDOUT_FILENO)
            return
        }

        try writeExactly(request, to: descriptor)
        let replyData = try readExactly(
            byteCount: UnixSocketF0Protocol.replyByteCount,
            from: descriptor
        )
        try requirePeerClosure(descriptor: descriptor)
        let reply = try UnixSocketF0Protocol.decodeReply(replyData)
        guard reply.nonce == nonce,
              reply.effectiveUserID == UInt32(geteuid()),
              reply.effectiveGroupID == UInt32(getegid()),
              reply.processID > 1 else {
            throw ClientFailure.invalidReply
        }

        emit(
            "READY pid=\(reply.processID) euid=\(reply.effectiveUserID) "
                + "egid=\(reply.effectiveGroupID) generation=\(uuidString(reply.generation))\n",
            descriptor: STDOUT_FILENO
        )
    }

    private static func connect(
        appURL: URL,
        endpointPath: String,
        launchAllowed: Bool,
        deadline: Double
    ) throws -> Int32 {
        var attemptCount = 1
        var requestedLaunch = false
        switch try connectOnce(
            endpointPath: endpointPath,
            deadline: min(deadline, monotonicTime() + 0.25)
        ) {
        case let .connected(descriptor):
            return descriptor
        case .unavailable where launchAllowed:
            requestApplicationLaunch(appURL: appURL, endpointPath: endpointPath)
            requestedLaunch = true
        case .unavailable:
            throw ClientFailure.connectionFailed
        case .pending:
            break
        }

        var backoffMicroseconds: useconds_t = 50_000
        while true {
            let remainingMicroseconds = (deadline - monotonicTime()) * 1_000_000
            guard remainingMicroseconds > 0 else { break }
            Darwin.usleep(
                min(backoffMicroseconds, useconds_t(remainingMicroseconds))
            )
            guard monotonicTime() < deadline else { break }
            attemptCount += 1
            switch try connectOnce(
                endpointPath: endpointPath,
                deadline: min(deadline, monotonicTime() + 0.25)
            ) {
            case let .connected(descriptor):
                guard !requestedLaunch || attemptCount >= 2 else {
                    Darwin.close(descriptor)
                    throw ClientFailure.connectionFailed
                }
                return descriptor
            case .unavailable, .pending:
                backoffMicroseconds = min(backoffMicroseconds + 50_000, 250_000)
            }
        }
        throw ClientFailure.connectionFailed
    }

    private static func connectOnce(
        endpointPath: String,
        deadline: Double
    ) throws -> ConnectAttempt {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ClientFailure.connectionFailed
        }
        var ownsDescriptor = true
        defer {
            if ownsDescriptor {
                Darwin.close(descriptor)
            }
        }

        try configureSocket(descriptor)
        let result = try UnixSocketF0Protocol.withSocketAddress(path: endpointPath) {
            Darwin.connect(descriptor, $0, $1)
        }
        if result == 0 {
            try makeSocketBlocking(descriptor)
            ownsDescriptor = false
            return .connected(descriptor)
        }
        let connectError = errno
        if connectError == ENOENT || connectError == ECONNREFUSED {
            return .unavailable
        }
        if connectError == EAGAIN {
            return .pending
        }
        if connectError == EINPROGRESS {
            switch try finishPendingConnection(descriptor, deadline: deadline) {
            case .connected:
                try makeSocketBlocking(descriptor)
                ownsDescriptor = false
                return .connected(descriptor)
            case .unavailable:
                return .unavailable
            case .pending:
                return .pending
            }
        }
        throw ClientFailure.connectionFailed
    }

    private static func configureSocket(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ClientFailure.socketOperationFailed
        }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw ClientFailure.socketOperationFailed
        }
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw ClientFailure.socketOperationFailed
        }
    }

    private static func finishPendingConnection(
        _ descriptor: Int32,
        deadline: Double
    ) throws -> ConnectAttempt {
        while true {
            let remainingMilliseconds = (deadline - monotonicTime()) * 1_000
            guard remainingMilliseconds > 0 else { return .pending }
            var readiness = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &readiness,
                1,
                Int32(min(remainingMilliseconds.rounded(.up), 250))
            )
            if pollResult == 0 {
                return .pending
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw ClientFailure.connectionFailed
            }

            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &errorLength
            ) == 0 else {
                throw ClientFailure.connectionFailed
            }
            if socketError == 0 {
                return .connected(descriptor)
            }
            if socketError == ENOENT || socketError == ECONNREFUSED {
                return .unavailable
            }
            if socketError == EINPROGRESS || socketError == EAGAIN {
                continue
            }
            throw ClientFailure.connectionFailed
        }
    }

    private static func makeSocketBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw ClientFailure.socketOperationFailed
        }
    }

    private static func configureOperationDeadline(descriptor: Int32, deadline: Double) throws {
        let remaining = min(
            socketOperationDeadlineSeconds,
            max(0.001, deadline - monotonicTime())
        )
        let wholeSeconds = remaining.rounded(.down)
        var timeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((remaining - wholeSeconds) * 1_000_000)
        )
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLength) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLength) == 0 else {
            throw ClientFailure.socketOperationFailed
        }
    }

    private static func requestApplicationLaunch(appURL: URL, endpointPath: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = false
        configuration.environment = [
            UnixSocketF0Protocol.endpointEnvironmentKey: endpointPath,
        ]
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: configuration
        ) { _, _ in }
    }

    private static func writeExactly<Bytes: DataProtocol>(
        _ bytes: Bytes,
        to descriptor: Int32
    ) throws {
        let data = Data(bytes)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw ClientFailure.socketOperationFailed
                }
            }
        }
    }

    private static func readExactly(byteCount: Int, from descriptor: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var offset = 0
        while offset < byteCount {
            let received = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    byteCount - offset
                )
            }
            if received > 0 {
                offset += received
            } else if received < 0, errno == EINTR {
                continue
            } else {
                throw ClientFailure.socketOperationFailed
            }
        }
        return Data(bytes)
    }

    private static func requirePeerClosure(descriptor: Int32) throws {
        var byte: UInt8 = 0
        while true {
            let received = Darwin.read(descriptor, &byte, 1)
            if received == 0 {
                return
            }
            if received < 0, errno == EINTR {
                continue
            }
            throw ClientFailure.socketOperationFailed
        }
    }

    private static func terminateApplication(
        appURL: URL,
        endpointPath: String,
        processID: pid_t
    ) throws {
        let application = try validatedApplication(appURL: appURL, processID: processID)
        guard application.terminate() else {
            throw ClientFailure.processControlFailed
        }
        let deadline = monotonicTime() + totalDeadlineSeconds
        while monotonicTime() < deadline {
            if processHasExited(processID),
               !FileManager.default.fileExists(atPath: endpointPath) {
                emit("TERMINATED\n", descriptor: STDOUT_FILENO)
                return
            }
            Darwin.usleep(50_000)
        }
        throw ClientFailure.processControlFailed
    }

    private static func killApplication(
        appURL: URL,
        endpointPath: String,
        processID: pid_t
    ) throws {
        _ = try validatedApplication(appURL: appURL, processID: processID)
        guard Darwin.kill(processID, SIGKILL) == 0 else {
            throw ClientFailure.processControlFailed
        }
        let deadline = monotonicTime() + totalDeadlineSeconds
        while monotonicTime() < deadline {
            if processHasExited(processID) {
                guard FileManager.default.fileExists(atPath: endpointPath) else {
                    throw ClientFailure.processControlFailed
                }
                emit("KILLED_STALE\n", descriptor: STDOUT_FILENO)
                return
            }
            Darwin.usleep(50_000)
        }
        throw ClientFailure.processControlFailed
    }

    private static func validatedApplication(
        appURL: URL,
        processID: pid_t
    ) throws -> NSRunningApplication {
        guard let application = NSRunningApplication(processIdentifier: processID),
              let runningBundleURL = application.bundleURL,
              normalizedFileURL(runningBundleURL) == normalizedFileURL(appURL) else {
            throw ClientFailure.processControlFailed
        }
        return application
    }

    private static func processHasExited(_ processID: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(processID, 0) == -1 && errno == ESRCH
    }

    private static func nonceBytes() -> [UInt8] {
        var value = UUID().uuid
        return withUnsafeBytes(of: &value) { Array($0) }
    }

    private static func uuidString(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == UnixSocketF0Protocol.generationByteCount)
        let hexadecimal = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(36)
        for index in bytes.indices {
            if index == 4 || index == 6 || index == 8 || index == 10 {
                output.append(45)
            }
            output.append(hexadecimal[Int(bytes[index] >> 4)])
            output.append(hexadecimal[Int(bytes[index] & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func normalizedFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func monotonicTime() -> Double {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC_RAW, &value) == 0 else {
            return 0
        }
        return Double(value.tv_sec) + (Double(value.tv_nsec) / 1_000_000_000)
    }

    private static func emit(_ message: String, descriptor: Int32) {
        let bytes = Array(message.utf8)
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
#endif
