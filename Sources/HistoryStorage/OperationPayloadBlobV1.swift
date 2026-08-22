/// Explicit binary audit-payload contract for the X.4 Gateway substrate.
/// Owning spec: `docs/v2/V2-05-external-gateway.md` §4.4.
///
/// This codec intentionally does not use synthesized `Codable` or an
/// extensible container. Every field and tag is spelled out below. Multi-byte
/// integers and UUID bytes use network byte order.
import Foundation
import HistoryCore

// MARK: - Closed wire values

internal enum SearchModeRawV1: UInt16, Sendable, Equatable, CaseIterable {
    case exact = 1
    case fuzzy = 2
    case regexp = 3
}

internal enum RequestSummaryV1: Sendable, Equatable {
    case recent(limit: UInt16)
    case search(
        queryUTF8ByteCount: UInt16,
        mode: SearchModeRawV1,
        limit: UInt16
    )
    case details(itemID: UUID)
    case pastePayload(itemID: UUID)
    case pin(itemID: UUID)
    case unpin(itemID: UUID)
    case remove(itemID: UUID)
    case enroll(
        kind: ConnectionEnrollKind,
        displayNameUTF8ByteCount: UInt16,
        credentialWasProvided: Bool
    )
    case grant(connectionID: UUID, capability: ExternalCapability)
    case revokeConnection(connectionID: UUID)
    case rebase(reason: AuditRebaseReason)
    case compact
    case readEffectiveContent(itemID: UUID)
    case revokeCapability(
        connectionID: UUID,
        capability: ExternalCapability
    )
    case readConnections
    case readGrants(connectionID: UUID)
    case readAudit(since: UInt64, limit: UInt16)
}

internal enum ResultSummaryV1: Sendable, Equatable {
    case none
    case page(returnedCount: UInt16, hasMore: Bool)
    case details(
        effectiveRepresentationCount: UInt16,
        revisionCount: UInt16
    )
    case pastePayload(representationCount: UInt16)
    case affectedItemIDs([UUID])
    case enrolled(connectionID: UUID)
    case grantChanged(Bool)
    case connectionRevoked(revokedGrantCount: UInt16)
    case capabilityRevoked(Bool)
    case connections(returnedCount: UInt16)
    case grants(returnedCount: UInt16)
    case auditPage(returnedCount: UInt16, snapshotHead: UInt64)
    case rebased(oldFloor: UInt64, newFloor: UInt64, discardedCount: UInt32)
    case compacted(
        oldFloor: UInt64,
        newFloor: UInt64,
        discardedCount: UInt32,
        discardedPayloadBytes: UInt64
    )
    case effectiveContent(representationCount: UInt16, totalBytes: UInt64)
}

internal struct OperationPayloadBlobV1: Sendable, Equatable {
    internal let formatVersion: UInt16
    internal let request: RequestSummaryV1
    internal let result: ResultSummaryV1

    internal init(
        formatVersion: UInt16 = 1,
        request: RequestSummaryV1,
        result: ResultSummaryV1
    ) {
        self.formatVersion = formatVersion
        self.request = request
        self.result = result
    }
}

/// Retained scalar columns needed to validate a payload as one coherent audit
/// record. The optional counter facts are supplied by the audit-store reader:
/// they are not duplicated into the payload.
internal struct OperationPayloadRecordContextV1: Sendable {
    internal let connectionID: UUID?
    internal let capability: ExternalCapability?
    internal let operationKind: ExternalOperationKind
    internal let outcome: ExternalOutcome
    internal let failureKind: ExternalFailureKindRaw?
    internal let denialReason: ExternalDenialReason?
    internal let changePosition: UInt64?
    internal let auditSequence: UInt64?
    internal let compactionFloor: UInt64?
    internal let nextAuditSequence: UInt64?

    internal init(
        connectionID: UUID?,
        capability: ExternalCapability?,
        operationKind: ExternalOperationKind,
        outcome: ExternalOutcome,
        failureKind: ExternalFailureKindRaw?,
        denialReason: ExternalDenialReason?,
        changePosition: UInt64?,
        auditSequence: UInt64? = nil,
        compactionFloor: UInt64? = nil,
        nextAuditSequence: UInt64? = nil
    ) {
        self.connectionID = connectionID
        self.capability = capability
        self.operationKind = operationKind
        self.outcome = outcome
        self.failureKind = failureKind
        self.denialReason = denialReason
        self.changePosition = changePosition
        self.auditSequence = auditSequence
        self.compactionFloor = compactionFloor
        self.nextAuditSequence = nextAuditSequence
    }
}

