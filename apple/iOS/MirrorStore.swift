import SwiftUI
import CloudKit
import KnifeKit

@MainActor
final class MirrorStore: ObservableObject {
    static let shared = MirrorStore()

    @Published var tabs: [MirroredTab] = []
    @Published var iCloudAvailable = true
    @Published var lastSync: Date?
    private let cloud = CloudSync(role: "ios")
    private var started = false

    func startup() async {
        guard !started else { return }
        started = true
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
        lastSync = Date()
        let badge = tabs.filter { $0.attention }.count
        try? await UNUserNotificationCenter.current().setBadgeCount(badge)
    }

    func send(_ text: String, to tabId: Int) {
        Task { try? await cloud.sendInput(tabId: tabId, text: text) }
    }
}

import UserNotifications
