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

    public static let light = TermTheme(
        background: RGB(0xffffff), foreground: RGB(0x111111), cursor: RGB(0x111111), cursorText: RGB(0xffffff),
        ansi: [
            RGB(0x111111), RGB(0xd11d1d), RGB(0x2e7d4f), RGB(0xe35a1e),
            RGB(0x3a3a38), RGB(0xb08a4d), RGB(0x8c8c87), RGB(0xb9b8b3),
            RGB(0x8a8a8a), RGB(0xd11d1d), RGB(0x2e7d4f), RGB(0xe35a1e),
            RGB(0x4a4a4a), RGB(0xb08a4d), RGB(0x8c8c87), RGB(0xececea),
        ])

    public static let dark = TermTheme(
        background: RGB(0x111111), foreground: RGB(0xececea), cursor: RGB(0xececea), cursorText: RGB(0x111111),
        ansi: [
            RGB(0x1a1a18), RGB(0xe04a4a), RGB(0x4caf7a), RGB(0xf07a45),
            RGB(0xb9b8b3), RGB(0xc9a567), RGB(0x9c9c97), RGB(0xb9b8b3),
            RGB(0x6a6a66), RGB(0xe04a4a), RGB(0x4caf7a), RGB(0xf07a45),
            RGB(0xd6d6d2), RGB(0xc9a567), RGB(0x9c9c97), RGB(0xffffff),
        ])

    // Ghostty's bundled "Tomorrow" — the light sibling of its stock dark look.
    public static let ghosttyLight = TermTheme(
        background: RGB(0xffffff), foreground: RGB(0x4d4d4c), cursor: RGB(0x4d4d4c), cursorText: RGB(0xffffff),
        ansi: [
            RGB(0x000000), RGB(0xc82829), RGB(0x718c00), RGB(0xeab700),
            RGB(0x4271ae), RGB(0x8959a8), RGB(0x3e999f), RGB(0xbfbfbf),
            RGB(0x000000), RGB(0xc82829), RGB(0x718c00), RGB(0xeab700),
            RGB(0x4271ae), RGB(0x8959a8), RGB(0x3e999f), RGB(0xffffff),
        ])

    // Ghostty's stock dark look (`ghostty +show-config --default`).
    public static let ghosttyDark = TermTheme(
        background: RGB(0x282c34), foreground: RGB(0xffffff), cursor: RGB(0xffffff), cursorText: RGB(0x282c34),
        ansi: [
            RGB(0x1d1f21), RGB(0xcc6666), RGB(0xb5bd68), RGB(0xf0c674),
            RGB(0x81a2be), RGB(0xb294bb), RGB(0x8abeb7), RGB(0xc5c8c6),
            RGB(0x666666), RGB(0xd54e53), RGB(0xb9ca4a), RGB(0xe7c547),
            RGB(0x7aa6da), RGB(0xc397d8), RGB(0x70c0b1), RGB(0xeaeaea),
        ])

    init(background: RGB, foreground: RGB, cursor: RGB, cursorText: RGB, ansi: [RGB]) {
        self.background = background; self.foreground = foreground
        self.cursor = cursor; self.cursorText = cursorText; self.ansi = ansi
    }
}

// Brand accent from the README (`accent #B1A57E`) and CW&T ink/paper.
public enum Brand {
    public static let accentHex: UInt32 = 0xB1A57E
    public static let inkHex: UInt32 = 0x1a1a18
    public static let paperHex: UInt32 = 0xf4f1e9
    public static let idLabel = "CWT_STE3XM1_2607"
}
