import SwiftUI
import CloudKit
import KnifeKit
import UserNotifications

@MainActor
final class MirrorStore: ObservableObject {
    static let shared = MirrorStore()

    @Published var tabs: [MirroredTab] = []
    @Published var projectLists: [String: [ProjectRef]] = [:]   // one manifest slice per Mac
    var projects: [ProjectRef] { ProjectRef.merge(Array(projectLists.values)) }
    @Published var pendingJob = false
    @Published var pendingOpens: Set<String> = []   // paths we've asked the Mac to open
    @Published var iCloudAvailable = true
    @Published var lastSync: Date?
    @Published var syncError: String?               // last failure, nil once a sync succeeds
    @Published var offline = false
    private let cloud = CloudSync(role: "ios")
    private var started = false
    private var pendingInputs: [(tab: MirroredTab, text: String)] = []  // typed while offline; retried on refresh

    // ─── Local cache: last mirrored state survives relaunch + works offline ───

    private struct Cache: Codable {
        var tabs: [MirroredTab]
        var projectLists: [String: [ProjectRef]]
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
        tabs = c.tabs; projectLists = c.projectLists; lastSync = c.lastSync
        return true
    }

    private func saveCache() {
        let c = Cache(tabs: tabs, projectLists: projectLists, lastSync: lastSync)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: cacheURL, options: .atomic) }
    }

    func startup() async {
        guard !started else { return }
        started = true
        if DemoData.enabled {
            tabs = DemoData.tabs
            projectLists = ["demo": DemoData.projects]
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

    private var subsReady = false
    private func ensureSubscriptions() async {
        guard !subsReady else { return }
        do {
            try await cloud.ensureZone()
            try await cloud.ensureDatabaseSubscription()
            try await cloud.ensureAlertSubscription()
            try? await cloud.ensureSharedSubscription() // guests only need it once a share exists; cheap to keep
            subsReady = true
        } catch {
            CloudSync.log("ios setup failed (will retry): \(error)")
        }
    }

    /// One fetch at a time. Pushes arrive every ~1.5s while the Mac is busy;
    /// each used to start its own zone fetch and the overlapping full fetches
    /// on a fresh install never finished. A push during a fetch queues one more.
    private var refreshing = false, refreshQueued = false, catchingUp = false
    private var refreshBegan = Date.distantPast, generation = 0, step = ""
    func refresh() async {
        // A push can wake the app before any view exists. Fetching into the unloaded store
        // then saved "only what changed since the token" over the cache, and the next open
        // showed a list missing every session that had been idle — or an empty one.
        if !started { return await startup() }
        guard !DemoData.enabled else { return }
        if refreshing {
            guard refreshBegan.timeIntervalSinceNow < -45 else { refreshQueued = true; return }
            // A CloudKit call that never returns (seen on the phone: locked mid-fetch, then
            // reopened) held `refreshing` forever, and the list froze until the app was killed.
            // ponytail: the abandoned call may still land late and re-apply an older delta and
            // token; the next fetch re-delivers the current records, so it heals itself
            CloudSync.log("refresh stuck \(Int(-refreshBegan.timeIntervalSinceNow))s at \(step), starting over")
            generation += 1
        }
        let gen = generation
        refreshing = true
        defer { if gen == generation { refreshing = false } }
        repeat { refreshQueued = false; refreshBegan = Date(); await refreshOnce() } while gen == generation && refreshQueued && !catchingUp
        guard gen == generation else { return }
        // a long catch-up goes on a few seconds at a time on its own, not on the caller's time
        // (a pull-to-refresh spinner, a push's completion handler) — and the poll asking again
        // while it runs must not keep this caller looping until it ends
        if catchingUp { Task { await refresh() } }
    }

    /// @Published announces every assignment, changed or not, and this runs every few
    /// seconds: only a real change should redraw the screen.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<MirrorStore, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    private var liveQueried = Date.distantPast
    private func refreshOnce() async {
        // offline, accountStatus can't be determined — still show the cache
        step = "accountStatus"
        let status = try? await cloud.container.accountStatus()
        set(\.iCloudAvailable, status != .noAccount && status != .restricted)
        guard iCloudAvailable else {
            set(\.syncError, "not signed into iCloud")
            return
        }
        step = "subscriptions"
        await ensureSubscriptions()
        step = "flushInputs"
        await flushPendingInputs()
        step = "fetchChanges"
        var delta: ZoneDelta
        do { delta = try await cloud.fetchChanges() }
        catch {
            set(\.offline, (error as? CKError).map { [.networkUnavailable, .networkFailure].contains($0.code) } ?? true)
            set(\.syncError, offline ? "offline" : "\(error.localizedDescription)")
            catchingUp = false // the poll picks it up again
            return
        }
        set(\.offline, false)
        set(\.syncError, delta.more ? "catching up…" : nil)
        catchingUp = delta.more
        if !delta.garbage.isEmpty { Task { try? await cloud.deleteRecords(delta.garbage) } }
        // Catching up walks the zone's whole history before it reaches the live tabs: show them
        // from a query meanwhile (everything on the first page, then what changed, every 8s).
        if delta.full || delta.more && liveQueried.timeIntervalSinceNow < -8 {
            liveQueried = Date()
            step = "queryLive"
            do {
                let (live, names) = try await cloud.queryLive(since: delta.full ? nil : tabs.filter { $0.share == nil }.map(\.updatedAt).max())
                delta.tabs += live.tabs
                delta.projects.merge(live.projects) { _, new in new }
                // the query is the present; the catch-up's pages are the past
                delta.deletedTabRecordNames = delta.deletedTabRecordNames.filter { !names.contains($0) }
                    + tabs.filter { $0.share == nil && !names.contains($0.id) }.map(\.id)
            } catch { CloudSync.log("live query failed: \(error)") }
        }
        step = "fetchShared"
        // sessions other people invited us to (collaborative mode) ride along in the same list
        if !delta.more, let shared = try? await cloud.fetchSharedChanges() {
            delta.tabs += shared.tabs
            delta.deletedTabRecordNames += shared.deletedTabRecordNames
            delta.endedShares = shared.endedShares
        }
        if lastSync.map({ $0.timeIntervalSinceNow < -30 }) ?? true { lastSync = Date() } // shown to the minute
        // the poll finds nothing new most of the time: don't republish the list or rewrite the cache
        guard delta.full || !delta.tabs.isEmpty || !delta.deletedTabRecordNames.isEmpty || !delta.endedShares.isEmpty
                || !delta.projects.isEmpty || !delta.deletedProjectRecordNames.isEmpty else { return }
        // A from-scratch fetch lists every tab that exists and no deletions: merging it onto
        // the cache kept tabs the Mac closed long ago. Shared tabs come from their own fetch.
        var byId = Dictionary(uniqueKeysWithValues: tabs.filter { !delta.full || $0.share != nil }.map { ($0.id, $0) })
        for t in delta.tabs { byId[t.id] = t }
        for name in delta.deletedTabRecordNames { byId.removeValue(forKey: name) }
        for owner in delta.endedShares { byId = byId.filter { $0.value.share?.owner != owner } }
        tabs = byId.values.sorted { ($0.share != nil ? 1 : 0, $0.order) < ($1.share != nil ? 1 : 0, $1.order) }
        if delta.full { projectLists = [:] }
        for (name, refs) in delta.projects { projectLists[name] = refs }
        for name in delta.deletedProjectRecordNames { projectLists.removeValue(forKey: name) }
        pendingOpens = pendingOpens.filter { path in !tabs.contains { $0.cwd == path } }
        saveCache()
        step = "badge"
        let badge = tabs.filter { $0.attention }.count
        try? await UNUserNotificationCenter.current().setBadgeCount(badge)
    }

    /// Keystrokes go up immediately; if that fails (offline) they wait for the
    /// next refresh. In-memory only — a relaunch drops them.
    // ponytail: unpersisted queue, write it into the cache file if lost drafts become a complaint
    func send(_ text: String, to tab: MirroredTab) {
        pendingInputs.append((tab, text))
        hurry?.cancel()
        hurry = Task {
            await flushPendingInputs()
            // The answer is a Mac fetch, a typed line and a republish away, and the push for it
            // is throttled: ask every second for a while instead of waiting out the 4s poll.
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                await refresh()
            }
        }
    }
    private var hurry: Task<Void, Never>?

    private var flushing = false
    private func flushPendingInputs() async {
        guard !flushing else { return }   // send() and refresh() both flush; a second flusher re-sent the head and crashed on removeFirst
        flushing = true
        defer { flushing = false }
        while let next = pendingInputs.first {
            do { try await cloud.sendInput(to: next.tab, text: next.text) }
            catch { syncError = "send failed: \(error.localizedDescription)"; return }
            pendingInputs.removeFirst()
        }
    }

    /// Viewing a tab acknowledges its "waiting for you" flag — cleared locally
    /// right away, and on the Mac via a Seen record.
    func markSeen(_ tab: MirroredTab) {
        guard tab.attention else { return }
        if let i = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[i].attention = false }
        let badge = tabs.filter { $0.attention }.count
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(badge) }
        guard tab.share == nil else { return } // a guest's glance doesn't clear the host's flag
        Task { try? await cloud.sendSeen(tabId: tab.tabId) }
    }

    /// Ask the Mac to close a tab. Removed locally right away; the Mac deleting
    /// the Tab record makes it stick (or the next refresh brings it back if not).
    func closeTab(_ tab: MirroredTab) {
        tabs.removeAll { $0.id == tab.id }
        UserDefaults.standard.removeObject(forKey: "draft." + tab.id) // its unsent text goes with it
        if let zone = tab.share { Task { try? await cloud.leave(zone) }; saveCache(); return } // a shared tab: leave, don't close the host's
        Task {
            try? await cloud.sendClose(tabId: tab.tabId)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await refresh()
        }
    }

    /// Post a dictated/typed request; the executor routes it to a project and
    /// runs it in a job tab, which mirrors back here like any session.
    func postJob(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        pendingJob = true
        Task {
            do { try await cloud.sendJob(t) }
            catch { syncError = "request not sent: \(error.localizedDescription)"; pendingJob = false; return } // the text field is already cleared: say so
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await refresh()
            pendingJob = false
        }
    }

    /// Someone invited us to their session: accept, then the next refresh lists it.
    func accept(_ metadata: CKShare.Metadata) {
        Task {
            do { try await cloud.accept(metadata) } catch { syncError = "join failed: \(error.localizedDescription)" }
            await refresh()
        }
    }

    /// Macs publishing a manifest slice — the run-on choices.
    var machines: [String] {
        projectLists.keys.map { String($0.dropFirst("projects-".count)) }.filter { $0 != ProjectRef.whereMachine && $0 != "demo" }.sorted()
    }

    /// Where a project's jobs run (a machine, "cloud", nil = the executor): the
    /// shared "projects-where" record, rewritten whole (last writer wins).
    func setRunOn(_ p: ProjectRef, _ tag: String?) {
        guard let remote = p.remote else { return }
        let key = "projects-" + ProjectRef.whereMachine
        var t = ProjectRef.tags([projectLists[key] ?? []]); t[remote] = tag
        let refs = ProjectRef.tagRefs(t)
        projectLists[key] = refs
        Task { try? await cloud.saveProjects(refs, machine: ProjectRef.whereMachine) }
    }

    /// Ask the Mac to open this project in a new tab (running claude).
    /// The new tab mirrors back through the normal sync within a few seconds.
    func openProject(_ p: ProjectRef, agent: String = "claude") {
        pendingOpens.insert(p.path)
        Task {
            do { try await cloud.sendOpen(path: agent == "codex" ? "codex:" + p.path : p.path) }
            catch { syncError = "open not sent: \(error.localizedDescription)"; pendingOpens.remove(p.path); return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await refresh()
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await refresh()
            pendingOpens.remove(p.path) // stop the spinner even if the Mac never answered
        }
    }
}
