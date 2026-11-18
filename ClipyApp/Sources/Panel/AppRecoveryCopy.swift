/// Localized copy owned by the app's store-open and paste recovery surface.
/// Typed History messages stay in PresentationUI's FailurePresentation.
import Foundation
import HistoryCore

enum AppRecoveryCopy {
    static func text(_ english: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: english, value: english, table: "AppRecovery")
    }

    /// A stable, content-free category shared by the panel and Settings.
    static func failureCategory(for error: any Error, bundle: Bundle = AppLocalization.bundle) -> String {
        guard let historyFailure = error as? HistoryFailure else {
            return error is ClipyCompositionError
                ? text("History Store Already Open", bundle: bundle)
                : text("History Store Open Failed", bundle: bundle)
        }
        guard case .persistence(let persistenceFailure) = historyFailure else {
            return text("History Store Open Failed", bundle: bundle)
        }
        switch persistenceFailure {
        case .openStore:
            return text("History Store Open Failed", bundle: bundle)
        case .storeAlreadyOpen:
            // DATA-7's cross-process lease denial is distinguishable from a
            // flat open failure and names the other live instance.
            return text("History Store Already Open", bundle: bundle)
        case .corruptStoredValue:
            return text("Stored History Unreadable", bundle: bundle)
        case .invariantViolation:
            return text("History Consistency Check Failed", bundle: bundle)
        case .transaction:
            return text("History Startup Transaction Failed", bundle: bundle)
        }
    }

    /// Uses the shared History failure vocabulary and omits raw diagnostics.
    static func failureMessage(for error: any Error, bundle: Bundle = AppLocalization.bundle) -> String {
        if let historyFailure = error as? HistoryFailure {
            // DATA-7: a live owner in ANOTHER process holds the StoreRoot
            // lease — the finding's "in use by another instance" wording,
            // not the generic storage error.
            if case .persistence(.storeAlreadyOpen) = historyFailure {
                return text("Clipy's history store is already open in another instance. Quit that instance and try again.", bundle: bundle)
            }
            return FailurePresentation.message(for: historyFailure, bundle: bundle)
        }
        if error is ClipyCompositionError {
            return text("Clipy's history store is already open in this app. Quit Clipy and try again.", bundle: bundle)
        }
        return text("Clipy couldn't open its history store.", bundle: bundle)
    }
}
