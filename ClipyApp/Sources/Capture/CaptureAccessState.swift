/// App-owned capture access/health policy (REVIEW Card 5A / CLIP-1).
/// This file is Foundation-free pure state: AppKit observation stays in
/// PasteboardAdapter and the composition root owns polling lifecycle.
import PasteboardAdapter

/// CLIP-1's one product-owned Pause choice. A fixed five-minute window keeps
/// the privacy action obvious and self-ending without adding a settings or
/// duration-selection surface. Quit may end it earlier; it is intentionally
/// process-local rather than durable preference state.
enum CapturePausePolicy {
    static let standardDuration: Duration = .seconds(300)

#if DEBUG
    /// Running-app evidence substitutes only elapsed time. The production
    /// reducer, observer, baseline, and capture lane remain unchanged.
    static let runningUITestDuration: Duration = .seconds(8)
#endif
}

/// The caller-visible, content-free reason background capture is running or
/// stopped. None of these cases carries pasteboard types, bytes, query text,
/// source applications, or framework errors.
enum CaptureAccessState: Sendable, Equatable {
    case systemDefault
    case ask
    case allowed
    case denied
    case readFailure
    case userPaused

    /// Card 5A's deny-by-default polling decision. Recovery only re-reads the
    /// system posture; an authoritative `.alwaysAllow` projection is still
    /// required before the observer loop may read an item.
    var permitsBackgroundPolling: Bool {
        self == .allowed
    }

    var recovery: CaptureAccessRecovery? {
        switch self {
        case .allowed:
            nil
        case .userPaused:
            .resume
        case .systemDefault, .ask, .denied, .readFailure:
            .retry
        }
    }
}

enum CaptureAccessRecovery: Sendable, Equatable {
    case retry
    case resume
}

/// Pure reducer that preserves user-pause precedence while retaining the most
/// recent system/read state underneath it. A retry is an explicit recovery
/// generation: it clears a prior read failure and consumes a newly read system
/// behavior instead of guessing that access changed.
struct CaptureAccessReducer: Sendable, Equatable {
    private var systemBehavior: PasteboardAccessBehavior
    private var hasReadFailure: Bool
    private var isUserPaused: Bool

    init(systemBehavior: PasteboardAccessBehavior) {
        self.systemBehavior = systemBehavior
        self.hasReadFailure = systemBehavior == .unavailable
        self.isUserPaused = false
    }

    var state: CaptureAccessState {
        if isUserPaused {
            return .userPaused
        }
        if hasReadFailure {
            return .readFailure
        }
        switch systemBehavior {
        case .systemDefault:
            return .systemDefault
        case .ask:
            return .ask
        case .allowed:
            return .allowed
        case .denied:
            return .denied
        case .unavailable:
            return .readFailure
        }
    }

    mutating func updateSystemBehavior(_ behavior: PasteboardAccessBehavior) {
        systemBehavior = behavior
        if behavior == .unavailable {
            hasReadFailure = true
        }
    }

    mutating func recordReadFailure() {
        hasReadFailure = true
    }

    mutating func retry(systemBehavior: PasteboardAccessBehavior) {
        self.systemBehavior = systemBehavior
        hasReadFailure = systemBehavior == .unavailable
    }

    mutating func pause() {
        isUserPaused = true
    }

    mutating func resume() {
        isUserPaused = false
    }
}
