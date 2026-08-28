import SwiftUI
import CloudKit
import KnifeKit

@MainActor
final class MirrorStore: ObservableObject {
    static let shared = MirrorStore()

    @Published var tabs: [MirroredTab] = []
    @Published var projects: [ProjectRef] = []
    @Published var pendingOpens: Set<String> = []   // paths we've asked the Mac to open
    @Published var iCloudAvailable = true
    @Published var lastSync: Date?
    private let cloud = CloudSync(role: "ios")
    private var started = false

    func startup() async {
        guard !started else { return }
        started = true
        if DemoData.enabled {
            tabs = DemoData.tabs
            projects = DemoData.projects
            lastSync = Date()
            return
        }
        iCloudAvailable = await cloud.accountAvailable()
        guard iCloudAvailable else { return }
        await ensureSubscriptions()
        await refresh()
    }

    private var subsReady = false
    private func ensureSubscriptions() async {
        guard !subsReady else { return }
        do {
            try await cloud.ensureZone()
            try await cloud.ensureDatabaseSubscription()
            try await cloud.ensureAlertSubscription()
            subsReady = true
        } catch {
            // container still propagating / offline — retried on next refresh
        }
    }

    func refresh() async {
        guard !DemoData.enabled else { return }
        guard iCloudAvailable else {
            iCloudAvailable = await cloud.accountAvailable()
            guard iCloudAvailable else { return }
            await startup()
            return
        }
        await ensureSubscriptions()
        guard let delta = try? await cloud.fetchChanges() else { return }
        var byId = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for t in delta.tabs { byId[t.id] = t }
        for name in delta.deletedTabRecordNames { byId.removeValue(forKey: name) }
        tabs = byId.values.sorted { $0.order < $1.order }
        if let refs = delta.projects { projects = refs }
        pendingOpens = pendingOpens.filter { path in !tabs.contains { $0.cwd == path } }
        lastSync = Date()
        let badge = tabs.filter { $0.attention }.count
        try? await UNUserNotificationCenter.current().setBadgeCount(badge)
    }

    func send(_ text: String, to tabId: Int) {
        Task { try? await cloud.sendInput(tabId: tabId, text: text) }
    }

    /// Viewing a tab acknowledges its "waiting for you" flag — cleared locally
    /// right away, and on the Mac via a Seen record.
    func markSeen(_ tab: MirroredTab) {
        guard tab.attention else { return }
        if let i = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[i].attention = false }
        let badge = tabs.filter { $0.attention }.count
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(badge) }
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
    func openProject(_ p: ProjectRef) {
        pendingOpens.insert(p.path)
        Task {
            try? await cloud.sendOpen(path: p.path)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await refresh()
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await refresh()
            pendingOpens.remove(p.path) // stop the spinner even if the Mac never answered
        }
    }
}

import UserNotifications
