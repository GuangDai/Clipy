/// FailurePresentationTests — the typed-failure → user-facing message
/// mapping (docs/03b-instruction-set.md §10; docs/roadmap/
/// 05-presentationui.md). Every case of the closed `HistoryFailure`
/// vocabulary — including every nested reason/kind of the associated-value
/// enums — must produce a non-empty message, and the contract-pinned
/// strings are spot-checked exactly. Public failures never leak raw
/// payloads, paths, or type identifiers into the strings.
import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

struct FailurePresentationTests {

    private func localizedBundle(_ language: String) throws -> Bundle {
        let localization = try #require(FailureCopy.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(FailureCopy.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    private func message(
        for failure: HistoryFailure,
        language: String = "en"
    ) throws -> String {
        FailurePresentation.message(for: failure, bundle: try localizedBundle(language))
    }

    // MARK: - Fixtures

    /// A fixed item ID for the associated-value payloads.
    private let itemID = HistoryItemID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
    )

    /// A fixed revision ID for `.revisionNotFound`.
    private let revisionID = RevisionID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!
    )

    /// One representative payload for every `InvalidInputReason` case.
    private var invalidInputReasons: [InvalidInputReason] {
        [
            .emptyCapture,
            .excludedFromHistory,
            .duplicateRepresentationType("public.utf8-plain-text"),
            .unsupportedRepresentationType("com.example.unknown"),
            .representationLimit,
            .byteLimit,
            .invalidTimestamp,
            .incoherentRevisionDraft,
            .invalidRegularExpression,
            .invalidPageLimit,
            .invalidPixelSize,
            .invalidRetentionPolicy,
            .invalidSearchTerm,
        ]
    }

    /// One representative payload for every `PinnedPlacementFailure` case.
    private var pinnedPlacementFailures: [PinnedPlacementFailure] {
        [
            .targetMissing,
            .anchorMissingOrUnpinned,
            .targetEqualsAnchor,
        ]
    }

    /// Every `CapacityKind` case.
    private var capacityKinds: [CapacityKind] {
        [
            .retainedItems,
            .revisionCount,
            .revisionBytes,
            .copyCount,
            .thumbnailBytes,
            .coherenceToken,
            .storageBytes,
        ]
    }

    /// Every `UnavailableReason` case.
    private var unavailableReasons: [UnavailableReason] {
        [
            .factProof,
            .dedupIndexRebuild,
            .insufficientDiskSpace,
            .searchEngineDeadline,
        ]
    }

    /// Every `PersistenceFailure` case.
    private var persistenceFailures: [PersistenceFailure] {
        [
            .openStore,
            .storeAlreadyOpen,
            .corruptStoredValue,
            .invariantViolation,
            .transaction,
        ]
    }

    /// One payload for every `HistoryFailure` case — the full closed
    /// vocabulary of docs/03b-instruction-set.md §10.
    private var allFailures: [HistoryFailure] {
        var failures: [HistoryFailure] = [
            .notFound(itemID),
            .staleContent(
                expected: ContentVersion(rawValue: 2),
                current: ContentVersion(rawValue: 3)
            ),
            .revisionNotFound(revisionID),
            .snapshotExpired(current: ChangePosition(rawValue: 7)),
            .thumbnailUnavailable,
        ]
        failures += invalidInputReasons.map { HistoryFailure.invalidInput($0) }
        failures += pinnedPlacementFailures.map {
            HistoryFailure.invalidPinnedPlacement($0)
        }
        failures += capacityKinds.map { HistoryFailure.capacityExceeded($0) }
        failures += unavailableReasons.map {
            HistoryFailure.temporarilyUnavailable($0)
        }
        failures += persistenceFailures.map { HistoryFailure.persistence($0) }
        return failures
    }

    // MARK: - Completeness

    /// Every case of the closed vocabulary answers a non-empty message — a
    /// new failure case is an owned source change that must be answered
    /// here (docs/03b-instruction-set.md §10).
    @Test func everyFailureCaseYieldsANonEmptyLocalizedMessage() throws {
        let englishBundle = try localizedBundle("en")
        let chineseBundle = try localizedBundle("zh-Hans")
        for failure in allFailures {
            let english = FailurePresentation.message(for: failure, bundle: englishBundle)
            let chinese = FailurePresentation.message(for: failure, bundle: chineseBundle)
            #expect(!english.isEmpty)
            #expect(!chinese.isEmpty)
            #expect(chinese != english)
            #expect(englishBundle.localizedString(
                forKey: english, value: "Missing English failure message", table: "Failure"
            ) == english)
            for text in [english, chinese] {
                #expect(!text.contains(itemID.rawValue.uuidString))
                #expect(!text.contains(revisionID.rawValue.uuidString))
                #expect(!text.contains("public.utf8-plain-text"))
                #expect(!text.contains("com.example.unknown"))
            }
        }
    }

    @Test func undecodableThumbnailDoesNotImplyHistoryStorageFailure() throws {
        #expect(try message(for: .thumbnailUnavailable)
            == "A thumbnail isn't available for this image")
        #expect(try message(for: .persistence(.corruptStoredValue))
            == "History storage error")
        #expect(try message(for: .thumbnailUnavailable, language: "zh-Hans")
            == "此图像没有可用的缩略图")
        #expect(try message(for: .persistence(.corruptStoredValue), language: "zh-Hans")
            == "历史记录存储出错")
    }

    // MARK: - Contract-pinned strings

    /// The four contract-specified spot checks: the regex-rejection and
    /// reindexing-retry wording, and the not-found / stale-content banner
    /// strings (docs/roadmap/05-presentationui.md).
    @Test func contractSpecifiedStringsMatchExactly() throws {
        #expect(
            try message(for: .invalidInput(.invalidRegularExpression))
                == "Invalid regular expression"
        )
        #expect(
            try message(
                for: .temporarilyUnavailable(.dedupIndexRebuild)
            )
                == "History is reindexing. Try again shortly."
        )
        #expect(
            try message(for: .notFound(itemID))
                == "Item was removed"
        )
        #expect(
            try message(
                for: .staleContent(
                    expected: ContentVersion(rawValue: 2),
                    current: ContentVersion(rawValue: 3)
                )
            )
                == "Item changed while editing"
        )
    }

    /// The settings-surface retention wordings carry the V2-07 §5 strings:
    /// the unsatisfiable-budget (R2) message and the pinned-exceeds-budget
    /// validation message.
    @Test func retentionSurfaceStringsMatchExactly() throws {
        #expect(
            try message(for: .invalidInput(.invalidRetentionPolicy))
                == "Pinned items exceed this budget. Unpin items or raise the budget."
        )
        #expect(
            try message(for: .capacityExceeded(.storageBytes))
                == "This budget can't be satisfied with the current history."
        )
    }

    @Test func insufficientDiskSpaceMessageExplainsTheRetryableAction() throws {
        #expect(
            try message(
                for: .temporarilyUnavailable(.insufficientDiskSpace)
            )
                == "Not enough disk space. Free some space and try again."
        )
    }

    /// REVIEW Card 11C (docs/03b-instruction-set.md §8/§10): the engine
    /// deadline is retryable, so the message says so.
    @Test func searchEngineDeadlineMessageSaysSearchIsSlowAndRetryable() throws {
        #expect(
            try message(
                for: .temporarilyUnavailable(.searchEngineDeadline)
            )
                == "Search is taking too long. Try again."
        )
    }

    @Test func chineseRecoveryMessagesPreserveTheSpecificRemedy() throws {
        #expect(try message(
            for: .temporarilyUnavailable(.insufficientDiskSpace), language: "zh-Hans"
        ) == "磁盘空间不足，请释放部分空间后重试。")
        #expect(try message(
            for: .temporarilyUnavailable(.searchEngineDeadline), language: "zh-Hans"
        ) == "搜索耗时过长，请重试。")
        #expect(try message(
            for: .temporarilyUnavailable(.dedupIndexRebuild), language: "zh-Hans"
        ) == "正在重建历史记录索引，请稍后重试。")
        #expect(try message(
            for: .invalidInput(.invalidRetentionPolicy), language: "zh-Hans"
        ) == "置顶项目已超出此限额。请取消部分项目的置顶，或提高限额。")
        #expect(try message(
            for: .invalidInput(.incoherentRevisionDraft), language: "zh-Hans"
        ) == "不能隐藏所有内容格式")
    }
}