internal enum OperationPayloadCodecRejection: Error, Sendable, Equatable {
    case malformedBlob
    case unknownVersion(found: UInt16)
    case unknownRequestTag(UInt16)
    case unknownResultTag(UInt16)
    case unknownEnumRaw(UInt16)
    case invalidBoolean(UInt8)
    case trailingBytes
    case blobExceedsLimit(found: Int, bound: Int)
    case incompatibleRecord
}

// MARK: - Codec

internal enum OperationPayloadBlobCodec {
    private static let formatVersion: UInt16 = 1
    private static let maximumQueryUTF8Bytes = 4_096

    internal static func encode(
        _ payload: OperationPayloadBlobV1,
        context: OperationPayloadRecordContextV1,
        limits: ExternalLimits = .standard
    ) throws -> Data {
        try validate(payload, context: context, limits: limits)

        var writer = OperationPayloadWriter()
        writer.append(payload.formatVersion)
        encode(payload.request, into: &writer)
        try encode(payload.result, into: &writer)

        let data = writer.data
        guard data.count <= limits.maximumAuditPayloadBlobBytes else {
            throw OperationPayloadCodecRejection.blobExceedsLimit(
                found: data.count,
                bound: limits.maximumAuditPayloadBlobBytes
            )
        }
        return data
    }

    internal static func decode(
        _ data: Data,
        context: OperationPayloadRecordContextV1,
        limits: ExternalLimits = .standard
    ) throws -> OperationPayloadBlobV1 {
        // The 16-KiB envelope is checked before even the first parse read.
        guard data.count <= limits.maximumAuditPayloadBlobBytes else {
            throw OperationPayloadCodecRejection.blobExceedsLimit(
                found: data.count,
                bound: limits.maximumAuditPayloadBlobBytes
            )
        }

        var reader = OperationPayloadReader(data: data)
        let version = try reader.readUInt16()
        guard version == formatVersion else {
            throw OperationPayloadCodecRejection.unknownVersion(found: version)
        }
        let request = try decodeRequest(from: &reader)
        let result = try decodeResult(from: &reader, limits: limits)
        guard reader.isAtEnd else {
            throw OperationPayloadCodecRejection.trailingBytes
        }

        let payload = OperationPayloadBlobV1(
            formatVersion: version,
            request: request,
            result: result
        )
        try validate(payload, context: context, limits: limits)
        return payload
    }

    // MARK: Encoding table

    private static func encode(
        _ request: RequestSummaryV1,
        into writer: inout OperationPayloadWriter
    ) {
        switch request {
        case .recent(let limit):
            writer.append(UInt16(1)); writer.append(limit)
        case .search(let byteCount, let mode, let limit):
            writer.append(UInt16(2)); writer.append(byteCount)
            writer.append(mode.rawValue); writer.append(limit)
        case .details(let itemID):
            writer.append(UInt16(3)); writer.append(itemID)
        case .pastePayload(let itemID):
            writer.append(UInt16(4)); writer.append(itemID)
        case .pin(let itemID):
            writer.append(UInt16(5)); writer.append(itemID)
        case .unpin(let itemID):
            writer.append(UInt16(6)); writer.append(itemID)
        case .remove(let itemID):
            writer.append(UInt16(7)); writer.append(itemID)
        case .enroll(let kind, let byteCount, let credentialWasProvided):
            writer.append(UInt16(8))
            writer.append(UInt16(bitPattern: kind.rawValue))
            writer.append(byteCount); writer.append(credentialWasProvided)
        case .grant(let connectionID, let capability):
            writer.append(UInt16(9)); writer.append(connectionID)
            writer.append(UInt16(bitPattern: capability.rawValue))
        case .revokeConnection(let connectionID):
            writer.append(UInt16(10)); writer.append(connectionID)
        case .rebase(let reason):
            writer.append(UInt16(11))
            writer.append(UInt16(bitPattern: reason.rawValue))
        case .compact:
            writer.append(UInt16(12))
        case .readEffectiveContent(let itemID):
            writer.append(UInt16(13)); writer.append(itemID)
        case .revokeCapability(let connectionID, let capability):
            writer.append(UInt16(14)); writer.append(connectionID)
            writer.append(UInt16(bitPattern: capability.rawValue))
        case .readConnections:
            writer.append(UInt16(15))
        case .readGrants(let connectionID):
            writer.append(UInt16(16)); writer.append(connectionID)
        case .readAudit(let since, let limit):
            writer.append(UInt16(17)); writer.append(since); writer.append(limit)
        }
    }

