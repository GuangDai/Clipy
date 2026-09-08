/// LocalizedCountPresentation.swift — one Presentation-owned formatter for
/// integer count tokens. Callers retain their own nouns and semantic copy;
/// this value only prevents raw interpolation from bypassing the active
/// locale's grouping and digits (V2-07 §10.3).
import Foundation

enum LocalizedCountPresentation {
    static func number(_ value: Int, locale: Locale) -> String {
        value.formatted(.number.locale(locale))
    }
}
