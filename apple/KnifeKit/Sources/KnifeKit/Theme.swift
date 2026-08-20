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
