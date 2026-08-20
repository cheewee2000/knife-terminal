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
