import AppKit
import SwiftTerm
import KnifeKit

/// ⌘N: a small popout shell — no tabs, no sidebar, no projects. Just a
/// terminal for quick commands. Not saved to the session, not mirrored to iOS.
@MainActor
final class MiniTermController: NSWindowController, NSWindowDelegate {
    let term: KnifeTermView

    init() {
        term = KnifeTermView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "mini"
        win.minSize = NSSize(width: 320, height: 180)
        super.init(window: win)
        win.delegate = self
        win.isReleasedWhenClosed = false
        AppModel.shared.theme.style(terminal: term)
        win.backgroundColor = AppModel.shared.theme.nsColor(AppModel.shared.theme.current.background)
        if let content = win.contentView {
            term.frame = content.bounds
            term.autoresizingMask = [.width, .height]
            content.addSubview(term)
        }
        win.center()

        let env = TabModel.shellEnv()
        term.processDelegate = self
        term.startProcess(executable: TabModel.userShell(), args: ["-l"],
                          environment: env.map { "\($0.key)=\($0.value)" },
                          execName: nil, currentDirectory: NSHomeDirectory())

        showWindow(nil)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(term)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        term.process?.terminate()
        AppModel.shared.miniClosed(self)
    }
}

extension MiniTermController: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            self?.window?.title = title.isEmpty ? "mini" : title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in self?.close() }
    }
}
