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

    /// Rendered text tail of the terminal (scrollback + screen) for the iOS mirror.
    func renderedTail(maxLines: Int = 400, maxBytes: Int = 48_000) -> String {
        guard let full = String(data: getTerminal().getBufferAsData(), encoding: .utf8) else { return "" }
        var lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        var text = lines.joined(separator: "\n")
        while text.utf8.count > maxBytes, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    // ⌥-click: move the shell's cursor to the clicked cell by sending arrow keys
    // (plain click stays selection, as in every terminal).
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) {
            placeCursor(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    private func placeCursor(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // cell metrics exactly as SwiftTerm computes them
        let f = font
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let cellW = max(1, (f.advancement(forGlyph: f.glyph(withName: "W")).width * scale).rounded() / scale)
        let cellH = max(1, ceil(ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * scale) / scale)
        let col = Int(p.x / cellW)
        let row = Int((frame.height - p.y) / cellH)
        let cur = getTerminal().getCursorLocation() // screen-relative, like row/col above
        var seq = ""
        let dr = row - cur.y
        let dc = col - cur.x
        if dr != 0 { seq += String(repeating: dr < 0 ? "\u{1b}[A" : "\u{1b}[B", count: min(abs(dr), 200)) }
        if dc != 0 { seq += String(repeating: dc < 0 ? "\u{1b}[D" : "\u{1b}[C", count: min(abs(dc), 400)) }
        if !seq.isEmpty { send(txt: seq) }
        window?.makeFirstResponder(self)
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
