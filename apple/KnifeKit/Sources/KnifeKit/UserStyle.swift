import Foundation

// Per-person style profiles — the app is shared, the taste isn't.
// Each profile is a set of vetoes over the CW&T house style; `cw` is the
// house style untouched. Ids name the style, not a person — the app is public. Add fields here as preferences accumulate.
public struct UserStyle: Sendable, Equatable {
    public let id: String
    /// Emoji in the chrome (tab rows, project list).
    public let emoticons: Bool
    /// Bold faces anywhere — UI labels and terminal SGR bold alike.
    public let boldText: Bool
    /// Grey/dimmed text on a dark background (terminal palette greys,
    /// SGR dim, grey 256/truecolor foregrounds, secondary UI labels).
    public let greyOnBlack: Bool
    /// Points off the house terminal font size (13).
    public let termFontDelta: Double
    /// What vetoed greys become instead (hex RGB); nil = the theme foreground.
    public let greyReplacementHex: UInt32?
    /// The one loud color this user allows — the active shell in the sidebar;
    /// nil = the house treatment (bold primary).
    public let accentHex: UInt32?
    /// Terminal palettes: Ghostty's (stock dark, Tomorrow light) instead of the house ones.
    public var ghosttyPalette = false
    /// Terminal grid font; nil = Space Mono.
    public var termFont: String? = nil
    /// Chrome (sidebar, footer) font, regular and bold faces; nil = Space Mono.
    /// A face that isn't installed falls back to the system font.
    public var chromeFont: (regular: String, bold: String)? = nil

    public static func == (a: UserStyle, b: UserStyle) -> Bool { a.id == b.id }

    public static let plain = UserStyle(id: "plain", emoticons: false, boldText: false, greyOnBlack: false,
                                         termFontDelta: -1, greyReplacementHex: nil, accentHex: 0x00FF00)
    public static let house = UserStyle(id: "house", emoticons: true, boldText: true, greyOnBlack: true,
                                     termFontDelta: 0, greyReplacementHex: nil, accentHex: nil)
    /// Ghostty's look: its palettes, JetBrains Mono (bundled) for the grid,
    /// Helvetica Now Text for the chrome (licensed, not bundled — system font without it).
    public static let ghostty = UserStyle(id: "ghostty", emoticons: true, boldText: true, greyOnBlack: true,
                                          termFontDelta: 0, greyReplacementHex: nil, accentHex: nil,
                                          ghosttyPalette: true, termFont: "JetBrains Mono",
                                          chromeFont: ("HelveticaNowText-Regular", "HelveticaNowText-Medium"))
    public static let all: [UserStyle] = [.plain, .house, .ghostty]

    public static func named(_ id: String?) -> UserStyle? {
        let id = ["taylor": "plain", "cw": "house"][id ?? ""] ?? id // ids saved before 1.3.10
        return all.first { $0.id == id }
    }

    /// First-run default: guess the profile from the macOS account, house style otherwise.
    public static func forMachine(username: String, fullName: String) -> UserStyle {
        (username + " " + fullName).lowercased().contains("taylor") ? .plain : .house
    }
}

public extension TermTheme {
    /// A color is "grey" when its channels are near-equal and it sits in the
    /// mid range — dark enough to read as grey on black, light enough not to
    /// be the black background itself (index 0 must stay black).
    static func isGrey(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        let mx = Swift.max(r, g, b), mn = Swift.min(r, g, b)
        return Int(mx) - Int(mn) <= 20 && mx >= 60 && mx < 216
    }

    /// The theme reshaped by a user style: with grey-on-black vetoed in dark
    /// mode, every greyish palette entry is lifted to the style's replacement
    /// color (or the full foreground).
    func applying(_ style: UserStyle, dark: Bool) -> TermTheme {
        guard dark, !style.greyOnBlack else { return self }
        let lift = style.greyReplacementHex.map(RGB.init) ?? foreground
        let lifted = ansi.map { Self.isGrey($0.r, $0.g, $0.b) ? lift : $0 }
        return TermTheme(background: background, foreground: foreground,
                         cursor: cursor, cursorText: cursorText, ansi: lifted)
    }
}
