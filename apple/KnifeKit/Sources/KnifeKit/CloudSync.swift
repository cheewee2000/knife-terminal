import Foundation
import CloudKit

// ─── CloudKit mirroring ───
// Private database, custom zone "KnifeZone". Three record types, each written by one side only:
//   Tab   — Mac-owned. One per open terminal tab: title/emoji/status + rendered text tail.
//   Input — iOS-owned. Keystrokes for a tab; Mac applies to the PTY and deletes.
//   Alert — Mac-owned. Created on attention; iOS has a visible-push query subscription on it.
// All reads go through zone-change fetches (no CKQuery), so no indexes are needed.
//
// Collaborative mode: the Mac puts a CKShare on one Tab record. A guest (another Apple ID,
// Mac or iPhone) accepts it, reads that tab from the shared database and writes Input records
// as children of it — the host consumes those like any other Input. Closing the tab (or the
// Mac relaunching) deletes the record, which ends the share.

public struct TabSnapshot: Sendable {
    public var tabId: Int
    public var title: String
    public var emoji: String
    public var cwd: String?
    public var order: Int
    public var cols: Int
    public var rows: Int
    public var working: Bool
    public var attention: Bool
    public var styled: Data
    public var chat: Data?       // encoded [ChatMessage] when the tab is a Claude session

    public init(tabId: Int, title: String, emoji: String, cwd: String?, order: Int,
                cols: Int, rows: Int, working: Bool, attention: Bool, styled: Data, chat: Data? = nil) {
        self.tabId = tabId; self.title = title; self.emoji = emoji; self.cwd = cwd; self.order = order
        self.cols = cols; self.rows = rows; self.working = working; self.attention = attention; self.styled = styled
        self.chat = chat
    }
}

/// Tab ids are per Mac, so several can publish into one zone: each starts at a stable hash of
/// its machine name × 10000 (records are "tab-<id>", Input/Seen/Close carry the id).
public enum TabIds {
    public static func base(machine: String) -> Int {
        let h = machine.utf8.reduce(5381) { ($0 &* 33 &+ Int($1)) & 0x7fff_ffff }
        return (h % 900 + 100) * 10_000 + 1
    }
    /// Which of `machines` runs this tab.
    public static func machine(of tabId: Int, among machines: [String]) -> String? {
        machines.first { let b = base(machine: $0); return (b..<b + 10_000).contains(tabId) }
    }
}

public struct MirroredTab: Identifiable, Sendable, Codable {
    public let id: String            // record name
    public var tabId: Int
    public var title: String
    public var emoji: String
    public var cwd: String?
    public var order: Int
    public var cols: Int
    public var rows: Int
    public var working: Bool
    public var attention: Bool
    public var styled: Data
    public var chat: Data
    public var updatedAt: Date
    public var share: SharedZone?    // set when this tab lives in someone else's zone (collaborative mode)

    public init(id: String, tabId: Int, title: String, emoji: String, cwd: String?,
                order: Int, cols: Int, rows: Int, working: Bool, attention: Bool,
                styled: Data, chat: Data, updatedAt: Date, share: SharedZone? = nil) {
        self.id = id; self.tabId = tabId; self.title = title; self.emoji = emoji
        self.cwd = cwd; self.order = order; self.cols = cols; self.rows = rows
        self.working = working; self.attention = attention
        self.styled = styled; self.chat = chat; self.updatedAt = updatedAt; self.share = share
    }
}

/// Where a shared tab lives: the host's zone in the guest's shared database, and the
/// CKShare record (deleting it from the shared database is how a guest leaves).
public struct SharedZone: Codable, Sendable, Hashable {
    public var owner: String        // host's CloudKit user record name
    public var zone: String
    public var shareRecord: String?
    public var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zone, ownerName: owner) }
    public init(owner: String, zone: String, shareRecord: String?) { self.owner = owner; self.zone = zone; self.shareRecord = shareRecord }
}

public struct RemoteInput: Sendable {
    public let recordID: CKRecord.ID
    public let tabId: Int
    public let data: String
    public let ts: Date
}

/// One project in the cross-machine manifest. Identity is the git remote URL
/// (the path is whichever machine wrote the entry); `description` and
/// `lastTouched` are the routing signals. Missing fields decode as nil so
/// records written by older builds still load.
public struct ProjectRef: Codable, Sendable, Identifiable, Equatable {
    public var name: String
    public var path: String
    public var remote: String?
    public var description: String?
    public var lastTouched: Date?
    public var runOn: String?       // where its jobs run: a machine name (Manifest.machine), "cloud", or nil = the executor
    public var id: String { remote ?? path }

    public init(name: String, path: String, remote: String? = nil, description: String? = nil, lastTouched: Date? = nil, runOn: String? = nil) {
        self.name = name; self.path = path; self.remote = remote; self.description = description; self.lastTouched = lastTouched; self.runOn = runOn
    }

    /// The run-on tags ride in one extra Projects record ("projects-where", written
    /// by whoever sets a tag — phone or any Mac) as path-less entries, so no record
    /// type or field had to be added: merge() strips them and applies the tag.
    public static let whereMachine = "where"
    public static func tags(_ lists: [[ProjectRef]]) -> [String: String] {
        var t: [String: String] = [:]
        for ref in lists.joined() where ref.path.isEmpty { if let r = ref.remote { t[r] = ref.runOn } }
        return t
    }
    public static func tagRefs(_ tags: [String: String]) -> [ProjectRef] {
        tags.map { ProjectRef(name: "", path: "", remote: $0.key, runOn: $0.value) }
    }