    private static func encode(
        _ result: ResultSummaryV1,
        into writer: inout OperationPayloadWriter
    ) throws {
        switch result {
        case .none:
            writer.append(UInt16(1))
        case .page(let count, let hasMore):
            writer.append(UInt16(2)); writer.append(count); writer.append(hasMore)
        case .details(let representationCount, let revisionCount):
            writer.append(UInt16(3)); writer.append(representationCount)
            writer.append(revisionCount)
        case .pastePayload(let representationCount):
            writer.append(UInt16(4)); writer.append(representationCount)
        case .affectedItemIDs(let itemIDs):
            guard let count = UInt16(exactly: itemIDs.count) else {
                throw OperationPayloadCodecRejection.incompatibleRecord
            }
            writer.append(UInt16(5)); writer.append(count)
            for itemID in itemIDs { writer.append(itemID) }
        case .enrolled(let connectionID):
            writer.append(UInt16(6)); writer.append(connectionID)
        case .grantChanged(let changed):
            writer.append(UInt16(7)); writer.append(changed)
        case .connectionRevoked(let revokedGrantCount):
            writer.append(UInt16(8)); writer.append(revokedGrantCount)
        case .capabilityRevoked(let revoked):
            writer.append(UInt16(9)); writer.append(revoked)
        case .connections(let returnedCount):
            writer.append(UInt16(10)); writer.append(returnedCount)
        case .grants(let returnedCount):
            writer.append(UInt16(11)); writer.append(returnedCount)
        case .auditPage(let returnedCount, let snapshotHead):
            writer.append(UInt16(12)); writer.append(returnedCount)
            writer.append(snapshotHead)
        case .rebased(let oldFloor, let newFloor, let discardedCount):
            writer.append(UInt16(13)); writer.append(oldFloor)
            writer.append(newFloor); writer.append(discardedCount)
        case .compacted(let oldFloor, let newFloor, let discardedCount, let bytes):
            writer.append(UInt16(14)); writer.append(oldFloor)
            writer.append(newFloor); writer.append(discardedCount)
            writer.append(bytes)
        case .effectiveContent(let representationCount, let totalBytes):
            writer.append(UInt16(15)); writer.append(representationCount)
            writer.append(totalBytes)
        }
    }

    // MARK: Decoding table

    private static func decodeRequest(
        from reader: inout OperationPayloadReader
    ) throws -> RequestSummaryV1 {
        let tag = try reader.readUInt16()
        switch tag {
        case 1: return .recent(limit: try reader.readUInt16())
        case 2:
            let byteCount = try reader.readUInt16()
            let mode = try decodeEnum(SearchModeRawV1.self, from: &reader)
            return .search(
                queryUTF8ByteCount: byteCount,
                mode: mode,
                limit: try reader.readUInt16()
            )
        case 3: return .details(itemID: try reader.readUUID())
        case 4: return .pastePayload(itemID: try reader.readUUID())
        case 5: return .pin(itemID: try reader.readUUID())
        case 6: return .unpin(itemID: try reader.readUUID())
        case 7: return .remove(itemID: try reader.readUUID())
        case 8:
            let kind = try decodeInt16Enum(ConnectionEnrollKind.self, from: &reader)
            return .enroll(
                kind: kind,
                displayNameUTF8ByteCount: try reader.readUInt16(),
                credentialWasProvided: try reader.readBool()
            )
        case 9:
            let connectionID = try reader.readUUID()
            return .grant(
                connectionID: connectionID,
                capability: try decodeInt16Enum(
                    ExternalCapability.self,
                    from: &reader
                )
            )
        case 10: return .revokeConnection(connectionID: try reader.readUUID())
        case 11:
            return .rebase(
                reason: try decodeInt16Enum(AuditRebaseReason.self, from: &reader)
            )
        case 12: return .compact
        case 13: return .readEffectiveContent(itemID: try reader.readUUID())
        case 14:
            let connectionID = try reader.readUUID()
            return .revokeCapability(
                connectionID: connectionID,
                capability: try decodeInt16Enum(
                    ExternalCapability.self,
                    from: &reader
                )
            )
        case 15: return .readConnections
        case 16: return .readGrants(connectionID: try reader.readUUID())
        case 17:
            return .readAudit(
                since: try reader.readUInt64(),
                limit: try reader.readUInt16()
            )
        default: throw OperationPayloadCodecRejection.unknownRequestTag(tag)
        }
    }

