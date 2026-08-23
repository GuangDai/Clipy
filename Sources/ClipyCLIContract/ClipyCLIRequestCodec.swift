/// ClipyCLIRequestCodec — exact protocol-v1 request shape and bounded typed
/// decoding (V2-05 §0.1.1; PLAY-PY-A2A–A2F, A2I).
import Foundation

package extension ClipyCLIContract {
    static func decodeRequest(_ bytes: Data) -> ClipyCLIRequestDecoding {
        guard bytes.count <= maximumRequestBytes else {
            return .failure(.init(code: .requestTooLarge, requestID: nil))
        }
        guard !bytes.starts(with: [0xEF, 0xBB, 0xBF]),
              String(data: bytes, encoding: .utf8) != nil else {
            return .failure(.init(code: .invalidJSON, requestID: nil))
        }
        let value: BoundedJSONValue
        do {
            value = try BoundedJSONParser.parse(bytes)
        } catch {
            return .failure(.init(code: .invalidJSON, requestID: nil))
        }
        guard case let .object(root) = value else {
            return .failure(.init(code: .invalidRequest, requestID: nil))
        }
        let requestID: ClipyCLIRequestID?
        if let requestIDValue = root.value(named: "requestID"),
           case let .string(rawValue) = requestIDValue {
            requestID = ClipyCLIRequestID(validating: rawValue)
        } else {
            requestID = nil
        }
        func failure(_ code: ClipyCLIErrorCode) -> ClipyCLIRequestDecoding {
            .failure(.init(code: code, requestID: requestID))
        }
        guard root.hasExactly(keys: [
            "arguments", "operation", "protocolVersion", "requestID",
        ]) else {
            return failure(.invalidRequest)
        }
        guard case let .number(versionToken) = root.value(named: "protocolVersion"),
              let version = checkedInteger(versionToken) else {
            return failure(.invalidRequest)
        }
        guard version == protocolVersion else {
            return failure(.unsupportedProtocolVersion)
        }
        guard let requestID else { return failure(.invalidRequest) }
        guard case let .string(operation) = root.value(named: "operation") else {
            return failure(.invalidRequest)
        }
        guard operation == "browsePreview" else {
            return failure(.unknownOperation)
        }
        guard case let .object(argumentObject) = root.value(named: "arguments"),
              let arguments = decodeBrowseArguments(argumentObject) else {
            return failure(.invalidRequest)
        }
        return .success(.browsePreview(requestID: requestID, arguments: arguments))
    }

    private static func decodeBrowseArguments(
        _ object: [(String, BoundedJSONValue)]
    ) -> ClipyCLIBrowseArguments? {
        let hasQuery = object.value(named: "query") != nil
        let hasMode = object.value(named: "mode") != nil
        let allowedKeys = hasQuery || hasMode
            ? ["cursor", "limit", "mode", "query"]
            : ["cursor", "limit"]
        guard object.hasOnly(keys: allowedKeys),
              case let .number(limitToken) = object.value(named: "limit"),
              let limit = checkedInteger(limitToken), (1...500).contains(limit) else {
            return nil
        }
        let cursor: String?
        if let cursorValue = object.value(named: "cursor") {
            guard case let .string(value) = cursorValue,
                  isNonemptyUTF8(value, atMost: 4_096) else {
                return nil
            }
            cursor = value
        } else {
            cursor = nil
        }
        if !hasQuery && !hasMode {
            return .recent(limit: limit, cursor: cursor)
        }
        guard hasQuery && hasMode,
              case let .string(query) = object.value(named: "query"),
              isNonemptyUTF8(query, atMost: 4_096),
              case let .string(modeValue) = object.value(named: "mode"),
              let mode = ClipyCLISearchMode(rawValue: modeValue) else {
            return nil
        }
        switch mode {
        case .exact: break
        case .fuzzy:
            guard query.count <= 64 else { return nil }
        case .regexp:
            guard query.count <= 512 else { return nil }
        }
        return .search(query: query, mode: mode, limit: limit, cursor: cursor)
    }

    private static func isNonemptyUTF8(_ value: String, atMost limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit
    }

    private static func checkedInteger(_ token: String) -> Int? {
        guard !token.contains("."), !token.contains("e"), !token.contains("E") else {
            return nil
        }
        return Int(token)
    }
}

package enum ClipyCLIRequestDecoding: Equatable, Sendable {
    case success(ClipyCLIRequest)
    case failure(ClipyCLIRequestFailure)
}

package struct ClipyCLIRequestFailure: Equatable, Sendable {
    package let code: ClipyCLIErrorCode
    package let requestID: ClipyCLIRequestID?

    fileprivate init(code: ClipyCLIErrorCode, requestID: ClipyCLIRequestID?) {
        self.code = code
        self.requestID = requestID
    }
}

package struct ClipyCLIRequestID: Equatable, Sendable {
    package let rawValue: String

    package init?(_ rawValue: String) {
        guard let validated = Self(validating: rawValue) else { return nil }
        self = validated
    }

    fileprivate init?(validating rawValue: String) {
        guard rawValue.utf8.count == 36,
              rawValue == rawValue.lowercased(),
              rawValue != "00000000-0000-0000-0000-000000000000",
              let uuid = UUID(uuidString: rawValue),
              uuid.uuidString.lowercased() == rawValue else {
            return nil
        }
        self.rawValue = rawValue
    }
}

package enum ClipyCLIRequest: Equatable, Sendable {
    case browsePreview(
        requestID: ClipyCLIRequestID,
        arguments: ClipyCLIBrowseArguments
    )

    package var requestID: ClipyCLIRequestID {
        switch self {
        case let .browsePreview(requestID, _): requestID
        }
    }

    package var arguments: ClipyCLIBrowseArguments {
        switch self {
        case let .browsePreview(_, arguments): arguments
        }
    }
}

package enum ClipyCLIBrowseArguments: Equatable, Sendable {
    case recent(limit: Int, cursor: String?)
    case search(query: String, mode: ClipyCLISearchMode, limit: Int, cursor: String?)

    package var limit: Int {
        switch self {
        case let .recent(limit, _), let .search(_, _, limit, _): limit
        }
    }
}

package enum ClipyCLISearchMode: String, Equatable, Sendable {
    case exact
    case fuzzy
    case regexp
}

private extension Array where Element == (String, BoundedJSONValue) {
    func value(named name: String) -> BoundedJSONValue? {
        first(where: { $0.0.utf8.elementsEqual(name.utf8) })?.1
    }

    func hasExactly(keys: [String]) -> Bool {
        count == keys.count && hasOnly(keys: keys)
    }

    func hasOnly(keys: [String]) -> Bool {
        allSatisfy { member in
            keys.contains { $0.utf8.elementsEqual(member.0.utf8) }
        }
    }
}
