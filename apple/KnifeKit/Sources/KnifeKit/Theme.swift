import Foundation

// CW&T terminal palettes, ported from the Electron renderer THEMES table.
public struct TermTheme: Sendable {
    public struct RGB: Sendable {
        public let r: UInt8, g: UInt8, b: UInt8
        public init(_ hex: UInt32) {
            r = UInt8((hex >> 16) & 0xff); g = UInt8((hex >> 8) & 0xff); b = UInt8(hex & 0xff)
        }
    }

    public let background: RGB
    public let foreground: RGB
    public let cursor: RGB
    public let cursorText: RGB
    /// ANSI 0-15: black red green yellow blue magenta cyan white, then bright variants.
    public let ansi: [RGB]
    /// Chrome highlight (active tab, working pulse, link underlines).
    public let accent: RGB
    /// "Claude is waiting for you" signal.
    public let attention: RGB

    // Ghostty's bundled "Tomorrow" theme — the light sibling of the dark default.
    public static let light = TermTheme(
        background: RGB(0xffffff), foreground: RGB(0x4d4d4c), cursor: RGB(0x4d4d4c), cursorText: RGB(0xffffff),
        accent: RGB(0x4271ae), attention: RGB(0xf5871f),
        ansi: [
            RGB(0x000000), RGB(0xc82829), RGB(0x718c00), RGB(0xeab700),
            RGB(0x4271ae), RGB(0x8959a8), RGB(0x3e999f), RGB(0xbfbfbf),
            RGB(0x000000), RGB(0xc82829), RGB(0x718c00), RGB(0xeab700),
            RGB(0x4271ae), RGB(0x8959a8), RGB(0x3e999f), RGB(0xffffff),
        ])

    // Ghostty's stock dark look (`ghostty +show-config --default`).
    public static let dark = TermTheme(
        background: RGB(0x282c34), foreground: RGB(0xffffff), cursor: RGB(0xffffff), cursorText: RGB(0x282c34),
        accent: RGB(0xb2b9f4), attention: RGB(0xde935f),
        ansi: [
            RGB(0x1d1f21), RGB(0xcc6666), RGB(0xb5bd68), RGB(0xf0c674),
            RGB(0x81a2be), RGB(0xb294bb), RGB(0x8abeb7), RGB(0xc5c8c6),
            RGB(0x666666), RGB(0xd54e53), RGB(0xb9ca4a), RGB(0xe7c547),
            RGB(0x7aa6da), RGB(0xc397d8), RGB(0x70c0b1), RGB(0xeaeaea),
        ])

    init(background: RGB, foreground: RGB, cursor: RGB, cursorText: RGB,
         accent: RGB, attention: RGB, ansi: [RGB]) {
        self.background = background; self.foreground = foreground
        self.cursor = cursor; self.cursorText = cursorText
        self.accent = accent; self.attention = attention; self.ansi = ansi
    }
}

// Ghostty-flavored accents: periwinkle highlight on the stock dark background.
public enum Brand {
    public static let accentHex: UInt32 = 0xB2B9F4
    public static let inkHex: UInt32 = 0x282c34
    public static let paperHex: UInt32 = 0xffffff
    public static let idLabel = "CWT_STE3XM1_2607"
}
