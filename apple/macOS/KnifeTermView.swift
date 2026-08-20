import AppKit
import SwiftTerm
import KnifeKit

func shellQuote(_ p: String) -> String {
    if p.range(of: "^[A-Za-z0-9_/.\\-]+$", options: .regularExpression) != nil { return p }
    return "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// SwiftTerm terminal wired to a local login shell, with taps for the ring
/// buffer (iOS mirroring), bell, and user typing (clears working/attention).
final class KnifeTermView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?      // raw pty output landed (already in `ring`)
    var onBell: (() -> Void)?
    var onUserInput: (() -> Void)?   // real typing, not ESC[-prefixed reports
    let ring = OutputRingBuffer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        bellStyle = .none // we run our own attention/chime logic
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        ring.append(slice)
        super.dataReceived(slice: slice)
        DispatchQueue.main.async { [weak self] in self?.onOutput?() }
    }

    override nonisolated func bell(source: Terminal) {
        DispatchQueue.main.async { [weak self] in self?.onBell?() }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Focus in/out reports, mouse events, and query responses arrive here
        // too (all ESC-prefixed) — only real typing clears working/attention.
        if data.first != 0x1b { DispatchQueue.main.async { [weak self] in self?.onUserInput?() } }
        super.send(source: source, data: data)
    }

    /// The visible screen as styled runs (colors, bold, …) for the iOS mirror.
    func styledScreen() -> Data {
        let t = getTerminal()
        var lines: [[TermRun]] = []
        for row in 0..<t.rows {
            guard let line = t.getLine(row: row) else { lines.append([]); continue }
            var runs: [TermRun] = []
            var text = ""
            var key: (f: Int?, g: Int?, s: Int?) = (nil, nil, nil)
            func flush() {
                if !text.isEmpty { runs.append(TermRun(t: text, f: key.f, g: key.g, s: key.s)); text = "" }
            }
            for col in 0..<t.cols {
                let cd = line[col]
                let a = cd.attribute
                var s = 0
                if a.style.contains(.bold) { s |= StyledScreen.styleBold }
                if a.style.contains(.dim) { s |= StyledScreen.styleDim }
                if a.style.contains(.italic) { s |= StyledScreen.styleItalic }
                if a.style.contains(.underline) { s |= StyledScreen.styleUnderline }
                if a.style.contains(.inverse) { s |= StyledScreen.styleInverse }
                let k = (Self.colorCode(a.fg), Self.colorCode(a.bg), s == 0 ? nil : s)
                if k != key { flush(); key = k }
                let ch = cd.getCharacter()
                text.append(ch == "\u{0}" ? " " : ch)
            }
            flush()
            // trim unstyled trailing blanks so lines don't carry cols of padding
            while let last = runs.last, last.g == nil,
                  last.t.trimmingCharacters(in: .whitespaces).isEmpty { runs.removeLast() }
            if var last = runs.popLast() {
                if last.g == nil { while last.t.hasSuffix(" ") { last.t.removeLast() } }
                runs.append(last)
            }
            lines.append(runs)
        }
        while let l = lines.last, l.isEmpty { lines.removeLast() }
        return StyledScreen(lines: lines).encoded()
    }

    private static func colorCode(_ c: Attribute.Color) -> Int? {
        switch c {
        case .defaultColor, .defaultInvertedColor: return nil
        case .ansi256(let code): return Int(code)
        case .trueColor(let r, let g, let b):
            return StyledScreen.trueColorFlag | Int(r) << 16 | Int(g) << 8 | Int(b)
        }
    }

    // Click near the cursor (no drag, no modifiers) → move the shell's cursor to
    // the clicked cell by sending arrow keys. Click-drag still selects, clicks far
    // from the cursor (scrollback / output) just focus, mouse-aware apps keep the
    // click for themselves.
    private var downPoint: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dragged = hypot(p.x - downPoint.x, p.y - downPoint.y) > 3
        super.mouseUp(with: event)
        guard event.clickCount == 1, !dragged,
              event.modifierFlags.intersection([.command, .control, .shift]).isEmpty,
              !(allowMouseReporting && getTerminal().mouseMode != .off) // app owns the mouse
        else { return }
        placeCursor(at: p)
    }

    private func placeCursor(at p: NSPoint) {
        // cell metrics exactly as SwiftTerm computes them for hit testing
        let f = font
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let cellW = max(1, (f.advancement(forGlyph: f.glyph(withName: "W")).width * scale).rounded() / scale)
        let cellH = max(1, ceil(ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * scale) / scale)
        let col = Int(p.x / cellW)
        let row = Int((frame.height - p.y) / cellH)
        let cur = getTerminal().getCursorLocation() // screen-relative, like row/col above
        let dr = row - cur.y
        let dc = col - cur.x
        // only reposition near the cursor (the input area); a click 6+ rows away
        // is output/scrollback and arrow-spamming there would trigger history
        guard abs(dr) <= 5, dr != 0 || dc != 0 else { return }
        var seq = ""
        if dr != 0 { seq += String(repeating: dr < 0 ? "\u{1b}[A" : "\u{1b}[B", count: abs(dr)) }
        if dc != 0 { seq += String(repeating: dc < 0 ? "\u{1b}[D" : "\u{1b}[C", count: min(abs(dc), 400)) }
        send(txt: seq)
    }

    // Drop files/folders → paste shell-quoted paths
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        send(txt: urls.map { shellQuote($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }
}
