import AppKit
import SwiftTerm

/// Accessibility for the terminal. SwiftTerm's view exposes nothing, so VoiceOver and tools like Omnikeys
/// saw only a scroll bar. The visible screen is presented as one text area and the terminal cursor as its caret.
/// Scrolled back, the text is the visible rows and the caret stays where the cursor would be; good enough,
/// since typing always happens at the bottom.
extension KnifeTermView {
    private var screenLines: [String] {
        let t = getTerminal()
        return (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
    }
    private var screenText: String { screenLines.joined(separator: "\n") }
    /// UTF-16 offset of the cursor within the screen text.
    private var cursorOffset: Int {
        let (x, y) = getTerminal().getCursorLocation()
        let lines = screenLines
        var off = 0
        for r in 0..<min(y, lines.count) { off += (lines[r] as NSString).length + 1 }
        if y < lines.count { off += min(x, (lines[y] as NSString).length) }
        return off
    }
    private func cell(of offset: Int) -> (row: Int, col: Int) {
        var off = offset
        for (r, l) in screenLines.enumerated() {
            let n = (l as NSString).length
            if off <= n { return (r, off) }
            off -= n + 1
        }
        return (max(0, getTerminal().rows - 1), 0)
    }
    /// SwiftTerm's cell size is private; the font's metrics reproduce it (height = line height, width = "W" advance).
    private var cellSize: CGSize {
        let w = ceil(font.advancement(forGlyph: font.glyph(withName: "W")).width)
        let h = ceil(font.ascender - font.descender + font.leading)
        return CGSize(width: max(1, w), height: max(1, h))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityRoleDescription() -> String? { "terminal" }
    override func accessibilityValue() -> Any? { screenText }
    override func accessibilityNumberOfCharacters() -> Int { (screenText as NSString).length }
    override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: cursorOffset, length: 0) }
    override func accessibilitySelectedText() -> String? { "" }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: accessibilityNumberOfCharacters()) }
    override func accessibilityInsertionPointLineNumber() -> Int { getTerminal().getCursorLocation().y }
    override func accessibilityString(for range: NSRange) -> String? {
        let s = screenText as NSString
        guard range.location >= 0, range.location <= s.length else { return nil }
        return s.substring(with: NSRange(location: range.location, length: max(0, min(range.length, s.length - range.location))))
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: nativeForegroundColor]) }
    }
    /// Screen rectangle of the cells covering `range` (one row; the first row if it spans several).
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let (row, col) = cell(of: range.location)
        let c = cellSize
        let n = max(1, min(range.length, getTerminal().cols - col))
        let local = NSRect(x: CGFloat(col) * c.width, y: bounds.height - CGFloat(row + 1) * c.height, width: CGFloat(n) * c.width, height: c.height)
        guard let w = window else { return .zero }
        return w.convertToScreen(convert(local, to: nil))
    }
}
