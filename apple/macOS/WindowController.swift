import AppKit
import SwiftUI
import Combine

@MainActor
final class KnifeWindowController: NSWindowController, NSWindowDelegate, ObservableObject {
    @Published var tabs: [TabModel] = []
    @Published var activeId: Int?
    @Published var showBoard = false
    /// The untouched shell a fresh window opens with; replaced by the first real tab.
    var defaultTabId: Int?
    /// The sidebar groups tabs; a tab changing group has to re-render the list
    /// itself, not just that row.
    private var statusWatch: [Int: AnyCancellable] = [:]
    /// The tab you just selected stays in the group it was in when you clicked it,
    /// until you move to another tab or something real happens to it. Otherwise
    /// clicking a ready tab clears it and the row leaves from under the cursor.
    @Published private(set) var pinned: (id: Int, group: SidebarGroup, status: TabStatus)?

    func displayGroup(_ tab: TabModel) -> SidebarGroup {
        if let p = pinned, p.id == tab.id, p.id == activeId, tab.status == p.status { return p.group }
        return tab.group
    }

    /// Drags only reorder within a group: status isn't something you can drop a
    /// tab into, and a cross-group move reshuffled the list under the cursor.
    func sameGroup(_ a: Int, _ b: Int) -> Bool {
        guard let ta = tabs.first(where: { $0.id == a }), let tb = tabs.first(where: { $0.id == b }) else { return false }
        return displayGroup(ta) == displayGroup(tb)
    }

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
        statusWatch[tab.id] = Publishers.Merge(
            tab.$group.dropFirst().removeDuplicates().map { _ in () },
            tab.$status.dropFirst().removeDuplicates().map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
        AppModel.shared.tabOpened(tab, in: self)
        if activateIt { activate(tab.id) }
        return tab
    }

    func activate(_ id: Int) {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        let groupBefore = displayGroup(t)
        activeId = id
        if NSApp.isActive, window?.isKeyWindow ?? false, t.attention {
            t.attention = false
            t.status = t.working ? .working : .idle
        }
        pinned = (id, groupBefore, t.status)
        AppModel.shared.saveSessionSoon()
    }

    func closeTab(_ id: Int, keepAlive: Bool = false) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: idx)
        statusWatch.removeValue(forKey: id)
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

    func moveTab(_ id: Int, before targetId: Int) {
        guard id != targetId,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == targetId }) else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
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
        if let t = activeTab, t.attention {
            let groupBefore = displayGroup(t)
            t.attention = false
            t.status = t.working ? .working : .idle
            pinned = (t.id, groupBefore, t.status)
        }
        AppModel.shared.mostRecentWindow = self
    }

    func windowDidMove(_ notification: Notification) { AppModel.shared.saveSessionSoon() }
    func windowDidResize(_ notification: Notification) { AppModel.shared.saveSessionSoon() }
}
