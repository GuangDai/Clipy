/// X.4 audit-payload codec gates. The literals and case tables here freeze the
/// binary contract in `V2-05` §4.4 independently of the implementation.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct OperationPayloadBlobV1Tests {
    private let itemID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    private let connectionID = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!

    @Test func literalBinaryContractIsStableAndUUIDIsExactlySixteenBytes() throws {
        let payload = OperationPayloadBlobV1(
            request: .details(itemID: itemID),
            result: .details(effectiveRepresentationCount: 2, revisionCount: 3)
        )
        let blob = try OperationPayloadBlobCodec.encode(
            payload,
            context: externalContext(
                operation: .readDetails,
                capability: .readContent
            )
        )

        #expect(blob == Data([
            0x00, 0x01,             // formatVersion
            0x00, 0x03,             // request tag: details
            0x00, 0x11, 0x22, 0x33, // UUID, network byte order (16 bytes)
            0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB,
            0xCC, 0xDD, 0xEE, 0xFF,
            0x00, 0x03,             // result tag: details
            0x00, 0x02,             // representation count
            0x00, 0x03,             // revision count
        ]))
    }

    @Test func allSeventeenRequestTagsRoundTrip() throws {
        let cases: [(UInt16, OperationPayloadBlobV1, OperationPayloadRecordContextV1)] = [
            (1, .init(request: .recent(limit: 500), result: .page(returnedCount: 3, hasMore: true)), externalContext(operation: .readRecent, capability: .browse)),
            (2, .init(request: .search(queryUTF8ByteCount: 4_096, mode: .regexp, limit: 1), result: .page(returnedCount: 0, hasMore: false)), externalContext(operation: .readSearch, capability: .browsePreview)),
            (3, .init(request: .details(itemID: itemID), result: .details(effectiveRepresentationCount: 2, revisionCount: 3)), externalContext(operation: .readDetails, capability: .readContent)),
            (4, .init(request: .pastePayload(itemID: itemID), result: .pastePayload(representationCount: 2)), externalContext(operation: .readPastePayload, capability: .readContent)),
            (5, .init(request: .pin(itemID: itemID), result: .affectedItemIDs([itemID])), externalContext(operation: .managePin, capability: .manage, changePosition: 7)),
            (6, .init(request: .unpin(itemID: itemID), result: .affectedItemIDs([itemID])), externalContext(operation: .manageUnpin, capability: .organize, changePosition: 8)),
            (7, .init(request: .remove(itemID: itemID), result: .affectedItemIDs([itemID])), externalContext(operation: .manageRemove, capability: .deleteItem, changePosition: 9)),
            (8, .init(request: .enroll(kind: .appIntents, displayNameUTF8ByteCount: 12, credentialWasProvided: false), result: .enrolled(connectionID: connectionID)), adminContext(connectionID: connectionID, operation: .adminEnroll)),
            (9, .init(request: .grant(connectionID: connectionID, capability: .browse), result: .grantChanged(true)), adminContext(connectionID: connectionID, capability: .browse, operation: .adminGrant)),
            (10, .init(request: .revokeConnection(connectionID: connectionID), result: .connectionRevoked(revokedGrantCount: 8)), adminContext(connectionID: connectionID, operation: .adminRevoke)),
            (11, .init(request: .rebase(reason: .adminForced), result: .rebased(oldFloor: 2, newFloor: 4, discardedCount: 2)), adminContext(operation: .adminRebase, nextAuditSequence: 20)),
            (12, .init(request: .compact, result: .compacted(oldFloor: 2, newFloor: 4, discardedCount: 2, discardedPayloadBytes: 99)), adminContext(operation: .adminCompact, nextAuditSequence: 20)),
            (13, .init(request: .readEffectiveContent(itemID: itemID), result: .effectiveContent(representationCount: 2, totalBytes: 99)), externalContext(operation: .readEffectiveContent, capability: .readEffectiveContent)),
            (14, .init(request: .revokeCapability(connectionID: connectionID, capability: .manage), result: .capabilityRevoked(true)), adminContext(connectionID: connectionID, capability: .manage, operation: .adminRevokeCapability)),
            (15, .init(request: .readConnections, result: .connections(returnedCount: 4)), adminContext(operation: .adminReadConnections)),
            (16, .init(request: .readGrants(connectionID: connectionID), result: .grants(returnedCount: 3)), adminContext(connectionID: connectionID, operation: .adminReadGrants)),
            (17, .init(request: .readAudit(since: 42, limit: 500), result: .auditPage(returnedCount: 5, snapshotHead: 77)), adminContext(operation: .adminReadAudit, auditSequence: 77)),
        ]

        for (expectedTag, payload, context) in cases {
            let blob = try OperationPayloadBlobCodec.encode(payload, context: context)
            #expect(blob.prefix(4).suffix(2) == Data.bigEndian(expectedTag))
            #expect(try OperationPayloadBlobCodec.decode(blob, context: context) == payload)
            #expect(try OperationPayloadBlobCodec.encode(payload, context: context) == blob)
        }
    }

    @Test func allFifteenResultTagsHaveStableRawValues() throws {
        let failed = adminContext(
            operation: .adminReadConnections,
            outcome: .failed,
            failureKind: .persistence
        )
        let cases: [(UInt16, OperationPayloadBlobV1, OperationPayloadRecordContextV1)] = [
            (1, .init(request: .readConnections, result: .none), failed),
            (2, .init(request: .recent(limit: 1), result: .page(returnedCount: 0, hasMore: false)), externalContext(operation: .readRecent, capability: .browse)),
            (3, .init(request: .details(itemID: itemID), result: .details(effectiveRepresentationCount: .max, revisionCount: .max)), externalContext(operation: .readDetails, capability: .readContent)),
            (4, .init(request: .pastePayload(itemID: itemID), result: .pastePayload(representationCount: .max)), externalContext(operation: .readPastePayload, capability: .readContent)),
            (5, .init(request: .pin(itemID: itemID), result: .affectedItemIDs([itemID])), externalContext(operation: .managePin, capability: .manage, changePosition: 1)),
            (6, .init(request: .enroll(kind: .localAutomation, displayNameUTF8ByteCount: 0, credentialWasProvided: false), result: .enrolled(connectionID: connectionID)), adminContext(connectionID: connectionID, operation: .adminEnroll)),
            (7, .init(request: .grant(connectionID: connectionID, capability: .browse), result: .grantChanged(true)), adminContext(connectionID: connectionID, capability: .browse, operation: .adminGrant)),
            (8, .init(request: .revokeConnection(connectionID: connectionID), result: .connectionRevoked(revokedGrantCount: 0)), adminContext(connectionID: connectionID, operation: .adminRevoke)),
            (9, .init(request: .revokeCapability(connectionID: connectionID, capability: .browse), result: .capabilityRevoked(true)), adminContext(connectionID: connectionID, capability: .browse, operation: .adminRevokeCapability)),
            (10, .init(request: .readConnections, result: .connections(returnedCount: 500)), adminContext(operation: .adminReadConnections)),
            (11, .init(request: .readGrants(connectionID: connectionID), result: .grants(returnedCount: 8)), adminContext(connectionID: connectionID, operation: .adminReadGrants)),
            (12, .init(request: .readAudit(since: 0, limit: 500), result: .auditPage(returnedCount: 500, snapshotHead: .max)), adminContext(operation: .adminReadAudit, auditSequence: .max)),
            (13, .init(request: .rebase(reason: .corruptionDetected), result: .rebased(oldFloor: 0, newFloor: UInt64(UInt32.max), discardedCount: .max)), adminContext(operation: .adminRebase, nextAuditSequence: UInt64(UInt32.max))),
            (14, .init(request: .compact, result: .compacted(oldFloor: 0, newFloor: UInt64(UInt32.max), discardedCount: .max, discardedPayloadBytes: .max)), adminContext(operation: .adminCompact, nextAuditSequence: UInt64(UInt32.max))),
            (15, .init(request: .readEffectiveContent(itemID: itemID), result: .effectiveContent(representationCount: .max, totalBytes: .max)), externalContext(operation: .readEffectiveContent, capability: .readEffectiveContent)),
        ]

        for (expectedTag, payload, context) in cases {
            let blob = try OperationPayloadBlobCodec.encode(payload, context: context)
            let resultOffset = resultTagOffset(in: blob)!
            #expect(blob[resultOffset..<(resultOffset + 2)] == Data.bigEndian(expectedTag))
            #expect(try OperationPayloadBlobCodec.decode(blob, context: context) == payload)
        }
    }

    @Test func privacySentinelsAreNeverPresent() throws {
        let forbidden = [
            Data("PRIVATE_QUERY_SENTINEL".utf8),
            Data("PRIVATE_DISPLAY_NAME_SENTINEL".utf8),
            Data("PRIVATE_CREDENTIAL_SENTINEL".utf8),
            Data("PRIVATE_CLIPBOARD_CONTENT_SENTINEL".utf8),
        ]
        let fixtures: [(OperationPayloadBlobV1, OperationPayloadRecordContextV1)] = [
            (.init(request: .search(queryUTF8ByteCount: UInt16(forbidden[0].count), mode: .exact, limit: 20), result: .page(returnedCount: 2, hasMore: false)), externalContext(operation: .readSearch, capability: .browse)),
            (.init(request: .enroll(kind: .appIntents, displayNameUTF8ByteCount: UInt16(forbidden[1].count), credentialWasProvided: true), result: .none), adminContext(operation: .adminEnroll, outcome: .denied, failureKind: .requestDenied, denialReason: .invalidInput)),
            (.init(request: .readEffectiveContent(itemID: itemID), result: .effectiveContent(representationCount: 1, totalBytes: UInt64(forbidden[3].count))), externalContext(operation: .readEffectiveContent, capability: .readEffectiveContent)),
        ]

        for (payload, context) in fixtures {
            let blob = try OperationPayloadBlobCodec.encode(payload, context: context)
            for sentinel in forbidden {
                #expect(blob.range(of: sentinel) == nil)
            }
        }
    }

    @Test func decodeRejectsEnvelopeBeforeParsingAndEncodeChecksOutput() throws {
        let limits = makeLimits(maximumPayloadBytes: 33)
        #expect(throws: OperationPayloadCodecRejection.blobExceedsLimit(found: 34, bound: 33)) {
            try OperationPayloadBlobCodec.decode(
                Data(repeating: 0, count: 34),
                context: adminContext(operation: .adminCompact),
                limits: limits
            )
        }

        let payload = OperationPayloadBlobV1(
            request: .compact,
            result: .compacted(oldFloor: 0, newFloor: 0, discardedCount: 0, discardedPayloadBytes: 0)
        )
        let standardBlob = try OperationPayloadBlobCodec.encode(
            payload,
            context: adminContext(
                operation: .adminCompact,
                outcome: .noOp,
                nextAuditSequence: 0
            )
        )
        #expect(standardBlob.count == 34)
        #expect(throws: OperationPayloadCodecRejection.blobExceedsLimit(found: 34, bound: 33)) {
            try OperationPayloadBlobCodec.encode(
                payload,
                context: adminContext(
                    operation: .adminCompact,
                    outcome: .noOp,
                    nextAuditSequence: 0
                ),
                limits: limits
            )
        }
    }

    @Test func decodeRejectsRawAndStructuralCorruption() throws {
        let payload = OperationPayloadBlobV1(
            request: .search(queryUTF8ByteCount: 3, mode: .fuzzy, limit: 2),
            result: .page(returnedCount: 1, hasMore: true)
        )
        let context = externalContext(operation: .readSearch, capability: .browse)
        let valid = try OperationPayloadBlobCodec.encode(payload, context: context)

        var wrongVersion = valid
        wrongVersion[1] = 2
        #expect(throws: OperationPayloadCodecRejection.unknownVersion(found: 2)) {
            try OperationPayloadBlobCodec.decode(wrongVersion, context: context)
        }

        for replacement in [UInt16(0), 18, .max] {
            var unknownRequest = valid
            unknownRequest.replaceSubrange(2..<4, with: Data.bigEndian(replacement))
            #expect(throws: OperationPayloadCodecRejection.unknownRequestTag(replacement)) {
                try OperationPayloadBlobCodec.decode(unknownRequest, context: context)
            }
        }

        var unknownSearchMode = valid
        unknownSearchMode.replaceSubrange(6..<8, with: Data.bigEndian(UInt16(4)))
        #expect(throws: OperationPayloadCodecRejection.unknownEnumRaw(4)) {
            try OperationPayloadBlobCodec.decode(unknownSearchMode, context: context)
        }

        let resultOffset = resultTagOffset(in: valid)!
        var unknownResult = valid
        unknownResult.replaceSubrange(resultOffset..<(resultOffset + 2), with: Data.bigEndian(UInt16(16)))
        #expect(throws: OperationPayloadCodecRejection.unknownResultTag(16)) {
            try OperationPayloadBlobCodec.decode(unknownResult, context: context)
        }

        var invalidBool = valid
        invalidBool[valid.count - 1] = 2
        #expect(throws: OperationPayloadCodecRejection.invalidBoolean(2)) {
            try OperationPayloadBlobCodec.decode(invalidBool, context: context)
        }

        #expect(throws: OperationPayloadCodecRejection.malformedBlob) {
            try OperationPayloadBlobCodec.decode(valid.dropLast(), context: context)
        }
        #expect(throws: OperationPayloadCodecRejection.trailingBytes) {
            try OperationPayloadBlobCodec.decode(valid + Data([0]), context: context)
        }
    }

    @Test func decodeRejectsEveryCodecLocalEnumFamilyAndTruncatedUUID() throws {
        let fixtures: [(OperationPayloadBlobV1, OperationPayloadRecordContextV1, Int)] = [
            (
                .init(
                    request: .enroll(
                        kind: .appIntents,
                        displayNameUTF8ByteCount: 1,
                        credentialWasProvided: false
                    ),
                    result: .enrolled(connectionID: connectionID)
                ),
                adminContext(connectionID: connectionID, operation: .adminEnroll),
                4
            ),
            (
                .init(
                    request: .grant(
                        connectionID: connectionID,
                        capability: .browse
                    ),
                    result: .grantChanged(true)
                ),
                adminContext(
                    connectionID: connectionID,
                    capability: .browse,
                    operation: .adminGrant
                ),
                20
            ),
            (
                .init(
                    request: .rebase(reason: .adminForced),
                    result: .rebased(
                        oldFloor: 0,
                        newFloor: 0,
                        discardedCount: 0
                    )
                ),
                adminContext(
                    operation: .adminRebase,
                    nextAuditSequence: 0
                ),
                4
            ),
        ]

        for (payload, context, rawOffset) in fixtures {
            var blob = try OperationPayloadBlobCodec.encode(
                payload,
                context: context
            )
            blob.replaceSubrange(
                rawOffset..<(rawOffset + 2),
                with: Data.bigEndian(.max)
            )
            #expect(throws: OperationPayloadCodecRejection.unknownEnumRaw(.max)) {
                try OperationPayloadBlobCodec.decode(blob, context: context)
            }
        }

        let details = OperationPayloadBlobV1(
            request: .details(itemID: itemID),
            result: .details(
                effectiveRepresentationCount: 1,
                revisionCount: 1
            )
        )
        let context = externalContext(
            operation: .readDetails,
            capability: .readContent
        )
        let valid = try OperationPayloadBlobCodec.encode(details, context: context)
        #expect(throws: OperationPayloadCodecRejection.malformedBlob) {
            try OperationPayloadBlobCodec.decode(
                Data(valid.prefix(4 + 15)),
                context: context
            )
        }
    }

    @Test func requestAndResultBoundsFailClosed() throws {
        let recent = externalContext(operation: .readRecent, capability: .browse)
        let search = externalContext(operation: .readSearch, capability: .browse)
        let readAudit = adminContext(operation: .adminReadAudit)

        for limit in [UInt16(0), 501] {
            expectIncompatible(.init(request: .recent(limit: limit), result: .page(returnedCount: 0, hasMore: false)), context: recent)
            expectIncompatible(.init(request: .search(queryUTF8ByteCount: 0, mode: .exact, limit: limit), result: .page(returnedCount: 0, hasMore: false)), context: search)
            expectIncompatible(.init(request: .readAudit(since: 0, limit: limit), result: .auditPage(returnedCount: 0, snapshotHead: 0)), context: readAudit)
        }
        expectIncompatible(.init(request: .search(queryUTF8ByteCount: 4_097, mode: .exact, limit: 1), result: .page(returnedCount: 0, hasMore: false)), context: search)
        expectIncompatible(.init(request: .enroll(kind: .appIntents, displayNameUTF8ByteCount: 257, credentialWasProvided: false), result: .enrolled(connectionID: connectionID)), context: adminContext(connectionID: connectionID, operation: .adminEnroll))
        expectIncompatible(.init(request: .recent(limit: 1), result: .page(returnedCount: 501, hasMore: false)), context: recent)
        expectIncompatible(.init(request: .readConnections, result: .connections(returnedCount: 501)), context: adminContext(operation: .adminReadConnections))
        expectIncompatible(.init(request: .readGrants(connectionID: connectionID), result: .grants(returnedCount: 9)), context: adminContext(connectionID: connectionID, operation: .adminReadGrants))

        let tooManyIDs = Array(repeating: itemID, count: 33)
        expectIncompatible(.init(request: .pin(itemID: itemID), result: .affectedItemIDs(tooManyIDs)), context: externalContext(operation: .managePin, capability: .manage, changePosition: 1))
    }

    @Test func requestOperationAndTypedResultCompatibilityIsClosed() {
        expectIncompatible(.init(request: .details(itemID: itemID), result: .pastePayload(representationCount: 1)), context: externalContext(operation: .readDetails, capability: .readContent))
        expectIncompatible(.init(request: .details(itemID: itemID), result: .details(effectiveRepresentationCount: 1, revisionCount: 1)), context: externalContext(operation: .readSearch, capability: .readContent))
        expectIncompatible(.init(request: .grant(connectionID: connectionID, capability: .browse), result: .grantChanged(false)), context: adminContext(connectionID: connectionID, capability: .browse, operation: .adminGrant))
        expectIncompatible(.init(request: .recent(limit: 1), result: .page(returnedCount: 2, hasMore: false)), context: externalContext(operation: .readRecent, capability: .browse))
        expectIncompatible(.init(request: .pin(itemID: itemID), result: .affectedItemIDs([])), context: externalContext(operation: .managePin, capability: .manage, changePosition: 1))
        expectIncompatible(.init(request: .readAudit(since: 1, limit: 5), result: .auditPage(returnedCount: 1, snapshotHead: 4)), context: adminContext(operation: .adminReadAudit, auditSequence: 5))
        expectIncompatible(.init(request: .rebase(reason: .adminForced), result: .rebased(oldFloor: 1, newFloor: 3, discardedCount: 1)), context: adminContext(operation: .adminRebase, nextAuditSequence: 3))
        expectIncompatible(.init(request: .compact, result: .compacted(oldFloor: 1, newFloor: 3, discardedCount: 1, discardedPayloadBytes: 0)), context: adminContext(operation: .adminCompact, nextAuditSequence: 3))

        let grantNoOp = OperationPayloadBlobV1(request: .grant(connectionID: connectionID, capability: .browse), result: .grantChanged(false))
        #expect(throws: Never.self) {
            _ = try OperationPayloadBlobCodec.encode(grantNoOp, context: adminContext(connectionID: connectionID, capability: .browse, operation: .adminGrant, outcome: .noOp))
        }

        expectIncompatible(
            .init(
                request: .revokeConnection(connectionID: connectionID),
                result: .connectionRevoked(revokedGrantCount: 1)
            ),
            context: adminContext(
                connectionID: connectionID,
                operation: .adminRevoke,
                outcome: .noOp
            )
        )
        expectIncompatible(
            .init(
                request: .compact,
                result: .compacted(
                    oldFloor: 1,
                    newFloor: 2,
                    discardedCount: 1,
                    discardedPayloadBytes: 1
                )
            ),
            context: adminContext(
                operation: .adminCompact,
                outcome: .noOp,
                nextAuditSequence: 2
            )
        )
    }

    @Test func outcomeFailureAndChangePositionCompatibilityIsClosed() {
        let details = OperationPayloadBlobV1(request: .details(itemID: itemID), result: .none)
        expectIncompatible(details, context: externalContext(operation: .readDetails, capability: .readContent, outcome: .denied, failureKind: nil))
        expectIncompatible(details, context: externalContext(operation: .readDetails, capability: .readContent, outcome: .denied, failureKind: .requestDenied))
        expectIncompatible(details, context: externalContext(operation: .readDetails, capability: .readContent, outcome: .denied, failureKind: .unauthorized, denialReason: .rateLimited))
        expectIncompatible(details, context: externalContext(operation: .readDetails, capability: .readContent, outcome: .failed, failureKind: .unauthorized))
        expectIncompatible(details, context: externalContext(operation: .readDetails, capability: .readContent, outcome: .failed, failureKind: .history, changePosition: 1))
        expectIncompatible(.init(request: .details(itemID: itemID), result: .details(effectiveRepresentationCount: 0, revisionCount: 0)), context: externalContext(operation: .readDetails, capability: .readContent, outcome: .noOp))
        expectIncompatible(.init(request: .pin(itemID: itemID), result: .affectedItemIDs([itemID])), context: externalContext(operation: .managePin, capability: .manage))
        expectIncompatible(.init(request: .pin(itemID: itemID), result: .affectedItemIDs([itemID])), context: externalContext(operation: .managePin, capability: .manage, changePosition: 0))

        let denied = adminContext(operation: .adminEnroll, outcome: .denied, failureKind: .requestDenied, denialReason: .rateLimited)
        #expect(throws: Never.self) {
            _ = try OperationPayloadBlobCodec.encode(.init(request: .enroll(kind: .appIntents, displayNameUTF8ByteCount: 1, credentialWasProvided: false), result: .none), context: denied)
        }
    }

    @Test func attributionIsExactIncludingEnrollAndGlobalAdminCases() {
        let enroll = OperationPayloadBlobV1(request: .enroll(kind: .appIntents, displayNameUTF8ByteCount: 1, credentialWasProvided: false), result: .enrolled(connectionID: connectionID))
        expectIncompatible(enroll, context: adminContext(operation: .adminEnroll))
        expectIncompatible(enroll, context: adminContext(connectionID: UUID(), operation: .adminEnroll))

        let deniedEnroll = OperationPayloadBlobV1(request: .enroll(kind: .appIntents, displayNameUTF8ByteCount: 1, credentialWasProvided: false), result: .none)
        expectIncompatible(deniedEnroll, context: adminContext(connectionID: connectionID, operation: .adminEnroll, outcome: .denied, failureKind: .requestDenied, denialReason: .invalidInput))

        let global = OperationPayloadBlobV1(request: .readConnections, result: .connections(returnedCount: 0))
        expectIncompatible(global, context: adminContext(connectionID: connectionID, operation: .adminReadConnections))
        expectIncompatible(global, context: adminContext(capability: .manage, operation: .adminReadConnections))

        let grant = OperationPayloadBlobV1(request: .grant(connectionID: connectionID, capability: .browse), result: .grantChanged(true))
        expectIncompatible(grant, context: adminContext(connectionID: connectionID, capability: .manage, operation: .adminGrant))
    }

    @Test func rebaseCompactAndCompactedReadUseCounterContext() {
        expectIncompatible(
            .init(request: .rebase(reason: .adminForced), result: .rebased(oldFloor: 4, newFloor: 3, discardedCount: 1)),
            context: adminContext(operation: .adminRebase, nextAuditSequence: 10)
        )
        expectIncompatible(
            .init(request: .compact, result: .compacted(oldFloor: 1, newFloor: 11, discardedCount: 1, discardedPayloadBytes: 1)),
            context: adminContext(operation: .adminCompact, nextAuditSequence: 10)
        )

        let compacted = OperationPayloadBlobV1(request: .readAudit(since: 4, limit: 1), result: .none)
        #expect(throws: Never.self) {
            _ = try OperationPayloadBlobCodec.encode(
                compacted,
                context: adminContext(operation: .adminReadAudit, outcome: .failed, failureKind: .auditCompactedBefore, compactionFloor: 5)
            )
        }
        expectIncompatible(
            compacted,
            context: adminContext(operation: .adminReadAudit, outcome: .failed, failureKind: .auditCompactedBefore, compactionFloor: 4)
        )
    }

    private func externalContext(
        operation: ExternalOperationKind,
        capability: ExternalCapability,
        outcome: ExternalOutcome = .succeeded,
        failureKind: ExternalFailureKindRaw? = nil,
        denialReason: ExternalDenialReason? = nil,
        changePosition: UInt64? = nil
    ) -> OperationPayloadRecordContextV1 {
        .init(
            connectionID: connectionID,
            capability: capability,
            operationKind: operation,
            outcome: outcome,
            failureKind: failureKind,
            denialReason: denialReason,
            changePosition: changePosition
        )
    }

    private func adminContext(
        connectionID: UUID? = nil,
        capability: ExternalCapability? = nil,
        operation: ExternalOperationKind,
        outcome: ExternalOutcome = .succeeded,
        failureKind: ExternalFailureKindRaw? = nil,
        denialReason: ExternalDenialReason? = nil,
        changePosition: UInt64? = nil,
        compactionFloor: UInt64? = nil,
        nextAuditSequence: UInt64? = nil,
        auditSequence: UInt64? = nil
    ) -> OperationPayloadRecordContextV1 {
        .init(
            connectionID: connectionID,
            capability: capability,
            operationKind: operation,
            outcome: outcome,
            failureKind: failureKind,
            denialReason: denialReason,
            changePosition: changePosition,
            auditSequence: auditSequence,
            compactionFloor: compactionFloor,
            nextAuditSequence: nextAuditSequence
        )
    }

    private func makeLimits(maximumPayloadBytes: Int) -> ExternalLimits {
        ExternalLimits(
            maximumDisplayNameUTF8Bytes: 256,
            maximumConnections: 500,
            maximumGrantRowsPerConnection: 8,
            maxAffectedItemsPerRecord: 32,
            maxAuditLogSize: 64 * 1_048_576,
            auditRecordAccountingOverheadBytes: 128,
            maximumAuditPayloadBlobBytes: maximumPayloadBytes,
            maxAuditAgeSeconds: 31_536_000,
            compactionCadenceOps: 100,
            maxAuditReadBatchSize: 500,
            externalBrowseLimitLowerBound: 1,
            externalBrowseLimitUpperBound: 500
        )!
    }

    private func resultTagOffset(in blob: Data) -> Int? {
        guard blob.count >= 4 else { return nil }
        let tag = UInt16(blob[2]) << 8 | UInt16(blob[3])
        let requestBodyBytes: Int
        switch tag {
        case 1, 11: requestBodyBytes = 2
        case 2: requestBodyBytes = 6
        case 3, 4, 5, 6, 7, 10, 13, 16: requestBodyBytes = 16
        case 8: requestBodyBytes = 5
        case 9, 14: requestBodyBytes = 18
        case 12, 15: requestBodyBytes = 0
        case 17: requestBodyBytes = 10
        default: return nil
        }
        let offset = 4 + requestBodyBytes
        return blob.count >= offset + 2 ? offset : nil
    }

    private func expectIncompatible(
        _ payload: OperationPayloadBlobV1,
        context: OperationPayloadRecordContextV1
    ) {
        #expect(throws: OperationPayloadCodecRejection.incompatibleRecord) {
            try OperationPayloadBlobCodec.encode(payload, context: context)
        }
    }
}

private extension Data {
    static func bigEndian(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }
}