    private static func decodeResult(
        from reader: inout OperationPayloadReader,
        limits: ExternalLimits
    ) throws -> ResultSummaryV1 {
        let tag = try reader.readUInt16()
        switch tag {
        case 1: return .none
        case 2:
            return .page(
                returnedCount: try reader.readUInt16(),
                hasMore: try reader.readBool()
            )
        case 3:
            return .details(
                effectiveRepresentationCount: try reader.readUInt16(),
                revisionCount: try reader.readUInt16()
            )
        case 4:
            return .pastePayload(representationCount: try reader.readUInt16())
        case 5:
            let count = Int(try reader.readUInt16())
            // Enforce the semantic cap before reserving or constructing the
            // UUID array; multiplication is checked before the byte lookahead.
            guard count <= limits.maxAffectedItemsPerRecord else {
                throw OperationPayloadCodecRejection.incompatibleRecord
            }
            let (requiredBytes, overflow) = count.multipliedReportingOverflow(by: 16)
            guard !overflow, reader.remainingByteCount >= requiredBytes else {
                throw OperationPayloadCodecRejection.malformedBlob
            }
            var itemIDs: [UUID] = []
            itemIDs.reserveCapacity(count)
            for _ in 0..<count { itemIDs.append(try reader.readUUID()) }
            return .affectedItemIDs(itemIDs)
        case 6: return .enrolled(connectionID: try reader.readUUID())
        case 7: return .grantChanged(try reader.readBool())
        case 8:
            return .connectionRevoked(
                revokedGrantCount: try reader.readUInt16()
            )
        case 9: return .capabilityRevoked(try reader.readBool())
        case 10: return .connections(returnedCount: try reader.readUInt16())
        case 11: return .grants(returnedCount: try reader.readUInt16())
        case 12:
            return .auditPage(
                returnedCount: try reader.readUInt16(),
                snapshotHead: try reader.readUInt64()
            )
        case 13:
            return .rebased(
                oldFloor: try reader.readUInt64(),
                newFloor: try reader.readUInt64(),
                discardedCount: try reader.readUInt32()
            )
        case 14:
            return .compacted(
                oldFloor: try reader.readUInt64(),
                newFloor: try reader.readUInt64(),
                discardedCount: try reader.readUInt32(),
                discardedPayloadBytes: try reader.readUInt64()
            )
        case 15:
            return .effectiveContent(
                representationCount: try reader.readUInt16(),
                totalBytes: try reader.readUInt64()
            )
        default: throw OperationPayloadCodecRejection.unknownResultTag(tag)
        }
    }

    private static func decodeEnum<T: RawRepresentable>(
        _ type: T.Type,
        from reader: inout OperationPayloadReader
    ) throws -> T where T.RawValue == UInt16 {
        let raw = try reader.readUInt16()
        guard let value = T(rawValue: raw) else {
            throw OperationPayloadCodecRejection.unknownEnumRaw(raw)
        }
        return value
    }

    private static func decodeInt16Enum<T: RawRepresentable>(
        _ type: T.Type,
        from reader: inout OperationPayloadReader
    ) throws -> T where T.RawValue == Int16 {
        let wireRaw = try reader.readUInt16()
        guard wireRaw <= UInt16(Int16.max),
              let value = T(rawValue: Int16(wireRaw))
        else {
            throw OperationPayloadCodecRejection.unknownEnumRaw(wireRaw)
        }
        return value
    }

    // MARK: Whole-record compatibility

