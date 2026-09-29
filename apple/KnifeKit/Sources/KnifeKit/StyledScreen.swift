import Foundation

// The Mac publishes each tab's visible screen as styled runs so the phone can
// render colors natively. Compact JSON: t = text, f/g = fg/bg color code
// (0-255 ansi, or trueColorFlag | 0xRRGGBB), s = style bits.

public struct TermRun: Codable, Sendable, Equatable {
    public var t: String
    public var f: Int?
    public var g: Int?
    public var s: Int?

    public init(t: String, f: Int? = nil, g: Int? = nil, s: Int? = nil) {
        self.t = t; self.f = f; self.g = g; self.s = s
    }
}

public struct StyledScreen: Codable, Sendable {
    public var lines: [[TermRun]]

    public init(lines: [[TermRun]]) { self.lines = lines }

    public static let styleBold = 1
    public static let styleDim = 2
    public static let styleItalic = 4
    public static let styleUnderline = 8
    public static let styleInverse = 16
    public static let trueColorFlag = 0x1_000_000

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data) -> StyledScreen? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(StyledScreen.self, from: data)
    }
}

public extension TermTheme {
    /// xterm-256 index → RGB under this theme (0-15 themed, 16-255 standard).
    func rgb(ansi idx: Int) -> RGB {
        if idx >= 0 && idx < 16 { return ansi[idx] }
        if idx >= 16 && idx < 232 {
            let i = idx - 16
            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            return RGB(steps[i / 36] << 16 | steps[(i / 6) % 6] << 8 | steps[i % 6])
        }
        if idx >= 232 && idx < 256 {
            let v = UInt32(8 + (idx - 232) * 10)
            return RGB(v << 16 | v << 8 | v)
        }
        return foreground
    }

    /// Decode a TermRun color code (ansi index or trueColorFlag | rgb).
    func rgb(code: Int) -> RGB {
        if code >= StyledScreen.trueColorFlag {
            return RGB(UInt32(code - StyledScreen.trueColorFlag))
        }
        return rgb(ansi: code)
    }
}

public extension StyledScreen {
    /// The screen as terminal bytes, for redrawing it in a real terminal view (a guest's tab in
    /// collaborative mode): home, each line cleared and rewritten with its SGR attributes, the
    /// rest of the screen cleared. Autowrap is off so lines wider than the viewer clip, not wrap.
    func ansi() -> String {
        var out = "\u{1b}[?7l\u{1b}[H"
        for (i, line) in lines.enumerated() {
            if i > 0 { out += "\r\n" }
            out += "\u{1b}[2K"
            for run in line {
                var sgr: [String] = ["0"]
                if let s = run.s {
                    if s & Self.styleBold != 0 { sgr.append("1") }
                    if s & Self.styleDim != 0 { sgr.append("2") }
                    if s & Self.styleItalic != 0 { sgr.append("3") }
                    if s & Self.styleUnderline != 0 { sgr.append("4") }
                    if s & Self.styleInverse != 0 { sgr.append("7") }
                }
                if let f = run.f { sgr.append(Self.sgrColor(f, base: 38)) }
                if let g = run.g { sgr.append(Self.sgrColor(g, base: 48)) }
                out += "\u{1b}[" + sgr.joined(separator: ";") + "m" + run.t
            }
            out += "\u{1b}[0m"
        }
        return out + "\u{1b}[0m\u{1b}[J"
    }

    private static func sgrColor(_ code: Int, base: Int) -> String {
        if code >= trueColorFlag {
            let rgb = code - trueColorFlag
            return "\(base);2;\(rgb >> 16 & 0xff);\(rgb >> 8 & 0xff);\(rgb & 0xff)"
        }
        return "\(base);5;\(code)"
    }
}
