#if DEBUG
import Foundation

/// Process-death tests interrupt real SQL writes. Both points precede COMMIT,
/// so a fresh process must see complete old state. This does not emulate
/// sudden power loss or claim interruption inside SQLite's commit syscall.
package enum TransactionKillDebugInstrumentation {
    package enum KillPoint: String, Sendable {
        case beforePositionWrite
        case beforeCommit
    }

    @TaskLocal package static var killPoint: KillPoint?
    package static let markerPrefix = "[CLIPY_TX_KILL]"

    package static func markerLine(for point: KillPoint) -> String {
        "\(markerPrefix) point=\(point.rawValue)"
    }

    package static func terminateIfArmed(_ point: KillPoint) {
        guard killPoint == point else { return }
        FileHandle.standardError.write(Data((markerLine(for: point) + "\n").utf8))
        fatalError("intentional mid-transaction kill point=\(point.rawValue)")
    }
}
#endif