    private static func validate(
        _ payload: OperationPayloadBlobV1,
        context: OperationPayloadRecordContextV1,
        limits: ExternalLimits
    ) throws {
        guard payload.formatVersion == formatVersion,
              requestIsBounded(payload.request, limits: limits),
              resultIsBounded(payload.result, limits: limits),
              operationMatches(payload.request, context.operationKind),
              attributionMatches(payload, context: context),
              outcomeMatches(payload, context: context),
              summaryFactsMatch(payload, context: context),
              counterFactsMatch(payload.result, context: context)
        else {
            if payload.formatVersion != formatVersion {
                throw OperationPayloadCodecRejection.unknownVersion(
                    found: payload.formatVersion
                )
            }
            throw OperationPayloadCodecRejection.incompatibleRecord
        }
    }

    private static func requestIsBounded(
        _ request: RequestSummaryV1,
        limits: ExternalLimits
    ) -> Bool {
        switch request {
        case .recent(let limit):
            return limits.externalBrowseLimitRange.contains(Int(limit))
        case .search(let byteCount, _, let limit):
            return Int(byteCount) <= maximumQueryUTF8Bytes
                && limits.externalBrowseLimitRange.contains(Int(limit))
        case .enroll(_, let displayNameByteCount, _):
            return Int(displayNameByteCount)
                <= limits.maximumDisplayNameUTF8Bytes
        case .readAudit(_, let limit):
            return (1...limits.maxAuditReadBatchSize).contains(Int(limit))
        case .details, .pastePayload, .pin, .unpin, .remove, .grant,
             .revokeConnection, .rebase, .compact, .readEffectiveContent,
             .revokeCapability, .readConnections, .readGrants:
            return true
        }
    }

    private static func resultIsBounded(
        _ result: ResultSummaryV1,
        limits: ExternalLimits
    ) -> Bool {
        switch result {
        case .page(let count, _):
            return Int(count) <= limits.externalBrowseLimitRange.upperBound
        case .connections(let count):
            return Int(count) <= limits.maximumConnections
        case .auditPage(let count, _):
            return Int(count) <= limits.maxAuditReadBatchSize
        case .grants(let count), .connectionRevoked(let count):
            return Int(count) <= limits.maximumGrantRowsPerConnection
        case .affectedItemIDs(let itemIDs):
            return itemIDs.count <= limits.maxAffectedItemsPerRecord
        case .none, .details, .pastePayload, .enrolled, .grantChanged,
             .capabilityRevoked, .rebased, .compacted, .effectiveContent:
            return true
        }
    }

    private static func operationMatches(
        _ request: RequestSummaryV1,
        _ operation: ExternalOperationKind
    ) -> Bool {
        switch (request, operation) {
        case (.recent, .readRecent), (.search, .readSearch),
             (.details, .readDetails), (.pastePayload, .readPastePayload),
             (.pin, .managePin), (.unpin, .manageUnpin),
             (.remove, .manageRemove), (.enroll, .adminEnroll),
             (.grant, .adminGrant), (.revokeConnection, .adminRevoke),
             (.rebase, .adminRebase), (.compact, .adminCompact),
             (.readEffectiveContent, .readEffectiveContent),
             (.revokeCapability, .adminRevokeCapability),
             (.readConnections, .adminReadConnections),
             (.readGrants, .adminReadGrants),
             (.readAudit, .adminReadAudit):
            return true
        default:
            return false
        }
    }

    private static func attributionMatches(
        _ payload: OperationPayloadBlobV1,
        context: OperationPayloadRecordContextV1
    ) -> Bool {
        let connectionID = context.connectionID
        let capability = context.capability
        switch payload.request {
        case .recent, .search:
            return connectionID != nil
                && capability.map { $0 == .browse || $0 == .browsePreview } == true
        case .details, .pastePayload:
            return connectionID != nil && capability == .readContent
        case .pin, .unpin:
            return connectionID != nil
                && capability.map { $0 == .manage || $0 == .organize } == true
        case .remove:
            return connectionID != nil
                && capability.map { $0 == .manage || $0 == .deleteItem } == true
        case .readEffectiveContent:
            return connectionID != nil && capability == .readEffectiveContent
        case .enroll:
            guard capability == nil else { return false }
            switch (context.outcome, payload.result) {
            case (.succeeded, .enrolled(let enrolledID)):
                return connectionID == enrolledID
            case (.failed, .none), (.denied, .none):
                return connectionID == nil
            default:
                return false
            }
        case .grant(let targetID, let targetCapability),
             .revokeCapability(let targetID, let targetCapability):
            return connectionID == targetID && capability == targetCapability
        case .revokeConnection(let targetID), .readGrants(let targetID):
            return connectionID == targetID && capability == nil
        case .rebase, .compact, .readConnections, .readAudit:
            return connectionID == nil && capability == nil
        }
    }