    /// The repo's web page for a git remote: git@host:o/r.git, ssh://git@host:22/o/r,
    /// https://user@host/o/r.git → https://host/o/r. nil for local-path remotes.
    public static func webURL(forRemote remote: String) -> URL? {
        var r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.hasSuffix(".git") { r.removeLast(4) }
        // a port only exists in the ssh:// form; in git@host:123/repo the digits are the owner
        if let m = r.firstMatch(of: #/^ssh://[^@/]+@([^:/]+)(?::\d+)?/(.+)$/#) { r = "https://\(m.1)/\(m.2)" }
        else if let m = r.firstMatch(of: #/^[^@/]+@([^:/]+):(.+)$/#) { r = "https://\(m.1)/\(m.2)" }
        guard var c = URLComponents(string: r), c.scheme?.hasPrefix("http") == true, c.host != nil else { return nil }
        c.scheme = "https"; c.user = nil; c.password = nil
        return c.url
    }

    /// Merge per-machine lists into one, keyed by remote (path when there is
    /// none): the most recently touched entry wins, a description beats none.
    /// Sorted newest first.
    public static func merge(_ lists: [[ProjectRef]]) -> [ProjectRef] {
        var byId: [String: ProjectRef] = [:]
        let tags = Self.tags(lists)
        for ref in lists.joined() where !ref.path.isEmpty {
            guard var cur = byId[ref.id] else { byId[ref.id] = ref; continue }
            if (ref.lastTouched ?? .distantPast) > (cur.lastTouched ?? .distantPast) {
                cur.name = ref.name; cur.path = ref.path; cur.lastTouched = ref.lastTouched
            }
            if cur.description?.isEmpty ?? true, let d = ref.description, !d.isEmpty { cur.description = d }
            byId[ref.id] = cur
        }
        for (id, tag) in tags { byId[id]?.runOn = tag }
        return byId.values.sorted { ($0.lastTouched ?? .distantPast) > ($1.lastTouched ?? .distantPast) }
    }
}

/// iOS asked the Mac to open a project in a new tab.
public struct RemoteOpen: Sendable {
    public let recordID: CKRecord.ID
    public let path: String
    public let ts: Date
}

/// iOS asked the Mac to close a tab.
public struct RemoteClose: Sendable {
    public let recordID: CKRecord.ID
    public let tabId: Int
    public let ts: Date
}

/// iOS viewed a tab — clear its attention ("waiting for you") flag on the Mac.
public struct RemoteSeen: Sendable {
    public let recordID: CKRecord.ID
    public let tabId: Int
    public let ts: Date
}

public struct ZoneDelta: Sendable {
    public var tabs: [MirroredTab] = []
    public var deletedTabRecordNames: [String] = []
    public var inputs: [RemoteInput] = []
    public var projects: [String: [ProjectRef]] = [:]   // manifest records that changed, by record name ("projects-<machine>")
    public var deletedProjectRecordNames: [String] = []
    public var opens: [RemoteOpen] = []
    public var closes: [RemoteClose] = []
    public var seens: [RemoteSeen] = []
    public var garbage: [CKRecord.ID] = []     // Alert records: push already fired, nobody reads them
    public var endedShares: [String] = []      // owners whose shared zone went away (share revoked / tab gone)
    /// Fetched from scratch (no change token): this is everything in the zone, and it
    /// carries no deletions, so whatever a cache holds beyond it no longer exists.
    public var full = false
    /// The server has more changes after this page: apply it, then fetch again.
    public var more = false
}

public final class CloudSync: @unchecked Sendable {
    public static let containerID = "iCloud.com.cwandt.knifeterminal"
    public let container: CKContainer
    public let db: CKDatabase
    public var sharedDB: CKDatabase { container.sharedCloudDatabase }
    public let zoneID: CKRecordZone.ID
    /// Set on a Mac that joined another Apple ID's zone through a zone-wide share:
    /// every operation then targets that zone in the shared database, so this
    /// Mac publishes tabs, consumes requests and routes jobs as a peer there.
    public let hostZone: SharedZone?
    private let role: String // "mac" | "ios" — namespaces tokens + subscription ids
    private let defaults = UserDefaults.standard
    // Setup (zone + subscriptions) is redone once per process — cheap, idempotent
    // upserts. Persisting "done" flags broke sync when the container environment
    // changed (Development → Production) and the flags outlived the data.
    private var setupDone: Set<String> = []

    /// Sync diagnostics: NSLog + ~/Library/Logs/knife-sync.log (Mac) or the app
    /// sandbox's Library/Logs (iOS). NSLog from the Mac app is invisible in the
    /// unified log on some machines, so the file is the reliable trail.
    public static func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        NSLog("knife sync: %@", msg)
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let dir = lib.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("knife-sync.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    public init(role: String, hostZone: SharedZone? = nil) {
        self.role = role
        self.hostZone = hostZone
        container = CKContainer(identifier: Self.containerID)
        db = hostZone == nil ? container.privateCloudDatabase : container.sharedCloudDatabase
        zoneID = hostZone?.zoneID ?? CKRecordZone.ID(zoneName: "KnifeZone", ownerName: CKCurrentUserDefaultName)
    }

    public func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    // ─── Setup ───

    public func ensureZone(force: Bool = false) async throws {
        if hostZone != nil { return } // the host owns it; a guest can't create zones in the shared database
        if !force, setupDone.contains("zone") { return }
        let res = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        // per-zone failures don't throw at the top level — surface them
        for (_, r) in res.saveResults { if case .failure(let e) = r { throw e } }
        setupDone.insert("zone")
    }

    /// True if the error is (or wraps, via partialFailure) a missing-zone error.
    public static func isZoneNotFound(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        if ck.code == .zoneNotFound || ck.code == .userDeletedZone { return true }
        if ck.code == .partialFailure, let partial = ck.partialErrorsByItemID {
            return partial.values.contains { isZoneNotFound($0) }
        }
        return false
    }

    /// Recreate the zone after a server-side zoneNotFound and forget the change token.
    private func recoverMissingZone() async throws {
        if let hostZone {
            Self.log("host zone \(hostZone.owner) is gone — the share ended; leave it (Shell → Leave Shared Mac)")
            throw CKError(.zoneNotFound)
        }
        Self.log("zone missing — recreating, change token dropped")
        changeToken = nil
        try await ensureZone(force: true)
    }

    /// Silent push on any change in the zone (both sides).
    public func ensureDatabaseSubscription() async throws {
        let id = "knife-db-\(role)"
        if setupDone.contains(id) { return }
        let sub = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        _ = try await db.modifySubscriptions(saving: [sub], deleting: [])
        setupDone.insert(id)
    }

    /// Silent push when a host updates a tab shared with us.
    public func ensureSharedSubscription() async throws {
        let id = "knife-shared-\(role)"
        if setupDone.contains(id) { return }
        let sub = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        _ = try await sharedDB.modifySubscriptions(saving: [sub], deleting: [])
        setupDone.insert(id)
    }

    /// Visible push when the Mac creates an Alert record (iOS only).
    public func ensureAlertSubscription() async throws {
        let id = "knife-alerts"
        if setupDone.contains(id) { return }
        let sub = CKQuerySubscription(recordType: "Alert", predicate: NSPredicate(value: true),
                                      subscriptionID: id, options: .firesOnRecordCreation)
        sub.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.alertLocalizationKey = "KNIFE_ALERT"
        info.alertLocalizationArgs = ["message"]
        info.soundName = "default"
        sub.notificationInfo = info
        _ = try await db.modifySubscriptions(saving: [sub], deleting: [])
        setupDone.insert(id)
    }

    // ─── Mac: publish ───

    private func recordID(forTab tabId: Int) -> CKRecord.ID {
        CKRecord.ID(recordName: "tab-\(tabId)", zoneID: zoneID)
    }

    public func saveTabs(_ snaps: [TabSnapshot]) async throws {
        guard !snaps.isEmpty else { return }
        func fill(_ r: CKRecord, _ s: TabSnapshot) -> CKRecord {
            r["tabId"] = s.tabId as CKRecordValue
            r["title"] = s.title as CKRecordValue
            r["emoji"] = s.emoji as CKRecordValue
            if let cwd = s.cwd { r["cwd"] = cwd as CKRecordValue }
            r["order"] = s.order as CKRecordValue
            r["cols"] = s.cols as CKRecordValue
            r["rows"] = s.rows as CKRecordValue
            r["working"] = (s.working ? 1 : 0) as CKRecordValue
            r["attention"] = (s.attention ? 1 : 0) as CKRecordValue
            r["styled"] = s.styled as CKRecordValue
            r["chat"] = (s.chat ?? Data()) as CKRecordValue // empty = no transcript; a key left unset keeps the server's old one
            r["updatedAt"] = Date() as CKRecordValue
            return r
        }
        try await modify(save: snaps.map { fill(CKRecord(recordType: "Tab", recordID: recordID(forTab: $0.tabId)), $0) }, delete: nil)
        updatePublished { for s in snaps { $0.insert("tab-\(s.tabId)") } }
        // tabs someone was invited into: their copy in the share zone
        let copies = locked { snaps.compactMap { s in shareRoots[s.tabId].map { fill($0, s) } } }
        if !copies.isEmpty { try await modify(db: privateDB, save: copies, delete: nil) }
    }

    /// saveTabs and deleteTabs run on whatever thread their task landed on, sometimes at once
    /// (a tab closing during a flush): an unguarded read-modify-write lost one of the updates.
    private let publishedLock = NSLock()
    private func locked<T>(_ body: () -> T) -> T { publishedLock.lock(); defer { publishedLock.unlock() }; return body() }
    private func updatePublished(_ change: (inout Set<String>) -> Void) {
        publishedLock.lock(); defer { publishedLock.unlock() }
        var published = Set(defaults.stringArray(forKey: publishedKey) ?? [])
        change(&published)
        defaults.set(Array(published), forKey: publishedKey)
    }

    public func deleteTabs(_ tabIds: [Int]) async throws {
        guard !tabIds.isEmpty else { return }
        let ids = tabIds.map { recordID(forTab: $0) }
        try await modify(save: nil, delete: ids)
        updatePublished { for t in tabIds { $0.remove("tab-\(t)") } }
        let shared = locked { tabIds.filter { shareRoots.removeValue(forKey: $0) != nil } }
        if !shared.isEmpty { await deleteShared(shared) }
    }

    /// Ends the sharing of these tabs: their copy and its CKShare leave the share zone.
    /// A failure keeps them on the list, and the next launch tries again.
    private func deleteShared(_ tabIds: [Int]) async {
        guard !tabIds.isEmpty else { return }
        do {
            try await modify(db: privateDB, save: nil, delete: tabIds.flatMap { [shareID(forTab: $0), sharedRecordID(forTab: $0)] })
        } catch where !Self.isZoneNotFound(error) { return } catch {}
        locked { defaults.set((defaults.array(forKey: sharedTabsKey) as? [Int] ?? []).filter { !tabIds.contains($0) }, forKey: sharedTabsKey) }
    }

    private var publishedKey: String { "knife.publishedTabs" }

    /// On launch, remove every Tab record a previous run left behind (tab ids restart at 1).
    public func clearStaleTabs() async throws {
        await deleteShared(defaults.array(forKey: sharedTabsKey) as? [Int] ?? [])
        let stale = defaults.stringArray(forKey: publishedKey) ?? []
        guard !stale.isEmpty else { return }
        let ids = stale.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        try await modify(save: nil, delete: ids)
        defaults.set([String](), forKey: publishedKey)
    }

    /// Publish this machine's slice of the project manifest (one Projects
    /// record per machine, JSON payload; readers merge them with ProjectRef.merge).
    public func saveProjects(_ refs: [ProjectRef], machine: String) async throws {
        let r = CKRecord(recordType: "Projects",
                         recordID: CKRecord.ID(recordName: "projects-" + machine, zoneID: zoneID))
        r["list"] = (try JSONEncoder().encode(refs)) as CKRecordValue
        r["updatedAt"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
    }

    /// Manifest slices read by record name. A launch needs the other machines' lists, and
    /// re-walking the zone for them takes half an hour once the zone has months of history.
    public func fetchProjects(machines: [String]) async throws -> [String: [ProjectRef]] {
        let ids = machines.map { CKRecord.ID(recordName: "projects-" + $0, zoneID: zoneID) }
        var out: [String: [ProjectRef]] = [:]
        for (id, result) in try await db.records(for: ids) { // a machine that never published is a per-record failure: skipped
            if case .success(let r) = result, let data = r["list"] as? Data,
               let refs = try? JSONDecoder().decode([ProjectRef].self, from: data) { out[id.recordName] = refs }
        }
        return out
    }

    /// The Alert record exists only to fire the phone's query subscription
    /// (the push payload carries the text). Creating it is the event; it is
    /// deleted right away so the zone doesn't fill with thousands of dead
    /// alerts — which made every from-scratch fetch crawl through them all.
    public func publishAlert(tabTitle: String, message: String) async throws {
        let r = CKRecord(recordType: "Alert",
                         recordID: CKRecord.ID(recordName: "alert-\(Int.random(in: 0..<64))", zoneID: zoneID)) // see slot()
        r["tabTitle"] = tabTitle as CKRecordValue
        r["message"] = message as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
        try await modify(save: nil, delete: [r.recordID])
    }

    /// Pre-manifest builds wrote a single "projects" record; the executor drops it once.
    public func deleteLegacyProjectsRecord() async throws {
        try await modify(save: nil, delete: [CKRecord.ID(recordName: "projects", zoneID: zoneID)])
    }

    // ─── Collaborative mode ───

    // A shared session is a copy of the tab's record in a zone of its own, in our private
    // database: CloudKit refuses a record share in a zone that has a zone-wide share (KnifeZone,
    // once another Mac runs in it), and a Mac that is a guest in a host's zone can't share there.
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private let shareZoneID = CKRecordZone.ID(zoneName: "KnifeShared", ownerName: CKCurrentUserDefaultName)
    private func sharedRecordID(forTab tabId: Int) -> CKRecord.ID { CKRecord.ID(recordName: "tab-\(tabId)", zoneID: shareZoneID) }
    private func shareID(forTab tabId: Int) -> CKRecord.ID { CKRecord.ID(recordName: "share-tab-\(tabId)", zoneID: shareZoneID) }
    /// The copies, kept as the server knows them (share reference included) and re-saved by
    /// saveTabs. Guarded by publishedLock. Tab ids restart with the app, so nothing outlives a run
    /// but the list of what to clean up.
    private var shareRoots: [Int: CKRecord] = [:]
    private let sharedTabsKey = "knife.sharedTabs"

    /// Host: the CKShare for a tab (created if there isn't one). The tab must already be
    /// published. Participants get read/write so they can type.
    public func share(tabId: Int, title: String) async throws -> CKShare {
        if locked({ shareRoots[tabId] != nil }), let existing = try? await privateDB.record(for: shareID(forTab: tabId)) as? CKShare { return existing }
        let res = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: shareZoneID)], deleting: [])
        for (_, r) in res.saveResults { if case .failure(let e) = r { throw e } }
        let src = try await db.record(for: recordID(forTab: tabId))
        let root = CKRecord(recordType: "Tab", recordID: sharedRecordID(forTab: tabId))
        for k in src.allKeys() { root[k] = src[k] }
        let share = CKShare(rootRecord: root, shareID: shareID(forTab: tabId))
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = "com.cwandt.knifeterminal.session" as CKRecordValue
        share.publicPermission = .none
        // on the cleanup list before it exists, so a crash in between can't strand it
        locked { defaults.set(Array(Set(defaults.array(forKey: sharedTabsKey) as? [Int] ?? []).union([tabId])), forKey: sharedTabsKey) }
        try await modify(db: privateDB, save: [root, share], delete: nil)
        locked { shareRoots[tabId] = root }
        Self.log("share saved for tab-\(tabId)")
        return share
    }

