/// ClipyCLIContract — pure, versioned request decoding and reply rendering for
/// the future first-party `clipyctl`. This target deliberately owns neither
/// process I/O nor operation dispatch (V2-05 §0.1.1–0.1.2; roadmap X.8).
import Foundation

package enum ClipyCLIContract {
    package static let protocolVersion = 1
    package static let maximumRequestBytes = 65_536
    package static let maximumResponseBytes = 33_554_432
}