    private static func outcomeMatches(
        _ payload: OperationPayloadBlobV1,
        context: OperationPayloadRecordContextV1
    ) -> Bool {
        switch context.outcome {
        case .succeeded:
            guard context.failureKind == nil, context.denialReason == nil,
                  successResultMatches(payload)
            else { return false }
            let isHistoryMutation: Bool
            switch payload.request {
            case .pin, .unpin, .remove: isHistoryMutation = true
            default: isHistoryMutation = false
            }
            if isHistoryMutation {
                return context.changePosition.map { $0 > 0 } == true
            }
            return context.changePosition == nil

        case .noOp:
            guard context.failureKind == nil, context.denialReason == nil,
                  context.changePosition == nil
            else { return false }
            switch (payload.request, payload.result) {
            case (.pin, .affectedItemIDs(let itemIDs)),
                 (.unpin, .affectedItemIDs(let itemIDs)),
                 (.remove, .affectedItemIDs(let itemIDs)):
                return itemIDs.isEmpty
            case (.revokeConnection, .connectionRevoked(let count)):
                return count == 0
            case (.compact, .compacted(
                let oldFloor,
                let newFloor,
                let count,
                let bytes
            )):
                return oldFloor == newFloor
                    && count == 0
                    && bytes == 0
            case (.grant, .grantChanged(false)),
                 (.revokeCapability, .capabilityRevoked(false)):
                return true
            default:
                return false
            }

        case .denied:
            guard case .none = payload.result,
                  context.changePosition == nil,
                  let failureKind = context.failureKind
            else { return false }
            switch failureKind {
            case .unauthorized, .connectionRevoked:
                return context.denialReason == nil
            case .requestDenied:
                return context.denialReason != nil
            case .notFound, .history, .temporarilyUnavailable, .persistence,
                 .auditCompactedBefore:
                return false
            }

        case .failed:
            guard case .none = payload.result,
                  context.changePosition == nil,
                  context.denialReason == nil,
                  let failureKind = context.failureKind
            else { return false }
            switch failureKind {
            case .notFound, .history, .temporarilyUnavailable, .persistence:
                return true
            case .auditCompactedBefore:
                guard case .readAudit(let since, _) = payload.request,
                      let floor = context.compactionFloor
                else { return false }
                return since < floor
            case .unauthorized, .connectionRevoked, .requestDenied:
                return false
            }
        }
    }

    private static func successResultMatches(
        _ payload: OperationPayloadBlobV1
    ) -> Bool {
        switch (payload.request, payload.result) {
        case (.recent, .page), (.search, .page), (.details, .details),
             (.pastePayload, .pastePayload), (.pin, .affectedItemIDs),
             (.unpin, .affectedItemIDs), (.remove, .affectedItemIDs),
             (.revokeConnection, .connectionRevoked),
             (.readEffectiveContent, .effectiveContent),
             (.readConnections, .connections), (.readGrants, .grants),
             (.readAudit, .auditPage), (.rebase, .rebased),
             (.compact, .compacted):
            return true
        case (.enroll(_, _, false), .enrolled):
            return true
        case (.grant, .grantChanged(true)),
             (.revokeCapability, .capabilityRevoked(true)):
            return true
        default:
            return false
        }
    }

