import ClipyCLIContract
import Darwin
import Foundation

public struct LocalAutomationOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    package init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    package init(_ output: ClipyCLIProcessOutput) {
        self.init(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
    }
}

public enum LocalAutomationClientFailure: Error, Sendable {
    case notReady
    case notEnrolled
    case authenticationFailed
    case invalidRequest
    case requestTooLarge
    case timeout
    case cancelled
    case outcomeUnknown

    package var code: ClipyCLIErrorCode {
        switch self {
        case .notReady: .notReady
        case .notEnrolled: .notEnrolled
        case .authenticationFailed: .authenticationFailed
        case .invalidRequest: .invalidRequest
        case .requestTooLarge: .requestTooLarge
        case .timeout: .timeout
        case .cancelled: .cancelled
        case .outcomeUnknown: .outcomeUnknown
        }
    }
}

/// A single connected invocation. Only connect may be retried by the CLI's
/// cold-start owner. Once request transmission begins, an uncertain mutation
/// reports outcome_unknown and is never sent a second time (07 §7/§8.3).
public actor LocalAutomationClient {
    public static let maximumRequestBytes = ClipyCLIContract.maximumRequestBytes
    private var descriptor: Int32?

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit {
        if let descriptor { _ = Darwin.close(descriptor) }
    }

    public static func connect(
        endpointURL: URL, timeout: TimeInterval = 2
    ) async throws -> LocalAutomationClient {
        guard timeout.isFinite, timeout > 0 else { throw LocalAutomationClientFailure.timeout }
        let descriptor: Int32
        do { descriptor = try LocalAutomationSocket.make() }
        catch { throw LocalAutomationClientFailure.notReady }
        do {
            try await LocalAutomationSocket.connect(
                descriptor, to: endpointURL,
                deadline: .now.advanced(by: .seconds(timeout))
            )
            guard LocalAutomationSocket.sameUser(descriptor) else {
                throw LocalAutomationClientFailure.authenticationFailed
            }
            return LocalAutomationClient(descriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            if error is CancellationError { throw LocalAutomationClientFailure.cancelled }
            if case LocalAutomationSocket.Failure.timeout = error {
                throw LocalAutomationClientFailure.timeout
            }
            throw LocalAutomationClientFailure.notReady
        }
    }

    public static func validateRequest(_ json: Data) -> LocalAutomationOutput? {
        switch ClipyCLIContract.decodeRequest(json) {
        case .success: nil
        case let .failure(failure): LocalAutomationOutput(ClipyCLIContract.render(failure))
        }
    }

    public static func failure(
        _ code: LocalAutomationClientFailure, request: Data? = nil
    ) -> LocalAutomationOutput {
        var requestID: ClipyCLIRequestID?
        if let request {
            switch ClipyCLIContract.decodeRequest(request) {
            case let .success(value): requestID = value.requestID
            case let .failure(value): requestID = value.requestID
            }
        }
        return LocalAutomationOutput(ClipyCLIContract.render(
            .failure(requestID: requestID, code: code.code)
        ))
    }

    public func request(
        _ json: Data, credential: Data, timeout: TimeInterval = 10
    ) async -> LocalAutomationOutput {
        let request: ClipyCLIRequest
        switch ClipyCLIContract.decodeRequest(json) {
        case let .success(value): request = value
        case let .failure(value):
            close()
            return LocalAutomationOutput(ClipyCLIContract.render(value))
        }
        guard credential.count == LocalAutomationFrames.credentialByteCount else {
            close()
            return Self.failure(.authenticationFailed, request: json)
        }
        guard let connection = descriptor else { return Self.failure(.notReady, request: json) }
        // Transfer ownership to this one operation before the first await;
        // actor reentry cannot send another request or close/reuse this FD.
        descriptor = nil
        defer { _ = Darwin.close(connection) }
        guard timeout.isFinite, timeout > 0 else { return Self.failure(.timeout, request: json) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            try Task.checkCancellation()
            try await LocalAutomationSocket.send(
                LocalAutomationFrames.requestHeader(credential: credential, jsonCount: json.count),
                to: connection, deadline: deadline
            )
            try await LocalAutomationSocket.send(json, to: connection, deadline: deadline)
            let header = try await LocalAutomationSocket.receive(12, from: connection, deadline: deadline)
            let shape = try LocalAutomationFrames.decodeResponseHeader(header)
            let stdout = try await LocalAutomationSocket.receive(shape.stdout, from: connection, deadline: deadline)
            let stderr = try await LocalAutomationSocket.receive(shape.stderr, from: connection, deadline: deadline)
            return LocalAutomationOutput(exitCode: shape.exitCode, stdout: stdout, stderr: stderr)
        } catch {
            if request.isMutation { return Self.failure(.outcomeUnknown, request: json) }
            if error is CancellationError { return Self.failure(.cancelled, request: json) }
            return Self.failure(.timeout, request: json)
        }
    }

    public func close() {
        if let descriptor { _ = Darwin.close(descriptor) }
        descriptor = nil
    }
}
