import Foundation

/// Common HTML character references for inert text; unknown names retain
/// their literal spelling instead of silently disappearing from the preview.
internal enum PreviewHTMLEntities {
    internal static func decode(_ spelling: String) -> String? {
        guard spelling.hasPrefix("#") else { return named[spelling] }
        let hexadecimal = spelling.hasPrefix("#x") || spelling.hasPrefix("#X")
        let digits = spelling.dropFirst(hexadecimal ? 2 : 1)
        guard !digits.isEmpty, let value = UInt32(digits, radix: hexadecimal ? 16 : 10) else {
            return nil
        }
        // HTML replaces null, surrogate and out-of-range numeric references.
        guard value != 0, let scalar = Unicode.Scalar(windows1252[value] ?? value) else {
            return "\u{FFFD}"
        }
        return String(scalar)
    }

    internal static let legacyNames: Set<String> = [
        "amp", "AMP", "lt", "LT", "gt", "GT", "quot", "QUOT", "nbsp", "copy", "reg"
    ]

    // HTML's numeric-reference replacement for the legacy C1 punctuation
    // range also occurs in clipboard fragments emitted by older editors.
    private static let windows1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
        0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
        0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
        0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
        0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
        0x9E: 0x017E, 0x9F: 0x0178
    ]

    private static let named: [String: String] = [
        "amp": "&", "AMP": "&", "lt": "<", "LT": "<", "gt": ">", "GT": ">",
        "quot": "\"", "QUOT": "\"", "apos": "'", "nbsp": "\u{A0}", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "lrm": "\u{200E}", "rlm": "\u{200F}", "copy": "©", "reg": "®", "trade": "™",
        "cent": "¢", "pound": "£", "yen": "¥", "euro": "€", "curren": "¤",
        "sect": "§", "para": "¶", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷",
        "micro": "µ", "middot": "·", "bull": "•", "hellip": "…", "ndash": "–", "mdash": "—",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "oline": "‾",
        "acute": "´", "uml": "¨", "cedil": "¸", "shy": "\u{AD}", "not": "¬",
        "iexcl": "¡", "iquest": "¿", "sup1": "¹", "sup2": "²", "sup3": "³",
        "frac14": "¼", "frac12": "½", "frac34": "¾",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å",
        "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë",
        "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "ETH": "Ð", "Ntilde": "Ñ",
        "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
        "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý", "THORN": "Þ",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å",
        "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
        "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "eth": "ð", "ntilde": "ñ",
        "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
        "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "thorn": "þ",
        "yuml": "ÿ", "szlig": "ß", "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š",
        "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ",
        "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ", "phi": "φ", "omega": "ω",
        "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Omega": "Ω",
        "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔", "crarr": "↵",
        "forall": "∀", "part": "∂", "exist": "∃", "empty": "∅", "nabla": "∇", "isin": "∈",
        "notin": "∉", "ni": "∋", "prod": "∏", "sum": "∑", "minus": "−", "lowast": "∗",
        "radic": "√", "infin": "∞", "ang": "∠", "and": "∧", "or": "∨", "cap": "∩", "cup": "∪",
        "int": "∫", "there4": "∴", "sim": "∼", "cong": "≅", "asymp": "≈", "ne": "≠",
        "equiv": "≡", "le": "≤", "ge": "≥", "sub": "⊂", "sup": "⊃", "nsub": "⊄",
        "sube": "⊆", "supe": "⊇", "oplus": "⊕", "otimes": "⊗", "perp": "⊥", "sdot": "⋅",
        "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋", "lang": "⟨", "rang": "⟩",
        "loz": "◊", "spades": "♠", "clubs": "♣", "hearts": "♥", "diams": "♦"
    ]
}
