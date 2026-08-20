import AppKit
import SwiftUI

@MainActor
final class KnifeWindowController: NSWindowController, NSWindowDelegate, ObservableObject {
    @Published var tabs: [TabModel] = []
    @Published var activeId: Int?
    /// The untouched shell a fresh window opens with; replaced by the first real tab.
    var defaultTabId: Int?

    var activeTab: TabModel? { tabs.first { $0.id == activeId } }

    convenience init(bounds: NSRect?) {
        let rect = bounds ?? NSRect(x: 0, y: 0, width: 1100, height: 700)
        let win = NSWindow(contentRect: rect,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.tabbingMode = .disallowed
        win.minSize = NSSize(width: 400, height: 240)
        win.isReleasedWhenClosed = false
        self.init(window: win)
        win.delegate = self
        win.backgroundColor = AppModel.shared.theme.nsColor(AppModel.shared.theme.current.background)
        win.contentView = NSHostingView(rootView: ContentView(controller: self))
        if bounds != nil { win.setFrame(rect, display: true) } else { win.center() }
    }

    @discardableResult
    func addTab(_ opts: TabOptions = TabOptions(), activateIt: Bool = true) -> TabModel {
        let tab = TabModel(id: AppModel.shared.takeTabId(), opts: opts)
        tabs.append(tab)
        AppModel.shared.tabOpened(tab, in: self)
        if activateIt { activate(tab.id) }
        return tab
    }

    func activate(_ id: Int) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeId = id
        if NSApp.isActive, window?.isKeyWindow ?? false, let t = activeTab, t.attention {
            t.attention = false
        }
        AppModel.shared.saveSessionSoon()
    }

    func closeTab(_ id: Int, keepAlive: Bool = false) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: idx)
        if !keepAlive {
            tab.terminate()
            AppModel.shared.tabClosed(tab)
        }
        if tabs.isEmpty {
            if keepAlive || AppModel.shared.windows.count > 1 {
                window?.close()
            } else {
                addTab()
                defaultTabId = activeId
            }
            return
        }
        if activeId == id { activate(tabs[min(idx, tabs.count - 1)].id) }
        AppModel.shared.saveSessionSoon()
    }

    func cycle(_ dir: Int) {
        guard let cur = activeId, let i = tabs.firstIndex(where: { $0.id == cur }), !tabs.isEmpty else { return }
        activate(tabs[(i + dir + tabs.count) % tabs.count].id)
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.windowClosing(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let t = activeTab, t.attention { t.attention = false }
        AppModel.shared.mostRecentWindow = self
    }

    func windowDidMove(_ notification: Notification) { AppModel.shared.saveSessionSoon() }
    func windowDidResize(_ notification: Notification) { AppModel.shared.saveSessionSoon() }
}
