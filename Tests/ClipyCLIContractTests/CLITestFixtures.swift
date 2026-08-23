import ClipyCLIContract
import Foundation

let validRequestID = "9bd92054-bd3f-4d20-8f8a-5d77aa63b726"

func requestBytes(
    version: String = "1",
    requestID: String = validRequestID,
    operation: String = "browsePreview",
    arguments: String = "{\"limit\":20}"
) -> Data {
    Data(
        "{\"protocolVersion\":\(version),\"requestID\":\"\(requestID)\"," +
            "\"operation\":\"\(operation)\",\"arguments\":\(arguments)}".utf8
    )
}

func failure(
    _ decoding: ClipyCLIRequestDecoding
) -> ClipyCLIRequestFailure? {
    guard case let .failure(value) = decoding else { return nil }
    return value
}

func decodedRequest(
    _ decoding: ClipyCLIRequestDecoding
) -> ClipyCLIRequest? {
    guard case let .success(value) = decoding else { return nil }
    return value
}

func utf8(_ data: Data) -> String? {
    String(data: data, encoding: .utf8)
}
