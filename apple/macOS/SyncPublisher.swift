import AppKit
import CloudKit
import KnifeKit

/// Mac side of the iOS mirror: publishes Tab records (coalesced), consumes
/// Input records, creates Alert records for push notifications.
@MainActor
final class SyncPublisher {
    let cloud = CloudSync(role: "mac")
    private var enabled = false
    var subReady = false
    private var dirty: Set<Int> = []          // tab ids with unpublished output
    private var flushTimer: Timer?
    private var pollTimer: Timer?
    private var lastFlush: [Int: Date] = [:]
    private let minInterval: TimeInterval = 1.5
    private var inFlight = false

    func start() {
        Task { await setup() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in
                guard let sync = AppModel.shared.sync else { return }
                if sync.enabled {
                    if !sync.subReady {
                        sync.subReady = (try? await sync.cloud.ensureDatabaseSubscription()) != nil
                    }
                    await sync.consumeInputs()
                    await sync.publishProjectsIfChanged()
                } else { await sync.setup() }
            }
        }
    }

    /// Idempotent; retried by the poll timer while iCloud/container isn't ready
    /// (a freshly created container can take a few minutes to propagate).
    private var settingUp = false
    private func setup() async {
        guard !settingUp, !enabled else { return }
        settingUp = true
        defer { settingUp = false }
        guard await cloud.accountAvailable() else { return }
        do {
            try await cloud.ensureZone()
            try await cloud.clearStaleTabs()
            try await cloud.clearOldAlerts()
        } catch {
            NSLog("knife sync: setup failed (will retry): \(error)")
            return
        }
        enabled = true
        NSApp.registerForRemoteNotifications()
        do { try await cloud.ensureDatabaseSubscription(); subReady = true }
        catch { NSLog("knife sync: db subscription failed (poll still works): \(error)") }
        // publish whatever is already open
        for wc in AppModel.shared.windows { for t in wc.tabs { dirty.insert(t.id) } }
        scheduleFlush(after: 0.5)
        await consumeInputs()
        await publishProjectsIfChanged()
    }

    // ─── Recent projects list (for the iOS "open a project" screen) ───

    private var lastProjectsJSON: Data?
    func publishProjectsIfChanged() async {
        guard enabled else { return }
        let refs = Projects.list().map { ProjectRef(name: $0.name, path: $0.path) }
        guard let json = try? JSONEncoder().encode(refs), json != lastProjectsJSON else { return }
        do { try await cloud.saveProjects(refs); lastProjectsJSON = json }
        catch { NSLog("knife sync: projects publish failed (will retry): \(error)") }
    }

    // ─── Publishing ───

    func tabOpened(_ tab: TabModel) { markDirty(tab.id, urgent: true) }
    func tabStateChanged(_ tab: TabModel) { markDirty(tab.id, urgent: true) }
    func tabOutput(_ tab: TabModel) { markDirty(tab.id, urgent: false) }

    func tabClosed(_ id: Int) {
        guard enabled else { return }
        dirty.remove(id)
        Task { try? await cloud.deleteTabs([id]) }
    }

    func publishAlert(tabTitle: String, message: String) {
        guard enabled else { return }
        Task { try? await cloud.publishAlert(tabTitle: tabTitle, message: message) }
    }

    private func markDirty(_ id: Int, urgent: Bool) {
        guard enabled else { return }
        dirty.insert(id)
        let elapsed = Date().timeIntervalSince(lastFlush[id] ?? .distantPast)
        scheduleFlush(after: urgent ? 0.1 : max(0.1, minInterval - elapsed))
    }

    private func scheduleFlush(after delay: TimeInterval) {
        if let t = flushTimer, t.isValid, t.fireDate.timeIntervalSinceNow < delay { return }
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in await AppModel.shared.sync?.flush() }
        }
    }

    private func flush() async {
        guard enabled, !inFlight, !dirty.isEmpty else { return }
        inFlight = true
        defer { inFlight = false }
        let ids = dirty; dirty.removeAll()
        var snaps: [TabSnapshot] = []
        var order = 0
        for wc in AppModel.shared.windows {
            for tab in wc.tabs {
                defer { order += 1 }
                guard ids.contains(tab.id) else { continue }
                snaps.append(TabSnapshot(tabId: tab.id, title: tab.title, emoji: tab.emoji,
                                         cwd: tab.lastReportedCwd ?? tab.opts.cwd, order: order,
                                         cols: tab.cols, rows: tab.rows,
                                         working: tab.working, attention: tab.attention,
                                         text: tab.view.renderedTail()))
                lastFlush[tab.id] = Date()
            }
        }
        guard !snaps.isEmpty else { return }
        do { try await cloud.saveTabs(snaps) }
        catch {
            for s in snaps { dirty.insert(s.tabId) } // retry on next change/poll
        }
    }

    // ─── Consuming input from iOS ───

    func remotePushReceived() {
        Task { await consumeInputs() }
    }

    func consumeInputs() async {
        guard enabled else { return }
        guard let delta = try? await cloud.fetchChanges(),
              !delta.inputs.isEmpty || !delta.opens.isEmpty || !delta.closes.isEmpty else { return }
        for input in delta.inputs {
            if let tab = AppModel.shared.tab(input.tabId) {
                tab.view.send(txt: input.data)
            }
        }
        // phone asked to open a project → new tab running claude, mirrored back
        for open in delta.opens where !open.path.isEmpty {
            AppModel.shared.dispatchOpen(open.path, cmd: "claude")
        }
        // phone asked to close a tab
        for close in delta.closes {
            for wc in AppModel.shared.windows where wc.tabs.contains(where: { $0.id == close.tabId }) {
                wc.closeTab(close.tabId)
                break
            }
        }
        try? await cloud.deleteRecords(delta.inputs.map { $0.recordID }
                                       + delta.opens.map { $0.recordID }
                                       + delta.closes.map { $0.recordID })
        // phone typed → screen will change; make sure it mirrors back fast
        for input in delta.inputs { markDirty(input.tabId, urgent: true) }
    }
}