    /// What guests typed into the tabs we share (they write into the share zone).
    private func sharedInputs() async -> [RemoteInput] {
        if locked({ shareRoots.isEmpty }) { return [] }
        let key = "knife.shareZoneToken"
        let token = defaults.data(forKey: key).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do {
            let (mods, _, next, _) = try await zoneChanges(db: privateDB, zoneID: shareZoneID, since: token)
            if let next, let d = try? NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true) { defaults.set(d, forKey: key) }
            var delta = ZoneDelta()
            delta.absorb(mods.filter { $0.recordType == "Input" }, deletions: [])
            return delta.inputs
        } catch {
            if (error as? CKError)?.code == .changeTokenExpired { defaults.removeObject(forKey: key) }
            Self.log("shared input fetch failed: \(error)")
            return []
        }
    }

    /// Host: the zone-wide CKShare on our zone (created if there isn't one) — another
    /// Mac on a different Apple ID accepts it and runs its whole sync in our zone.
    /// CloudKit allows either record shares or a zone-wide share in a zone, not both,
    /// which is why invited sessions live in the share zone instead.
    public func shareZone() async throws -> CKShare {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await db.record(for: id) as? CKShare { return existing }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Knife Terminal" as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = "com.cwandt.knifeterminal.zone" as CKRecordValue
        share.publicPermission = .none
        try await modify(save: [share], delete: nil)
        Self.log("zone-wide share saved")
        return share
    }

    /// Guest: accept an invitation; the host's zone then shows up in fetchSharedChanges.
    public func accept(_ metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
        Self.log("accepted share from \(metadata.share.recordID.zoneID.ownerName)")
    }

    /// Guest: leave a share (a participant deleting the CKShare removes only themselves).
    public func leave(_ zone: SharedZone) async throws {
        guard let name = zone.shareRecord else { return }
        try await modify(db: sharedDB, save: nil, delete: [CKRecord.ID(recordName: name, zoneID: zone.zoneID)])
        sharedZoneToken[zone.owner] = nil
    }

    // ─── iOS: send input ───

    /// Names for records that are consumed and deleted. Every record name ever used leaves a
    /// tombstone that a from-scratch zone fetch walks, forever — a UUID per keystroke grew that
    /// walk to half an hour. So names are reused: 64 slots per device for these, one per tab
    /// for Seen/Close, 64 for alerts.
    // ponytail: the 65th unconsumed input/open from one device overwrites its oldest
    private let slotLock = NSLock()
    private func slot(_ kind: String) -> String {
        slotLock.lock(); defer { slotLock.unlock() }
        var tag = defaults.string(forKey: "knife.slotTag") ?? ""
        if tag.isEmpty { tag = String(UUID().uuidString.prefix(8)); defaults.set(tag, forKey: "knife.slotTag") }
        let n = defaults.integer(forKey: "knife.slotSeq")
        defaults.set((n + 1) % 64, forKey: "knife.slotSeq")
        return "\(kind)-\(tag)-\(n)"
    }

    /// Typed into a tab: our own Mac's, or a shared one (then the record is a child of the
    /// host's Tab record, in the host's zone — that's what makes it part of the share).
    public func sendInput(to tab: MirroredTab, text: String) async throws {
        guard let zone = tab.share else { return try await sendInput(tabId: tab.tabId, text: text) }
        let r = CKRecord(recordType: "Input",
                         recordID: CKRecord.ID(recordName: slot("input"), zoneID: zone.zoneID))
        r["tabId"] = tab.tabId as CKRecordValue
        r["data"] = text as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        r.parent = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tab-\(tab.tabId)", zoneID: zone.zoneID), action: .none)
        try await modify(db: sharedDB, save: [r], delete: nil)
    }

    public func sendInput(tabId: Int, text: String) async throws {
        let r = CKRecord(recordType: "Input",
                         recordID: CKRecord.ID(recordName: slot("input"), zoneID: zoneID))
        r["tabId"] = tabId as CKRecordValue
        r["data"] = text as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
    }

    /// iOS: tell the Mac a tab was viewed (clears its attention flag).
    public func sendSeen(tabId: Int) async throws {
        let r = CKRecord(recordType: "Seen",
                         recordID: CKRecord.ID(recordName: "seen-\(tabId)", zoneID: zoneID))
        r["tabId"] = tabId as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
    }

    /// iOS: ask the Mac to close a tab.
    public func sendClose(tabId: Int) async throws {
        let r = CKRecord(recordType: "Close",
                         recordID: CKRecord.ID(recordName: "close-\(tabId)", zoneID: zoneID))
        r["tabId"] = tabId as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
    }

    /// iOS: ask the Mac to open a project in a new tab (running claude).
    public func sendOpen(path: String) async throws {
        let r = CKRecord(recordType: "Open",
                         recordID: CKRecord.ID(recordName: slot("open"), zoneID: zoneID))
        r["path"] = path as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
    }

    /// Client → executor: a dictated/typed request to route and run. Rides in
    /// an Open record as "job:<text>" — a new record type would need a
    /// Production schema deploy, and the executor already consumes Opens.
    public static let jobPrefix = "job:"
    /// An Input whose data is this + base64 JPEG is a photo from the phone: the Mac saves it and
    /// pastes the path. Rides in Input.data (records cap at 1 MB) — no Production schema deploy.
    public static let imagePrefix = "\u{1}knife-image:"
    public func sendJob(_ text: String) async throws {
        try await sendOpen(path: Self.jobPrefix + text)
    }

    public func deleteRecords(_ ids: [CKRecord.ID]) async throws {
        let guests = ids.filter { $0.zoneID == shareZoneID } // consumed guest input, in the share zone
        if !guests.isEmpty { try await modify(db: privateDB, save: nil, delete: guests) }
        let ids = ids.filter { $0.zoneID != shareZoneID }
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: 400) { // CloudKit caps one op at 400 records
            try await modify(save: nil, delete: Array(ids[chunk..<min(chunk + 400, ids.count)]))
        }
    }

    // ─── Zone-change fetch (both sides) ───

    private var tokenKey: String { "knife.zoneToken.\(role)" + (hostZone.map { ".host-" + $0.owner } ?? "") }

    private var changeToken: CKServerChangeToken? {
        get {
            guard let d = defaults.data(forKey: tokenKey) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: d)
        }
        set {
            if let t = newValue, let d = try? NSKeyedArchiver.archivedData(withRootObject: t, requiringSecureCoding: true) {
                defaults.set(d, forKey: tokenKey)
            } else {
                defaults.removeObject(forKey: tokenKey)
            }
        }
    }

    public func resetChangeToken() { changeToken = nil }

    /// The zone's changes since the saved token — at most a few seconds' worth of pages;
    /// `more` says to call again. The token is saved with each batch, so a long catch-up
    /// survives the app being suspended instead of starting over each time.
    public func fetchChanges() async throws -> ZoneDelta {
        let t0 = Date()
        var delta = ZoneDelta()
        delta.full = changeToken == nil
        var token = changeToken, tombstones = 0, pages = 0
        do {
          repeat {
            let (mods, deletions, next, moreComing) = try await zoneChanges(since: token)
            delta.absorb(mods, deletions: deletions)
            tombstones += deletions.count
            token = next; delta.more = moreComing; pages += 1
          } while delta.more && Date().timeIntervalSince(t0) < 5
          changeToken = token
        } catch where pages > 0 {
            changeToken = token; delta.more = true // keep what the earlier pages brought; the next call meets the error again
        } catch where Self.isZoneNotFound(error) {
            try await recoverMissingZone()
            delta.full = true
            return delta // zone is empty right after creation; nothing to fetch
        } catch let e as CKError where e.code == .changeTokenExpired && changeToken != nil {
            // the one error that means the token is no good (also what a token from the other
            // container environment gets). Anything else keeps it: starting over is the
            // expensive path, and a server hiccup is not a reason to take it.
            Self.log("change token expired, resyncing from scratch")
            changeToken = nil
            return try await fetchChanges()
        } catch {
            Self.log("fetch failed: \(error)")
            throw error
        }
        delta.inputs += await sharedInputs()
        delta.inputs.sort { $0.ts < $1.ts }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if ms > 2000 || !delta.garbage.isEmpty || delta.more { // routine fetches run every few seconds; only the odd ones are worth a line
            Self.log("fetched \(delta.tabs.count) tabs, \(delta.deletedTabRecordNames.count) deleted (\(tombstones) tombstones), \(delta.inputs.count) inputs, \(delta.garbage.count) stale alerts in \(ms)ms\(delta.more ? ", \(pages) pages, more coming" : "")\(delta.full ? ", from scratch" : "")")
        }
        return delta
    }

    /// The tabs and project lists as they are right now, by query: those saved after `since`,
    /// plus the name of every tab that exists (so closed ones can be dropped).
    /// A from-scratch zone fetch walks the zone's whole write history before it reaches
    /// them — half an hour on a zone a Mac has published to for months — so a client
    /// that is catching up shows these meanwhile. Needs the queryable index CloudKit puts
    /// on `updatedAt` by default; without it this throws and the catch-up is all there is.
    public func queryLive(since: Date?) async throws -> (delta: ZoneDelta, tabNames: Set<String>) {
        func all(_ type: String, since: Date?, keys: [CKRecord.FieldKey]? = nil) async throws -> [CKRecord] {
            let query = CKQuery(recordType: type, predicate: NSPredicate(format: "updatedAt > %@", (since ?? .distantPast) as NSDate))
            var (results, cursor) = try await db.records(matching: query, inZoneWith: zoneID, desiredKeys: keys)
            var out: [CKRecord] = []
            while true {
                for case (_, .success(let r)) in results { out.append(r) }
                guard let c = cursor else { return out }
                (results, cursor) = try await db.records(continuingMatchFrom: c, desiredKeys: keys)
            }
        }
        var delta = ZoneDelta()
        let names = Set(try await all("Tab", since: nil, keys: []).map(\.recordID.recordName))
        delta.tabs = try await all("Tab", since: since).map { Self.tab($0, share: nil) }
        for r in try await all("Projects", since: since) {
            if let data = r["list"] as? Data, let refs = try? JSONDecoder().decode([ProjectRef].self, from: data) {
                delta.projects[r.recordID.recordName] = refs
            }
        }
        return (delta, names)
    }

    static func tab(_ record: CKRecord, share: SharedZone?) -> MirroredTab {
        MirroredTab(
            id: share.map { "\($0.owner)/" }.map { $0 + record.recordID.recordName } ?? record.recordID.recordName,
            tabId: record["tabId"] as? Int ?? 0,
            title: record["title"] as? String ?? "shell",
            emoji: record["emoji"] as? String ?? "🔪",
            cwd: record["cwd"] as? String,
            order: record["order"] as? Int ?? 0,
            cols: record["cols"] as? Int ?? 80,
            rows: record["rows"] as? Int ?? 24,
            working: (record["working"] as? Int ?? 0) == 1,
            attention: (record["attention"] as? Int ?? 0) == 1,
            styled: record["styled"] as? Data ?? Data(),
            chat: record["chat"] as? Data ?? Data(),
            updatedAt: record["updatedAt"] as? Date ?? .distantPast,
            share: share)
    }

    // ─── Guest: tabs shared with us ───

    private var sharedDBTokenKey: String { "knife.sharedDbToken.\(role)" }
    private var sharedZoneToken: [String: Data] {   // owner → archived CKServerChangeToken
        get { defaults.dictionary(forKey: "knife.sharedZoneTokens.\(role)") as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: "knife.sharedZoneTokens.\(role)") }
    }

    /// Tabs shared with us that changed, and shares that ended. Zone discovery goes through
    /// database changes (a new share = a new zone); each zone then has its own change token.
    public func fetchSharedChanges() async throws -> ZoneDelta {
        var delta = ZoneDelta()
        let dbToken = defaults.data(forKey: sharedDBTokenKey)
            .flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        let (changed, gone, newDBToken) = try await databaseChanges(db: sharedDB, since: dbToken)
        var tokens = sharedZoneToken
        for z in gone { delta.endedShares.append(z.ownerName); tokens[z.ownerName] = nil }
        for z in changed where z != hostZone?.zoneID {   // the zone we run in is fetchChanges' job
            let since = tokens[z.ownerName].flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
            var more = true, token = since
            while more {
                let res: (mods: [CKRecord], deletions: [String], token: CKServerChangeToken?, more: Bool)
                do { res = try await zoneChanges(db: sharedDB, zoneID: z, since: token) }
                catch where Self.isZoneNotFound(error) { delta.endedShares.append(z.ownerName); tokens[z.ownerName] = nil; break }
                for r in res.mods where r.recordType == "Tab" {
                    delta.tabs.append(Self.tab(r, share: SharedZone(owner: z.ownerName, zone: z.zoneName, shareRecord: r.share?.recordID.recordName)))
                }
                delta.deletedTabRecordNames.append(contentsOf: res.deletions.filter { $0.hasPrefix("tab-") }.map { "\(z.ownerName)/\($0)" })
                token = res.token; more = res.more
                if let t = token, let d = try? NSKeyedArchiver.archivedData(withRootObject: t, requiringSecureCoding: true) { tokens[z.ownerName] = d }
            }
        }
        sharedZoneToken = tokens
        if let t = newDBToken, let d = try? NSKeyedArchiver.archivedData(withRootObject: t, requiringSecureCoding: true) {
            defaults.set(d, forKey: sharedDBTokenKey)
        }
        if !delta.tabs.isEmpty || !delta.endedShares.isEmpty {
            Self.log("shared: \(delta.tabs.count) tabs, \(delta.deletedTabRecordNames.count) deleted, \(delta.endedShares.count) ended")
        }
        return delta
    }

    private func databaseChanges(db: CKDatabase, since token: CKServerChangeToken?) async throws
        -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: CKServerChangeToken?) {
        try await withCheckedThrowingContinuation { cont in
            let op = CKFetchDatabaseChangesOperation(previousServerChangeToken: token)
            var changed: [CKRecordZone.ID] = [], deleted: [CKRecordZone.ID] = []
            op.recordZoneWithIDChangedBlock = { changed.append($0) }
            op.recordZoneWithIDWasDeletedBlock = { deleted.append($0) }
            op.recordZoneWithIDWasPurgedBlock = { deleted.append($0) }
            op.recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock = { deleted.append($0) }
            op.fetchDatabaseChangesResultBlock = { result in
                switch result {
                case .success(let (token, _)): cont.resume(returning: (changed, deleted, token))
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            op.qualityOfService = .userInitiated
            db.add(op)
        }
    }

    private func zoneChanges(since token: CKServerChangeToken?) async throws
        -> (mods: [CKRecord], deletions: [String], token: CKServerChangeToken?, more: Bool) {
        try await zoneChanges(db: db, zoneID: zoneID, since: token)
    }

    private func zoneChanges(db: CKDatabase, zoneID: CKRecordZone.ID, since token: CKServerChangeToken?) async throws
        -> (mods: [CKRecord], deletions: [String], token: CKServerChangeToken?, more: Bool) {
        try await withCheckedThrowingContinuation { cont in
            let cfg = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            cfg.previousServerChangeToken = token
            let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: cfg])
            var mods: [CKRecord] = []
            var deletions: [String] = []
            var newToken: CKServerChangeToken?
            var more = false
            var zoneError: Error?
            op.fetchAllChanges = false // one page per call: the caller applies it and saves the token
            op.recordWasChangedBlock = { id, result in
                switch result {
                case .success(let record): mods.append(record)
                case .failure(let e): Self.log("record \(id.recordName) failed: \(e)")
                }
            }
            op.recordWithIDWasDeletedBlock = { id, _ in deletions.append(id.recordName) }
            op.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (token, _, moreComing)): newToken = token; more = moreComing
                case .failure(let e): zoneError = e
                }
            }
            // A failed zone still finishes the operation with .success. Returning that as
            // "no changes, no token" dropped the change token on every hiccup, and the
            // next fetch then re-walked the whole zone.
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    if let e = zoneError { cont.resume(throwing: e) } else { cont.resume(returning: (mods, deletions, newToken, more)) }
                case .failure(let e): cont.resume(throwing: zoneError ?? e)
                }
            }
            op.qualityOfService = .userInitiated
            db.add(op)
        }
    }

    /// Modify records; if the zone vanished (first run, or user wiped iCloud
    /// data), recreate it and retry once; a busy zone is retried when it says to.
    /// Per-record failures also surface.
    private func modify(db: CKDatabase? = nil, save: [CKRecord]?, delete: [CKRecord.ID]?, retried: Bool = false, attempt: Int = 0) async throws {
        do {
            try await runModify(db: db ?? self.db, save: save, delete: delete)
        } catch where Self.isZoneNotFound(error) && !retried && db == nil {
            try await recoverMissingZone()
            try await modify(save: save, delete: delete, retried: true)
        } catch let e as CKError where attempt < 3 && [.zoneBusy, .serviceUnavailable, .requestRateLimited].contains(e.code) {
            // the zone takes one write at a time ("Zone Busy") and says when to come back; callers
            // mostly `try?`, so without this a closed tab stayed on the phone and a keystroke was dropped
            try? await Task.sleep(for: .seconds((e.retryAfterSeconds ?? 2) + .random(in: 0...1)))
            try await modify(db: db, save: save, delete: delete, retried: retried, attempt: attempt + 1)
        } catch {
            Self.log("modify failed (\(save?.count ?? 0) saves, \(delete?.count ?? 0) deletes): \(error)")
            throw error
        }
    }

    private func runModify(db: CKDatabase, save: [CKRecord]?, delete: [CKRecord.ID]?) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: save, recordIDsToDelete: delete)
        op.savePolicy = .allKeys // single writer per record: last write wins
        var recordError: Error?
        op.perRecordSaveBlock = { _, result in
            // in an atomic batch every other record fails with "Batch Request Failed"; keep the cause
            if case .failure(let e) = result, recordError == nil || (recordError as? CKError)?.code == .batchRequestFailed { recordError = e }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    if let e = recordError { cont.resume(throwing: e) } else { cont.resume() }
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            op.qualityOfService = .userInitiated
            db.add(op)
        }
    }
}

