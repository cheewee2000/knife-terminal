import AppKit
import KnifeKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let theme = ThemeManager()
    var windows: [KnifeWindowController] = []
    weak var mostRecentWindow: KnifeWindowController?
    private var nextTabId = 1
    private var owner: [Int: KnifeWindowController] = [:] // tab id → window
    private var tabById: [Int: TabModel] = [:]
    var sync: SyncPublisher?
    private var socket: UnixSocketServer?
    private var saveTimer: Timer?
    private var debounceTimer: Timer?

    func takeTabId() -> Int { defer { nextTabId += 1 }; return nextTabId }

    func tab(_ id: Int) -> TabModel? { tabById[id] }
    func window(of tab: TabModel) -> KnifeWindowController? { owner[tab.id] }

    /// The window to talk to: key, else most recently used, else any.
    func frontWindow() -> KnifeWindowController? {
        if let k = NSApp.keyWindow, let wc = windows.first(where: { $0.window == k }) { return wc }
        if let m = mostRecentWindow, windows.contains(where: { $0 === m }) { return m }
        return windows.last
    }

    // ─── Lifecycle ───

    func start() {
        socket = UnixSocketServer(path: (NSHomeDirectory() as NSString).appendingPathComponent(".knife-terminal.sock")) { [weak self] msg in
            Task { @MainActor in self?.handleSocketMessage(msg) }
        }
        socket?.start()
        restoreSession()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.saveSession() }
        }
        let publisher = SyncPublisher()
        sync = publisher
        publisher.start()
    }

    func shutdown() {
        saveSession()
        socket?.stop()
        for wc in windows { for t in wc.tabs { t.terminate() } }
    }

    func tabOpened(_ tab: TabModel, in wc: KnifeWindowController) {
        owner[tab.id] = wc
        tabById[tab.id] = tab
        saveSessionSoon()
        sync?.tabOpened(tab)
    }

    func reassign(_ tab: TabModel, to wc: KnifeWindowController) {
        owner[tab.id] = wc
        saveSessionSoon()
    }

    func tabClosed(_ tab: TabModel) {
        owner.removeValue(forKey: tab.id)
        tabById.removeValue(forKey: tab.id)
        agents.removeValue(forKey: tab.id)
        pendingStop[tab.id]?.cancel(); pendingStop.removeValue(forKey: tab.id)
        saveSessionSoon()
        sync?.tabClosed(tab.id)
    }

    func processExited(tabId: Int) {
        guard let wc = owner[tabId] else { return }
        wc.closeTab(tabId)
    }

    func windowClosing(_ wc: KnifeWindowController) {
        saveSession() // capture before the tabs die
        for t in wc.tabs { t.terminate(); tabClosed(t) }
        wc.tabs.removeAll()
        windows.removeAll { $0 === wc }
        if windows.isEmpty { NSApp.terminate(nil) }
    }

    @discardableResult
    func newWindow(bounds: NSRect? = nil, withTab: Bool = true) -> KnifeWindowController {
        let wc = KnifeWindowController(bounds: bounds)
        windows.append(wc)
        wc.showWindow(nil)
        if withTab {
            wc.addTab()
            wc.defaultTabId = wc.activeId
        }
        return wc
    }

    func mergeAllWindows() {
        guard let target = frontWindow() else { return }
        for wc in windows where wc !== target {
            for tab in wc.tabs { target.adopt(tab) }
            wc.tabs.removeAll()
            wc.window?.close()
        }
    }

    func moveActiveTabToNewWindow() {
        guard let src = frontWindow(), src.tabs.count > 1, let id = src.activeId,
              let tab = src.detach(id) else { return }
        let wc = newWindow(withTab: false)
        wc.adopt(tab)
    }

    // ─── Open requests (files, urls, socket "open <dir>") ───

    struct OpenRequest { var cwd: String?; var cmd: String?; var title: String? }

    func openRequest(for target: String) -> OpenRequest? {
        if target.hasPrefix("ssh://") || target.hasPrefix("telnet://") {
            guard let u = URL(string: target), let host = u.host else { return nil }
            let user = u.user.map { $0 + "@" } ?? ""
            let scheme = u.scheme ?? "ssh"
            var port = ""
            if let p = u.port { port = scheme == "ssh" ? " -p \(p)" : " \(p)" }
            return OpenRequest(cwd: nil, cmd: "\(scheme) \(user)\(host)\(port)", title: host)
        }
        if target.hasPrefix("x-man-page://") {
            let page = target.replacingOccurrences(of: "x-man-page://", with: "")
            return OpenRequest(cwd: nil, cmd: "man " + page, title: "man " + page)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            return OpenRequest(cwd: target, cmd: nil, title: (target as NSString).lastPathComponent)
        }
        return OpenRequest(cwd: (target as NSString).deletingLastPathComponent,
                           cmd: shellQuote(target), title: (target as NSString).lastPathComponent)
    }

    func dispatchOpen(_ target: String, cmd: String? = nil) {
        guard var req = openRequest(for: target) else { return }
        if let cmd { req.cmd = cmd }
        let wc = frontWindow() ?? newWindow(withTab: false)
        wc.addTab(TabOptions(cwd: req.cwd, cmd: req.cmd, title: req.title,
                             restoreCmd: req.cmd == "claude" ? "claude -c" : nil))
    }

    // ─── Attention: Claude Code hooks ping the socket with the tab id ───

    static let workingEvents: Set<String> = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop", "TaskCompleted"]
    private var agents: [Int: Int] = [:]     // tab id → live subagent count
    private var pendingStop: [Int: DispatchWorkItem] = [:]
    private let stopQuiet: TimeInterval = 2.0

    private func handleSocketMessage(_ msg: String) {
        let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        // "open <dir>" → new tab in <dir> running claude (Finder "Open with Claude" quick action)
        if trimmed.hasPrefix("open ") {
            let dir = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                dispatchOpen(dir, cmd: "claude")
                NSApp.activate(ignoringOtherApps: true)
                frontWindow()?.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard let sp = trimmed.firstIndex(where: { $0 == " " || $0 == "\n" }) ?? (Int(trimmed) != nil ? trimmed.endIndex : nil),
              let id = Int(trimmed[trimmed.startIndex..<sp]) else { return }
        var type = "stop"
        let rest = sp < trimmed.endIndex ? String(trimmed[trimmed.index(after: sp)...]) : ""
        if let data = rest.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            type = (j["notification_type"] as? String) ?? (j["hook_event_name"] as? String) ?? type
        }
        attention(id: id, type: type)
    }

    /// Ported from the Electron main process: working events animate; a Stop
    /// only chimes when no sub-agents are live, after a short quiet window.
    private func attention(id: Int, type: String) {
        let tab = tabById[id]
        if Self.workingEvents.contains(type) {
            pendingStop[id]?.cancel(); pendingStop.removeValue(forKey: id)
            if type == "UserPromptSubmit" { agents[id] = 0 } // fresh turn: recover from drift
            else if type == "SubagentStart" { agents[id] = (agents[id] ?? 0) + 1 }
            else if type == "SubagentStop" { agents[id] = max(0, (agents[id] ?? 0) - 1) }
            if let tab, !tab.working { tab.working = true; tabStateChanged(tab) }
            return
        }
        pendingStop[id]?.cancel(); pendingStop.removeValue(forKey: id)
        if type == "Stop" {
            if (agents[id] ?? 0) > 0 { return } // sub-agents still running: not done
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStop.removeValue(forKey: id)
                if let tab = self.tabById[id] {
                    tab.working = false
                    self.markAttention(tab, fromBell: false)
                    self.tabStateChanged(tab)
                }
                self.chime()
                self.publishAlert(id: id, type: type)
            }
            pendingStop[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + stopQuiet, execute: work)
            return
        }
        if let tab, tab.working { tab.working = false; tabStateChanged(tab) }
        if type == "SessionEnd" { agents.removeValue(forKey: id); return }
        if let tab { markAttention(tab, fromBell: false) }
        chime()
        publishAlert(id: id, type: type)
    }

    func markAttention(_ tab: TabModel, fromBell: Bool) {
        let wc = owner[tab.id]
        let isVisibleActive = tab.id == wc?.activeId && (wc?.window?.isKeyWindow ?? false) && NSApp.isActive
        if fromBell && isVisibleActive { return } // a bell in the tab you're looking at is just a bell
        if !isVisibleActive { tab.attention = true; tabStateChanged(tab) }
    }

    func bellRang(in tab: TabModel) {
        markAttention(tab, fromBell: true)
        // with hooks on, claude rings the bell at the same moments the hooks chime — don't double up
        if !HooksInstaller.installed() { chime() }
    }

    func chime() {
        NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)?.play()
    }

    private func publishAlert(id: Int, type: String) {
        guard let tab = tabById[id] else { return }
        let msg = type == "Stop" ? "\(tab.title) — ready for input" : "\(tab.title) — needs attention"
        sync?.publishAlert(tabTitle: tab.title, message: msg)
    }

    func tabStateChanged(_ tab: TabModel) {
        sync?.tabStateChanged(tab)
    }

    // ─── Session persistence (same shape as the Electron session.json) ───

    struct SavedTab: Codable { var title: String?; var cwd: String?; var cmd: String?; var active: Bool? }
    struct SavedWindow: Codable { var bounds: Bounds?; var tabs: [SavedTab]
        struct Bounds: Codable { var x: Double; var y: Double; var width: Double; var height: Double } }
    struct SavedSession: Codable { var windows: [SavedWindow] }

    private var lastSaved: SavedSession?

    private var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Knife Terminal/session.json")
    }
    private var legacySessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("knife-terminal/session.json")
    }

    func saveSessionSoon() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
            Task { @MainActor in AppModel.shared.saveSession() }
        }
    }

    func saveSession() {
        let saved = windows.compactMap { wc -> SavedWindow? in
            guard !wc.tabs.isEmpty else { return nil }
            let b = wc.window?.frame ?? .zero
            let tabs = wc.tabs.map { t in
                SavedTab(title: t.title, cwd: t.currentCwd, cmd: t.opts.restoreCmd, active: t.id == wc.activeId)
            }
            return SavedWindow(bounds: .init(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height), tabs: tabs)
        }
        if !saved.isEmpty { lastSaved = SavedSession(windows: saved) }
        guard let session = lastSaved else { return }
        do {
            try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
            try enc.encode(session).write(to: sessionURL)
        } catch {}
    }

    private func restoreSession() {
        var session: SavedSession?
        for url in [sessionURL, legacySessionURL] {
            if let data = try? Data(contentsOf: url) {
                // the Electron file may be {windows:[…]} or legacy {tabs:[…]}
                if let s = try? JSONDecoder().decode(SavedSession.self, from: data), !s.windows.isEmpty { session = s; break }
                if let one = try? JSONDecoder().decode(SavedWindow.self, from: data), !one.tabs.isEmpty {
                    session = SavedSession(windows: [one]); break
                }
            }
        }
        guard let session, !session.windows.isEmpty else { newWindow(); return }
        for w in session.windows {
            var rect: NSRect?
            if let b = w.bounds {
                let r = NSRect(x: b.x, y: b.y, width: b.width, height: b.height)
                if onScreen(r) { rect = r }
            }
            let wc = newWindow(bounds: rect, withTab: false)
            var activeTabId: Int?
            for t in w.tabs where t.cwd != nil {
                let isShellName = t.title?.range(of: "^shell \\d+$", options: .regularExpression) != nil
                let tab = wc.addTab(TabOptions(cwd: t.cwd, cmd: t.cmd,
                                               title: t.cmd != nil ? t.title : nil,
                                               shownTitle: isShellName ? nil : t.title,
                                               restoreCmd: t.cmd), activateIt: false)
                if t.active == true { activeTabId = tab.id }
            }
            if wc.tabs.isEmpty { wc.addTab(); wc.defaultTabId = wc.activeId }
            else { wc.activate(activeTabId ?? wc.tabs[0].id) }
        }
        if windows.isEmpty { newWindow() }
    }

    /// Use saved bounds only if a meaningful part would land on a connected display.
    private func onScreen(_ b: NSRect) -> Bool {
        guard b.width > 0, b.height > 0 else { return false }
        return NSScreen.screens.contains { s in
            let a = s.visibleFrame
            let ix = min(b.maxX, a.maxX) - max(b.minX, a.minX)
            let iy = min(b.maxY, a.maxY) - max(b.minY, a.minY)
            return ix >= 120 && iy >= 80
        }
    }
}
