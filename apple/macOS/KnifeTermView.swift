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
        installKeyMonitor()
        installMouseMonitor()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        ring.append(slice)
        super.dataReceived(slice: slice)
        DispatchQueue.main.async { [weak self] in
            self?.onOutput?()
            self?.scheduleLinkScan()
        }
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        scheduleLinkScan()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleLinkScan()
    }

    override nonisolated func bell(source: Terminal) {
        DispatchQueue.main.async { [weak self] in self?.onBell?() }
    }

    // Editing chords (TerminalView.keyDown isn't open, so a local monitor):
    //   Shift+Enter        newline instead of submit (ESC CR, Claude Code's binding)
    //   ⌃Delete / ⌘Delete  delete the whole input line (^E ^U)
    //   Delete w/selection erase the highlighted text on the input row
    private var keyMonitor: Any?

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  self.window?.firstResponder === self else { return event }
            return self.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if event.keyCode == 36, mods == [.shift] {
            send(txt: "\u{1b}\r")
            onUserInput?()
            return nil
        }
        if event.keyCode == 51, mods == [.control] || mods == [.command] {
            send(txt: "\u{05}\u{15}") // end-of-line, then kill-to-start
            onUserInput?()
            return nil
        }
        if event.keyCode == 51, mods.isEmpty, selection.active {
            deleteSelection()
            return nil
        }
        return event
    }

    /// Backspace with a highlight: walk the cursor to the end of the selection
    /// and erase it. Only works on the cursor's own (input) row — a terminal
    /// can't edit rows the program isn't editing.
    private func deleteSelection() {
        defer { selectNone() }
        guard !selection.isMultiLine else { return }
        let t = getTerminal()
        let row = selection.start.row - t.getTopVisibleRow()
        let cur = t.getCursorLocation()
        guard row == cur.y else { return }
        let startCol = min(selection.start.col, selection.end.col)
        let endCol = max(selection.start.col, selection.end.col)
        var seq = ""
        let dc = (endCol + 1) - cur.x
        if dc != 0 { seq += String(repeating: dc < 0 ? "\u{1b}[D" : "\u{1b}[C", count: min(abs(dc), 400)) }
        seq += String(repeating: "\u{7f}", count: min(endCol - startCol + 1, 400))
        send(txt: seq)
        onUserInput?()
    }

    // Plain-click link opening runs on a local monitor, not the mouseUp
    // override — clicks never reached the override in practice (cause unknown;
    // the monitor sees every event before dispatch, same as the key monitor).
    private var mouseMonitor: Any?
    private var lastOpenedEventTimestamp: TimeInterval = -1

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let p = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(p) else { return event }
            if event.type == .leftMouseDown {
                self.downPoint = p
                return event
            }
            // No mouse-reporting check here: even when the TUI owns the mouse
            // (Claude Code turns reporting on), a click ON a link opens it —
            // that's the whole point. Non-link clicks fall through untouched.
            guard event.clickCount == 1,
                  hypot(p.x - self.downPoint.x, p.y - self.downPoint.y) <= 3,
                  event.modifierFlags.intersection([.command, .control, .shift]).isEmpty
            else { return event }
            let (col, row) = self.cellHit(p)
            guard row != self.getTerminal().getCursorLocation().y else { return event }
            self.rescanLinks()
            if let url = self.linkAt(col: col, row: row) {
                self.lastOpenedEventTimestamp = event.timestamp
                Self.openLink(url)
            }
            return event
        }
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
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
        // Link opening lives in the mouse monitor (which sees this same event
        // first); if it opened one, don't also walk the cursor to the click.
        if event.timestamp == lastOpenedEventTimestamp { return }
        let (col, row) = cellHit(p)
        placeCursor(col: col, row: row)
    }

    /// Cell metrics exactly as SwiftTerm computes them for hit testing.
    private func cellSize() -> (w: CGFloat, h: CGFloat) {
        let f = font
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let w = max(1, (f.advancement(forGlyph: f.glyph(withName: "W")).width * scale).rounded() / scale)
        let h = max(1, ceil(ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * scale) / scale)
        return (w, h)
    }

    private func cellHit(_ p: NSPoint) -> (col: Int, row: Int) {
        let (w, h) = cellSize()
        return (Int(p.x / w), Int((frame.height - p.y) / h))
    }

    // ─── Links: URLs on screen are underlined and open on a plain click ───
    // We scan the visible screen ourselves (joining wrapped rows) so links
    // always LOOK like links — SwiftTerm only underlines while ⌘ is held.

    private struct ScreenLink {
        let url: URL
        let spans: [(row: Int, cols: Range<Int>)] // screen-relative rows
    }
    private var screenLinks: [ScreenLink] = []
    private let linkLayer = CAShapeLayer()
    private var linkScanPending = false
    private static let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private func scheduleLinkScan() {
        guard !linkScanPending else { return }
        linkScanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.linkScanPending = false
            self.rescanLinks()
        }
    }

    private func rescanLinks() {
        guard let det = Self.urlDetector else { return }
        refreshCwdIfStale()
        let t = getTerminal()
        var found: [ScreenLink] = []
        var row = 0
        while row < t.rows {
            guard t.getLine(row: row) != nil else { row += 1; continue }
            // one logical line = this row plus following wrapped rows
            var text = ""
            var cellOfUnit: [Int] = [] // utf16 offset → cell ordinal in group
            var rows: [Int] = []
            var cell = 0
            repeat {
                guard let line = t.getLine(row: row) else { break }
                rows.append(row)
                for col in 0..<t.cols {
                    var ch = line[col].getCharacter()
                    if ch == "\u{0}" { ch = " " }
                    text.append(ch)
                    for _ in 0..<String(ch).utf16.count { cellOfUnit.append(cell) }
                    cell += 1
                }
                row += 1
            } while row < t.rows && (t.getLine(row: row)?.isWrapped ?? false)

            let ns = text as NSString
            func spansFor(_ range: NSRange) -> [(row: Int, cols: Range<Int>)] {
                guard range.length > 0, range.location < cellOfUnit.count else { return [] }
                let startCell = cellOfUnit[range.location]
                let endCell = cellOfUnit[min(range.location + range.length, cellOfUnit.count) - 1]
                var spans: [(row: Int, cols: Range<Int>)] = []
                var c = startCell
                while c <= endCell {
                    let rowEnd = min(endCell, (c / t.cols) * t.cols + t.cols - 1)
                    spans.append((row: rows[c / t.cols], cols: (c % t.cols)..<(rowEnd % t.cols) + 1))
                    c = rowEnd + 1
                }
                return spans
            }

            var claimed: [NSRange] = []
            for m in det.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url else { continue }
                let spans = spansFor(m.range)
                guard !spans.isEmpty else { continue }
                claimed.append(m.range)
                found.append(ScreenLink(url: url, spans: spans))
            }
            // File paths: any token that resolves to something on disk.
            for m in Self.tokenRegex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                guard !claimed.contains(where: { NSIntersectionRange($0, m.range).length > 0 }),
                      let (url, range) = fileLink(token: ns.substring(with: m.range), at: m.range)
                else { continue }
                let spans = spansFor(range)
                guard !spans.isEmpty else { continue }
                found.append(ScreenLink(url: url, spans: spans))
            }
        }
        screenLinks = found
        refreshLinkOverlay()
    }

    // ─── File paths: underlined like URLs, click shows them in Finder ───

    private static let tokenRegex = try! NSRegularExpression(pattern: #"\S+"#)

    /// "(apple/macOS/Foo.swift:12)" → file URL for apple/macOS/Foo.swift plus
    /// the range of just the path part, or nil when nothing on disk matches.
    /// Relative paths resolve against the shell's cwd; existence is the filter
    /// that keeps ordinary prose like "and/or" from underlining.
    private func fileLink(token: String, at range: NSRange) -> (URL, NSRange)? {
        guard token.contains("/") || token.first == "~" else { return nil }
        var core = Substring(token)
        while let f = core.first, "('\"`<[{".contains(f) { core.removeFirst() }
        while let l = core.last, ")'\"`>]},.;:!?".contains(l) { core.removeLast() }
        if let m = core.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
            core = core[..<m.lowerBound] // compiler-style file.swift:12:5 suffix
        }
        guard core.count > 1, core.contains("/") || core.first == "~" else { return nil }
        var path = String(core)
        if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        } else if !path.hasPrefix("/") {
            guard let cwd = cachedCwd else { return nil }
            path = cwd + "/" + path
        }
        path = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let lead = token[token.startIndex..<core.startIndex].utf16.count
        return (URL(fileURLWithPath: path),
                NSRange(location: range.location + lead, length: core.utf16.count))
    }

    // The shell's cwd (for resolving relative paths) comes from lsof, which is
    // too slow for the scan itself — cache it and refresh off the main thread.
    private var cachedCwd: String?
    private var cwdFetchedAt = Date.distantPast
    private var cwdFetchInFlight = false

    private func refreshCwdIfStale() {
        guard Date().timeIntervalSince(cwdFetchedAt) > 3, !cwdFetchInFlight,
              let pid = process?.shellPid, pid > 0 else { return }
        cwdFetchInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cwd = TabModel.cwdOf(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cwdFetchInFlight = false
                self.cwdFetchedAt = Date()
                if let cwd { self.cachedCwd = cwd }
            }
        }
    }

    /// URLs → browser. Directories → a Finder window. Files → revealed in Finder.
    private static func openLink(_ url: URL) {
        guard url.isFileURL else { NSWorkspace.shared.open(url); return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func refreshLinkOverlay() {
        wantsLayer = true
        if linkLayer.superlayer !== layer {
            linkLayer.removeFromSuperlayer()
            linkLayer.strokeColor = NSColor(red: 0xB1 / 255.0, green: 0xA5 / 255.0, blue: 0x7E / 255.0, alpha: 0.9).cgColor
            linkLayer.lineWidth = 1
            linkLayer.fillColor = nil
            linkLayer.zPosition = 10
            layer?.addSublayer(linkLayer)
        }
        let path = CGMutablePath()
        let (cellW, cellH) = cellSize()
        for link in screenLinks {
            for span in link.spans {
                let y = frame.height - CGFloat(span.row + 1) * cellH + 1.5
                path.move(to: CGPoint(x: CGFloat(span.cols.lowerBound) * cellW, y: y))
                path.addLine(to: CGPoint(x: CGFloat(span.cols.upperBound) * cellW, y: y))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        linkLayer.frame = layer?.bounds ?? bounds
        linkLayer.path = screenLinks.isEmpty ? nil : path
        CATransaction.commit()
    }

    private func linkAt(col: Int, row: Int) -> URL? {
        for link in screenLinks {
            for span in link.spans where span.row == row && span.cols.contains(col) {
                return link.url
            }
        }
        return nil
    }

    private func placeCursor(col: Int, row: Int) {
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
