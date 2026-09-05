/// Capture/access presentation owned by the application bundle. These
/// messages contain no clipboard bytes, application identifiers, or errors.
import Foundation

enum AppCaptureCopy {
    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: "AppCapture")
    }

    static func accessMessage(_ state: CaptureAccessState, bundle: Bundle = .main) -> String {
        let message: String
        switch state {
        case .systemDefault:
            message = "Clipy needs permission before it can monitor clipboard changes."
        case .ask:
            message = "Clipboard access needs your approval before monitoring can continue."
        case .allowed:
            message = "Clipboard monitoring is allowed."
        case .denied:
            message = "Clipboard access is denied, so monitoring is stopped."
        case .readFailure:
            message = "Clipy couldn't check clipboard access. Try again."
        case .userPaused:
            message = "Clipboard monitoring is paused for up to 5 minutes."
        }
        return text(message, bundle: bundle)
    }

    static func recoveryTitle(_ recovery: CaptureAccessRecovery, bundle: Bundle = .main) -> String {
        text(recovery == .resume ? "Resume" : "Try Again", bundle: bundle)
    }

    static func recoveryLabel(_ recovery: CaptureAccessRecovery, bundle: Bundle = .main) -> String {
        text(recovery == .resume ? "Resume clipboard capture" : "Retry clipboard access", bundle: bundle)
    }

    static func statusLabel(isPaused: Bool, bundle: Bundle = .main) -> String {
        isPaused ? text("Clipy, clipboard monitoring paused", bundle: bundle) : "Clipy"
    }
}
