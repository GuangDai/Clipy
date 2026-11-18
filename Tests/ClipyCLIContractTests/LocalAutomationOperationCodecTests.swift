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

    @Test func effectiveContentBudgetIsCheckedBeforeBase64Rendering() {
        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try ClipyCLIEffectiveResult(locator: "i1_a", contentVersion: 1, representations: [
                .init(typeIdentifier: "com.example.binary", bytes: Data(
                    repeating: 0, count: ClipyCLIEffectiveResult.maximumContentBytes + 1
                ))
            ])
        }
    }
}