extension ZoneDelta {
    /// One page of zone changes folded in.
    mutating func absorb(_ mods: [CKRecord], deletions: [String]) {
        // Pages are applied in order, and a record name can be deleted on one page and saved
        // again on a later one (names are reused), or the other way round: the later page wins.
        for record in mods {
            let name = record.recordID.recordName
            switch record.recordType {
            case "Tab":
                deletedTabRecordNames.removeAll { $0 == name }
                tabs.append(CloudSync.tab(record, share: nil))
            case "Input":
                inputs.append(RemoteInput(
                    recordID: record.recordID,
                    tabId: record["tabId"] as? Int ?? 0,
                    data: record["data"] as? String ?? "",
                    ts: record["ts"] as? Date ?? .distantPast))
            case "Projects":
                if let data = record["list"] as? Data,
                   let refs = try? JSONDecoder().decode([ProjectRef].self, from: data) {
                    deletedProjectRecordNames.removeAll { $0 == name }
                    projects[name] = refs
                }
            case "Open":
                opens.append(RemoteOpen(
                    recordID: record.recordID,
                    path: record["path"] as? String ?? "",
                    ts: record["ts"] as? Date ?? .distantPast))
            case "Close":
                closes.append(RemoteClose(
                    recordID: record.recordID,
                    tabId: record["tabId"] as? Int ?? 0,
                    ts: record["ts"] as? Date ?? .distantPast))
            case "Seen":
                seens.append(RemoteSeen(
                    recordID: record.recordID,
                    tabId: record["tabId"] as? Int ?? 0,
                    ts: record["ts"] as? Date ?? .distantPast))
            case "Alert":
                garbage.append(record.recordID)
            default: break
            }
        }
        let gone = Set(deletions)
        tabs.removeAll { gone.contains($0.id) }
        for name in deletions { projects[name] = nil }
        deletedTabRecordNames += deletions.filter { $0.hasPrefix("tab-") }
        deletedProjectRecordNames += deletions.filter { $0.hasPrefix("projects") }
    }
}
