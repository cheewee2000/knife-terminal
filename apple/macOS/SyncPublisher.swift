import AppKit
import CloudKit
import KnifeKit

/// Mac side of the iOS mirror: publishes Tab records (coalesced), consumes
/// Input records, creates Alert records for push notifications.
///
/// Roles (Knife Terminal menu): the **executor** (the Mac mini) publishes its
/// tabs, runs jobs, and answers the phone; a **client** (the laptop) never
/// touches Tab/Input/Open records — it publishes its own project list, mirrors
/// the executor's tabs into `remoteTabs`, and posts job requests.
@MainActor
final class SyncPublisher: ObservableObject {
    static let roleKey = "knife.role"
    static var isExecutor: Bool { (UserDefaults.standard.string(forKey: roleKey) ?? "executor") == "executor" }
    let cloud = CloudSync(role: "mac")
    @Published var remoteTabs: [MirroredTab] = []   // client role: the executor's tabs (jobs included)
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
            if Self.isExecutor {
                try await cloud.clearStaleTabs()
                if !UserDefaults.standard.bool(forKey: "knife.legacyProjectsGone") {
                    try await cloud.deleteLegacyProjectsRecord()
                    UserDefaults.standard.set(true, forKey: "knife.legacyProjectsGone")
                }
            } else {
                // a client's tab ids collide with the executor's — never delete or publish them
                UserDefaults.standard.set([String](), forKey: "knife.publishedTabs")
                cloud.resetChangeToken() // mirror the executor's tabs from scratch
            }
            // one-time: re-walk the whole zone so leaked Alert records get purged
            if !UserDefaults.standard.bool(forKey: "knife.purgedAlerts") {
                cloud.resetChangeToken()
                UserDefaults.standard.set(true, forKey: "knife.purgedAlerts")
            }
        } catch {
            NSLog("knife sync: setup failed (will retry): \(error)")
            return
        }
        enabled = true
        NSApp.registerForRemoteNotifications()
        do { try await cloud.ensureDatabaseSubscription(); subReady = true }
        catch { NSLog("knife sync: db subscription failed (poll still works): \(error)") }
        // publish whatever is already open
        if Self.isExecutor {
            for wc in AppModel.shared.windows { for t in wc.tabs { dirty.insert(t.id) } }
            scheduleFlush(after: 0.5)
        }
        await consumeInputs()
        await publishProjectsIfChanged()
    }

    // ─── Project manifest: this machine's slice (both roles) ───

    private var lastProjectsJSON: Data?
    func publishProjectsIfChanged() async {
        guard enabled else { return }
        let refs = Manifest.localRefs()
        Manifest.write(local: refs)
        guard let json = try? JSONEncoder().encode(refs), json != lastProjectsJSON else { return }
        do { try await cloud.saveProjects(refs, machine: Manifest.machine); lastProjectsJSON = json }
        catch { NSLog("knife sync: projects publish failed (will retry): \(error)") }
    }

    /// A request typed here or on the phone. The executor runs it in a job
    /// tab right away; a client posts it for the executor to pick up.
    func postJob(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if Self.isExecutor { AppModel.shared.dispatchJob(t); return }
        Task { try? await cloud.sendJob(t) }
    }

    // ─── Publishing ───

    func tabOpened(_ tab: TabModel) { markDirty(tab.id, urgent: true) }
    func tabStateChanged(_ tab: TabModel) { markDirty(tab.id, urgent: true) }
    func tabOutput(_ tab: TabModel) { markDirty(tab.id, urgent: false) }

    func tabClosed(_ id: Int) {
        guard enabled, Self.isExecutor else { return }
        dirty.remove(id)
        Task { try? await cloud.deleteTabs([id]) } // failure logged by CloudSync
    }

    func publishAlert(tabTitle: String, message: String) {
        guard enabled, Self.isExecutor else { return }
        Task { try? await cloud.publishAlert(tabTitle: tabTitle, message: message) }
    }

    private func markDirty(_ id: Int, urgent: Bool) {
        guard enabled, Self.isExecutor else { return }
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
                let cwd = tab.lastReportedCwd ?? tab.opts.cwd
                snaps.append(TabSnapshot(tabId: tab.id, title: tab.title, emoji: tab.emoji,
                                         cwd: cwd, order: order,
                                         cols: tab.cols, rows: tab.rows,
                                         working: tab.working, attention: tab.attention,
                                         styled: tab.view.styledScreen(),
                                         chat: TranscriptReader.chatData(forCwd: cwd)))
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

    private var consuming = false
    func consumeInputs() async {
        guard enabled, !consuming else { return } // poll + push overlap; one fetch at a time
        consuming = true
        defer { consuming = false }
        guard let delta = try? await cloud.fetchChanges() else { return } // failure already logged by CloudSync
        // other machines' manifest slices → merged file for the job runner
        if !delta.projects.isEmpty || !delta.deletedProjectRecordNames.isEmpty {
            for (name, refs) in delta.projects { Manifest.remoteLists[name] = refs }
            for name in delta.deletedProjectRecordNames { Manifest.remoteLists.removeValue(forKey: name) }
            Manifest.write(local: Manifest.localRefs())
        }
        guard Self.isExecutor else {
            // client: mirror the executor's tabs; leave its Input/Open/Alert records alone
            var byId = Dictionary(uniqueKeysWithValues: remoteTabs.map { ($0.id, $0) })
            for t in delta.tabs { byId[t.id] = t }
            for name in delta.deletedTabRecordNames { byId.removeValue(forKey: name) }
            remoteTabs = byId.values.sorted { $0.order < $1.order }
            return
        }
        if !delta.garbage.isEmpty { Task { try? await cloud.deleteRecords(delta.garbage) } }
        guard !delta.inputs.isEmpty || !delta.opens.isEmpty || !delta.closes.isEmpty || !delta.seens.isEmpty
        else { return }
        for input in delta.inputs {
            guard let tab = AppModel.shared.tab(input.tabId) else { continue }
            var text = input.data
            if text.count > 1, text.hasSuffix("\r") {
                // Text and Enter must not land in one chunk: TUIs (Claude Code)
                // treat fast multi-char input as a paste and insert the CR as a
                // newline instead of submitting. Send the CR separately, later.
                text.removeLast()
                tab.view.send(txt: text)
                let view = tab.view
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { view.send(txt: "\r") }
            } else {
                tab.view.send(txt: text)
            }
        }
        // phone asked to open a project → new tab running claude, mirrored back
        // "codex:<path>" picks Codex CLI — the Open record can't grow a cmd
        // field without a Production CloudKit schema deploy, so it rides in path
        // "job:<text>" is a request to route + run (see knife-job.sh)
        for open in delta.opens where !open.path.isEmpty {
            if open.path.hasPrefix(CloudSync.jobPrefix) {
                AppModel.shared.dispatchJob(String(open.path.dropFirst(CloudSync.jobPrefix.count)))
            } else if open.path.hasPrefix("codex:") {
                AppModel.shared.openProject(String(open.path.dropFirst(6)), cmd: "codex")
            } else {
                AppModel.shared.openProject(open.path, cmd: "claude")
            }
        }
        // phone asked to close a tab
        for close in delta.closes {
            for wc in AppModel.shared.windows where wc.tabs.contains(where: { $0.id == close.tabId }) {
                wc.closeTab(close.tabId)
                break
            }
        }
        // phone viewed a tab → its "waiting for you" flag is acknowledged
        for seen in delta.seens {
            if let tab = AppModel.shared.tab(seen.tabId), tab.attention {
                tab.attention = false
                tabStateChanged(tab)
            }
        }
        try? await cloud.deleteRecords(delta.inputs.map { $0.recordID }
                                       + delta.opens.map { $0.recordID }
                                       + delta.closes.map { $0.recordID }
                                       + delta.seens.map { $0.recordID })
        // phone typed → screen will change; make sure it mirrors back fast
        for input in delta.inputs { markDirty(input.tabId, urgent: true) }
    }
}