    private static func summaryFactsMatch(
        _ payload: OperationPayloadBlobV1,
        context: OperationPayloadRecordContextV1
    ) -> Bool {
        switch (payload.request, payload.result) {
        case (.recent(let limit), .page(let count, _)),
             (.search(_, _, let limit), .page(let count, _)):
            return count <= limit

        case (.pin(let itemID), .affectedItemIDs(let itemIDs)),
             (.unpin(let itemID), .affectedItemIDs(let itemIDs)),
             (.remove(let itemID), .affectedItemIDs(let itemIDs)):
            switch context.outcome {
            case .succeeded:
                return itemIDs == [itemID]
            case .noOp:
                return itemIDs.isEmpty
            case .failed, .denied:
                return false
            }

        case (.readAudit(let since, let limit),
              .auditPage(let returnedCount, let snapshotHead)):
            guard context.outcome == .succeeded,
                  context.auditSequence == snapshotHead,
                  since <= snapshotHead,
                  returnedCount <= limit else {
                return false
            }
            return UInt64(returnedCount) <= snapshotHead - since

        case (.rebase, .rebased(let oldFloor, let newFloor, let count)):
            guard oldFloor <= newFloor,
                  let width = UInt32(exactly: newFloor - oldFloor) else {
                return false
            }
            return count == width

        case (.compact, .compacted(
            let oldFloor,
            let newFloor,
            let count,
            _
        )):
            guard oldFloor <= newFloor,
                  let width = UInt32(exactly: newFloor - oldFloor),
                  count == width else {
                return false
            }
            switch context.outcome {
            case .succeeded:
                return count > 0
            case .noOp:
                return count == 0
            case .failed, .denied:
                return false
            }

        default:
            return true
        }
    }

    private static func counterFactsMatch(
        _ result: ResultSummaryV1,
        context: OperationPayloadRecordContextV1
    ) -> Bool {
        switch result {
        case .rebased(let oldFloor, let newFloor, _),
             .compacted(let oldFloor, let newFloor, _, _):
            guard oldFloor <= newFloor,
                  let nextAuditSequence = context.nextAuditSequence
            else { return false }
            let discardedCount: UInt32
            switch result {
            case .rebased(_, _, let count), .compacted(_, _, let count, _):
                discardedCount = count
            default:
                return false
            }
            return newFloor <= nextAuditSequence
                && newFloor - oldFloor == UInt64(discardedCount)
        default:
            return true
        }
    }
}

// MARK: - Primitive binary format

private struct OperationPayloadWriter {
    fileprivate var data = Data()

    fileprivate mutating func append(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    fileprivate mutating func append(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    fileprivate mutating func append(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    fileprivate mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    fileprivate mutating func append(_ value: UUID) {
        let bytes = value.uuid
        data.append(contentsOf: [
            bytes.0, bytes.1, bytes.2, bytes.3,
            bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11,
            bytes.12, bytes.13, bytes.14, bytes.15,
        ])
    }
}

private struct OperationPayloadReader {
    private let data: Data
    private var offset = 0

    fileprivate init(data: Data) {
        self.data = data
    }

    fileprivate var isAtEnd: Bool { offset == data.count }
    fileprivate var remainingByteCount: Int { data.count - offset }

    fileprivate mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw OperationPayloadCodecRejection.malformedBlob
        }
        defer { offset += 1 }
        return data[offset]
    }

    fileprivate mutating func readBool() throws -> Bool {
        let raw = try readUInt8()
        switch raw {
        case 0: return false
        case 1: return true
        default: throw OperationPayloadCodecRejection.invalidBoolean(raw)
        }
    }

    fileprivate mutating func readUInt16() throws -> UInt16 {
        var result: UInt16 = 0
        for _ in 0..<2 { result = (result << 8) | UInt16(try readUInt8()) }
        return result
    }

    fileprivate mutating func readUInt32() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 { result = (result << 8) | UInt32(try readUInt8()) }
        return result
    }

    fileprivate mutating func readUInt64() throws -> UInt64 {
        var result: UInt64 = 0
        for _ in 0..<8 { result = (result << 8) | UInt64(try readUInt8()) }
        return result
    }

    fileprivate mutating func readUUID() throws -> UUID {
        guard remainingByteCount >= 16 else {
            throw OperationPayloadCodecRejection.malformedBlob
        }
        let bytes = (try readUInt8(), try readUInt8(), try readUInt8(), try readUInt8(),
                     try readUInt8(), try readUInt8(), try readUInt8(), try readUInt8(),
                     try readUInt8(), try readUInt8(), try readUInt8(), try readUInt8(),
                     try readUInt8(), try readUInt8(), try readUInt8(), try readUInt8())
        return UUID(uuid: bytes)
    }
}
