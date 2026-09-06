import ClipyCLIContract
import Foundation
import Testing

struct LocalAutomationOperationCodecTests {
    @Test(arguments: ["detailsEffective", "pasteEffective", "pin", "unpin", "delete"])
    func itemOperationsRequireOnlyAnOpaqueLocator(operation: String) throws {
        let bytes = requestBytes(operation: operation, arguments: #"{"locator":"i1_opaque"}"#)
        let request = try #require(decodedRequest(ClipyCLIContract.decodeRequest(bytes)))
        #expect(request.requestID.rawValue == validRequestID)
        #expect(request.arguments == nil)
        #expect(request.isMutation == ["pin", "unpin", "delete"].contains(operation))
        for arguments in [#"{}"#, #"{"locator":""}"#, #"{"locator":3}"#,
                          #"{"locator":"value","limit":1}"#] {
            #expect(failure(ClipyCLIContract.decodeRequest(requestBytes(
                operation: operation, arguments: arguments
            )))?.code == .invalidRequest)
        }
    }

    @Test func effectiveReplyPreservesBinaryBytesAndExposesOnlyEffectiveFields() throws {
        let request = try #require(decodedRequest(ClipyCLIContract.decodeRequest(
            requestBytes(operation: "detailsEffective", arguments: #"{"locator":"i1_a"}"#)
        )))
        let effective = try ClipyCLIEffectiveResult(locator: "i1_a", representations: [
            .init(typeIdentifier: "com.example.binary", bytes: Data([0, 255, 10]))
        ])
        let output = ClipyCLIContract.render(.success(for: request, effective: effective))
        #expect(output.exitCode == 0)
        #expect(output.stderr.isEmpty)
        #expect(String(decoding: output.stdout, as: UTF8.self) ==
            "{\"ok\":true,\"protocolVersion\":1,\"requestID\":\"\(validRequestID)\",\"result\":{\"locator\":\"i1_a\",\"representations\":[{\"bytesBase64\":\"AP8K\",\"typeIdentifier\":\"com.example.binary\"}]}}\n")
    }

    @Test(arguments: [false, true])
    func mutationReportsTheActualChangedState(changed: Bool) throws {
        let request = try #require(decodedRequest(ClipyCLIContract.decodeRequest(
            requestBytes(operation: "pin", arguments: #"{"locator":"i1_a"}"#)
        )))
        let output = ClipyCLIContract.render(.success(for: request, changed: changed))
        #expect(output.exitCode == 0)
        #expect(output.stderr.isEmpty)
        #expect(String(decoding: output.stdout, as: UTF8.self) ==
            "{\"ok\":true,\"protocolVersion\":1,\"requestID\":\"\(validRequestID)\",\"result\":{\"changed\":\(changed)}}\n")
    }

    @Test func effectiveContentBudgetIsCheckedBeforeBase64Rendering() {
        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try ClipyCLIEffectiveResult(locator: "i1_a", representations: [
                .init(typeIdentifier: "com.example.binary", bytes: Data(
                    repeating: 0, count: ClipyCLIEffectiveResult.maximumContentBytes + 1
                ))
            ])
        }
    }
}
