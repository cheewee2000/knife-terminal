import SwiftUI
import CloudKit
import KnifeKit
import UserNotifications

@MainActor
final class MirrorStore: ObservableObject {
    static let shared = MirrorStore()

    @Published var tabs: [MirroredTab] = []
    @Published var projects: [ProjectRef] = []
    @Published var pendingOpens: Set<String> = []   // paths we've asked the Mac to open
    @Published var iCloudAvailable = true
    @Published var lastSync: Date?
    @Published var syncError: String?               // last failure, nil once a sync succeeds
    @Published var offline = false
    private let cloud = CloudSync(role: "ios")
    private var started = false
    private var pendingInputs: [(tabId: Int, text: String)] = []  // typed while offline; retried on refresh

    // ─── Local cache: last mirrored state survives relaunch + works offline ───

    private struct Cache: Codable {
        var tabs: [MirroredTab]
        var projects: [ProjectRef]
        var lastSync: Date?
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mirror.json")
    }

    @discardableResult
    private func loadCache() -> Bool {
        guard let d = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(Cache.self, from: d) else { return false }
        tabs = c.tabs; projects = c.projects; lastSync = c.lastSync
        return true
    }

    private func saveCache() {
        let c = Cache(tabs: tabs, projects: projects, lastSync: lastSync)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: cacheURL, options: .atomic) }
    }

    func startup() async {
        guard !started else { return }
        started = true
        if DemoData.enabled {
            tabs = DemoData.tabs
            projects = DemoData.projects
            lastSync = Date()
            return
        }
        // The zone-change token only makes sense relative to the state it was
        // fetched into. No cache → fetch everything from scratch. (Before the
        // cache existed the token outlived the in-memory tabs, so a relaunch
        // only ever showed tabs that changed after the previous run.)
        if !loadCache() { cloud.resetChangeToken() }
        CloudSync.log("startup: cached tabs=\(tabs.count)")
        await refresh()
    }

    /// User-visible "needs you" pushes, off unless asked for. The silent
    /// database subscription that keeps the mirror fresh is separate and stays on.
    static let alertsKey = "knife.pushAlerts"
    var alertsOn: Bool { UserDefaults.standard.bool(forKey: Self.alertsKey) }

    func setAlerts(_ on: Bool) {
        Task {
            if on {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                try? await cloud.ensureAlertSubscription()
            } else {
                try? await cloud.deleteAlertSubscription()
            }
            await syncBadge()
        }
    }

    private func syncBadge() async {
        let badge = alertsOn ? tabs.filter { $0.attention }.count : 0
        try? await UNUserNotificationCenter.current().setBadgeCount(badge)
    }

    private var subsReady = false
    private func ensureSubscriptions() async {
        guard !subsReady else { return }
        do {
            try await cloud.ensureZone()
            try await cloud.ensureDatabaseSubscription()
            if alertsOn { try await cloud.ensureAlertSubscription() }
            else { try? await cloud.deleteAlertSubscription() } // clears one left from a previous run
            subsReady = true
        } catch {
            CloudSync.log("ios setup failed (will retry): \(error)")
        }
    }

    /// One fetch at a time. Pushes arrive every ~1.5s while the Mac is busy;
    /// each used to start its own zone fetch and the overlapping full fetches
    /// on a fresh install never finished. A push during a fetch queues one more.
    private var refreshing = false, refreshQueued = false
    func refresh() async {
        guard !DemoData.enabled else { return }
        if refreshing { refreshQueued = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat { refreshQueued = false; await refreshOnce() } while refreshQueued
    }

    private func refreshOnce() async {
        // offline, accountStatus can't be determined — still show the cache
        let status = try? await cloud.container.accountStatus()
        iCloudAvailable = status != .noAccount && status != .restricted
        guard iCloudAvailable else {
            syncError = "not signed into iCloud"
            return
        }
        await ensureSubscriptions()
        await flushPendingInputs()
        let delta: ZoneDelta
        do { delta = try await cloud.fetchChanges() }
        catch {
            offline = (error as? CKError).map { [.networkUnavailable, .networkFailure].contains($0.code) } ?? true
            syncError = offline ? "offline" : "\(error.localizedDescription)"
            return
        }
        offline = false
        syncError = nil
        if !delta.garbage.isEmpty { Task { try? await cloud.deleteRecords(delta.garbage) } }
        var byId = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for t in delta.tabs { byId[t.id] = t }
        for name in delta.deletedTabRecordNames { byId.removeValue(forKey: name) }
        tabs = byId.values.sorted { $0.order < $1.order }
        if let refs = delta.projects { projects = refs }
        pendingOpens = pendingOpens.filter { path in !tabs.contains { $0.cwd == path } }
        lastSync = Date()
        saveCache()
        await syncBadge()
    }

    /// Keystrokes go up immediately; if that fails (offline) they wait for the
    /// next refresh. In-memory only — a relaunch drops them.
    // ponytail: unpersisted queue, write it into the cache file if lost drafts become a complaint
    func send(_ text: String, to tabId: Int) {
        pendingInputs.append((tabId, text))
        Task { await flushPendingInputs() }
    }

    private func flushPendingInputs() async {
        while let next = pendingInputs.first {
            do { try await cloud.sendInput(tabId: next.tabId, text: next.text) }
            catch { syncError = "send failed: \(error.localizedDescription)"; return }
            pendingInputs.removeFirst()
        }
    }

    /// Viewing a tab acknowledges its "waiting for you" flag — cleared locally
    /// right away, and on the Mac via a Seen record.
    func markSeen(_ tab: MirroredTab) {
        guard tab.attention else { return }
        if let i = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[i].attention = false }
        Task { await syncBadge() }
        Task { try? await cloud.sendSeen(tabId: tab.tabId) }
    }

    /// Ask the Mac to close a tab. Removed locally right away; the Mac deleting
    /// the Tab record makes it stick (or the next refresh brings it back if not).
    func closeTab(_ tab: MirroredTab) {
        tabs.removeAll { $0.id == tab.id }
        Task {
            try? await cloud.sendClose(tabId: tab.tabId)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await refresh()
        }
    }

    /// Ask the Mac to open this project in a new tab (running claude).
    /// The new tab mirrors back through the normal sync within a few seconds.
    func openProject(_ p: ProjectRef, agent: String = "claude") {
        pendingOpens.insert(p.path)
        Task {
            try? await cloud.sendOpen(path: agent == "codex" ? "codex:" + p.path : p.path)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await refresh()
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await refresh()
            pendingOpens.remove(p.path) // stop the spinner even if the Mac never answered
        }
    }
}
