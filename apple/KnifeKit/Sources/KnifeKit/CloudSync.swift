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
    public var id: String { remote ?? path }

    public init(name: String, path: String, remote: String? = nil, description: String? = nil, lastTouched: Date? = nil) {
        self.name = name; self.path = path; self.remote = remote; self.description = description; self.lastTouched = lastTouched
    }

    /// The repo's web page for a git remote: git@host:o/r.git, ssh://git@host:22/o/r,
    /// https://user@host/o/r.git → https://host/o/r. nil for local-path remotes.
    public static func webURL(forRemote remote: String) -> URL? {
        var r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.hasSuffix(".git") { r.removeLast(4) }
        if let m = r.firstMatch(of: #/^(?:ssh://)?[^@/]+@([^:/]+)[:/](?:\d+/)?(.+)$/#) { r = "https://\(m.1)/\(m.2)" }
        guard var c = URLComponents(string: r), c.scheme?.hasPrefix("http") == true, c.host != nil else { return nil }
        c.scheme = "https"; c.user = nil; c.password = nil
        return c.url
    }

    /// Merge per-machine lists into one, keyed by remote (path when there is
    /// none): the most recently touched entry wins, a description beats none.
    /// Sorted newest first.
    public static func merge(_ lists: [[ProjectRef]]) -> [ProjectRef] {
        var byId: [String: ProjectRef] = [:]
        for ref in lists.joined() {
            guard var cur = byId[ref.id] else { byId[ref.id] = ref; continue }
            if (ref.lastTouched ?? .distantPast) > (cur.lastTouched ?? .distantPast) {
                cur.name = ref.name; cur.path = ref.path; cur.lastTouched = ref.lastTouched
            }
            if cur.description?.isEmpty ?? true, let d = ref.description, !d.isEmpty { cur.description = d }
            byId[ref.id] = cur
        }
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
}

public final class CloudSync: @unchecked Sendable {
    public static let containerID = "iCloud.com.cwandt.knifeterminal"
    public let container: CKContainer
    public let db: CKDatabase
    public var sharedDB: CKDatabase { container.sharedCloudDatabase }
    public let zoneID = CKRecordZone.ID(zoneName: "KnifeZone", ownerName: CKCurrentUserDefaultName)
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

    /// Network/server hiccups: keep tokens and retry later. Anything else is a
    /// real protocol error worth resetting cached state over.
    public static func isTransient(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return true } // URLError etc.
        switch ck.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable: return true
        default: return false
        }
    }

    public init(role: String) {
        self.role = role
        container = CKContainer(identifier: Self.containerID)
        db = container.privateCloudDatabase
    }

    public func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    // ─── Setup ───

    public func ensureZone(force: Bool = false) async throws {
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
        let records = snaps.map { s in
            let r = CKRecord(recordType: "Tab", recordID: recordID(forTab: s.tabId))
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
            if let chat = s.chat { r["chat"] = chat as CKRecordValue }
            r["updatedAt"] = Date() as CKRecordValue
            return r
        }
        try await modify(save: records, delete: nil)
        var published = Set(defaults.stringArray(forKey: publishedKey) ?? [])
        for s in snaps { published.insert("tab-\(s.tabId)") }
        defaults.set(Array(published), forKey: publishedKey)
    }

    public func deleteTabs(_ tabIds: [Int]) async throws {
        guard !tabIds.isEmpty else { return }
        let ids = tabIds.map { recordID(forTab: $0) }
        try await modify(save: nil, delete: ids)
        var published = Set(defaults.stringArray(forKey: publishedKey) ?? [])
        for t in tabIds { published.remove("tab-\(t)") }
        defaults.set(Array(published), forKey: publishedKey)
    }

    private var publishedKey: String { "knife.publishedTabs" }

    /// On launch, remove every Tab record a previous run left behind (tab ids restart at 1).
    public func clearStaleTabs() async throws {
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

    /// The Alert record exists only to fire the phone's query subscription
    /// (the push payload carries the text). Creating it is the event; it is
    /// deleted right away so the zone doesn't fill with thousands of dead
    /// alerts — which made every from-scratch fetch crawl through them all.
    public func publishAlert(tabTitle: String, message: String) async throws {
        let r = CKRecord(recordType: "Alert",
                         recordID: CKRecord.ID(recordName: "alert-\(UUID().uuidString)", zoneID: zoneID))
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

    /// Host: the CKShare on a tab's record (created if there isn't one). The record must
    /// already be published. Participants get read/write so they can type.
    public func share(tabId: Int, title: String) async throws -> CKShare {
        let root = try await db.record(for: recordID(forTab: tabId))
        if let ref = root.share, let existing = try? await db.record(for: ref.recordID) as? CKShare { return existing }
        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = "com.cwandt.knifeterminal.session" as CKRecordValue
        share.publicPermission = .none
        try await modify(save: [root, share], delete: nil)
        Self.log("share saved for tab-\(tabId)")
        return share
    }

    /// Guest: accept an invitation; the host's zone then shows up in fetchSharedChanges.
    public func accept(_ metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
        Self.log("accepted share from \(metadata.rootRecordID.zoneID.ownerName)")
    }

    /// Guest: leave a share (a participant deleting the CKShare removes only themselves).
    public func leave(_ zone: SharedZone) async throws {
        guard let name = zone.shareRecord else { return }
        try await modify(db: sharedDB, save: nil, delete: [CKRecord.ID(recordName: name, zoneID: zone.zoneID)])
        sharedZoneToken[zone.owner] = nil
    }

    // ─── iOS: send input ───

    /// Typed into a tab: our own Mac's, or a shared one (then the record is a child of the
    /// host's Tab record, in the host's zone — that's what makes it part of the share).
    public func sendInput(to tab: MirroredTab, text: String) async throws {
        guard let zone = tab.share else { return try await sendInput(tabId: tab.tabId, text: text) }
        let r = CKRecord(recordType: "Input",
                         recordID: CKRecord.ID(recordName: "input-\(UUID().uuidString)", zoneID: zone.zoneID))
        r["tabId"] = tab.tabId as CKRecordValue
        r["data"] = text as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        r.parent = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tab-\(tab.tabId)", zoneID: zone.zoneID), action: .none)
        try await modify(db: sharedDB, save: [r], delete: nil)
    }

    public func sendInput(tabId: Int, text: String) async throws {
        let r = CKRecord(recordType: "Input",
                         recordID: CKRecord.ID(recordName: "input-\(UUID().uuidString)", zoneID: zoneID))
        r["tabId"] = tabId as CKRecordValue
        r["data"] = text as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
    }

    /// iOS: tell the Mac a tab was viewed (clears its attention flag).
    public func sendSeen(tabId: Int) async throws {
        let r = CKRecord(recordType: "Seen",
                         recordID: CKRecord.ID(recordName: "seen-\(UUID().uuidString)", zoneID: zoneID))
        r["tabId"] = tabId as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
    }

    /// iOS: ask the Mac to close a tab.
    public func sendClose(tabId: Int) async throws {
        let r = CKRecord(recordType: "Close",
                         recordID: CKRecord.ID(recordName: "close-\(UUID().uuidString)", zoneID: zoneID))
        r["tabId"] = tabId as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
    }

    /// iOS: ask the Mac to open a project in a new tab (running claude).
    public func sendOpen(path: String) async throws {
        let r = CKRecord(recordType: "Open",
                         recordID: CKRecord.ID(recordName: "open-\(UUID().uuidString)", zoneID: zoneID))
        r["path"] = path as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
    }

    /// Client → executor: a dictated/typed request to route and run. Rides in
    /// an Open record as "job:<text>" — a new record type would need a
    /// Production schema deploy, and the executor already consumes Opens.
    public static let jobPrefix = "job:"
    public func sendJob(_ text: String) async throws {
        try await sendOpen(path: Self.jobPrefix + text)
    }

    public func deleteRecords(_ ids: [CKRecord.ID]) async throws {
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: 400) { // CloudKit caps one op at 400 records
            try await modify(save: nil, delete: Array(ids[chunk..<min(chunk + 400, ids.count)]))
        }
    }

    // ─── Zone-change fetch (both sides) ───

    private var tokenKey: String { "knife.zoneToken.\(role)" }

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

    public func fetchChanges() async throws -> ZoneDelta {
        let t0 = Date()
        var delta = ZoneDelta()
        var more = true
        while more {
            do {
                let (mods, deletions, token, moreComing) = try await zoneChanges(since: changeToken)
                for record in mods {
                    switch record.recordType {
                    case "Tab":
                        delta.tabs.append(Self.tab(record, share: nil))
                    case "Input":
                        delta.inputs.append(RemoteInput(
                            recordID: record.recordID,
                            tabId: record["tabId"] as? Int ?? 0,
                            data: record["data"] as? String ?? "",
                            ts: record["ts"] as? Date ?? .distantPast))
                    case "Projects":
                        if let data = record["list"] as? Data,
                           let refs = try? JSONDecoder().decode([ProjectRef].self, from: data) {
                            delta.projects[record.recordID.recordName] = refs
                        }
                    case "Open":
                        delta.opens.append(RemoteOpen(
                            recordID: record.recordID,
                            path: record["path"] as? String ?? "",
                            ts: record["ts"] as? Date ?? .distantPast))
                    case "Close":
                        delta.closes.append(RemoteClose(
                            recordID: record.recordID,
                            tabId: record["tabId"] as? Int ?? 0,
                            ts: record["ts"] as? Date ?? .distantPast))
                    case "Seen":
                        delta.seens.append(RemoteSeen(
                            recordID: record.recordID,
                            tabId: record["tabId"] as? Int ?? 0,
                            ts: record["ts"] as? Date ?? .distantPast))
                    case "Alert":
                        delta.garbage.append(record.recordID)
                    default: break
                    }
                }
                delta.deletedTabRecordNames.append(contentsOf:
                    deletions.filter { $0.hasPrefix("tab-") })
                delta.deletedProjectRecordNames.append(contentsOf:
                    deletions.filter { $0.hasPrefix("projects") })
                changeToken = token
                more = moreComing
            } catch where Self.isZoneNotFound(error) {
                try await recoverMissingZone()
                return delta // zone is empty right after creation; nothing to fetch
            } catch where changeToken != nil && !Self.isTransient(error) {
                // expired token, or one minted by another container environment:
                // start over from scratch (a second failure throws below)
                Self.log("fetch failed with token, resyncing from scratch: \(error)")
                changeToken = nil
            } catch {
                Self.log("fetch failed: \(error)")
                throw error
            }
        }
        delta.inputs.sort { $0.ts < $1.ts }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if ms > 2000 || !delta.garbage.isEmpty { // routine fetches run every ~1.5s; only the odd ones are worth a line
            Self.log("fetched \(delta.tabs.count) tabs, \(delta.deletedTabRecordNames.count) deleted, \(delta.inputs.count) inputs, \(delta.garbage.count) stale alerts in \(ms)ms")
        }
        return delta
    }

    private static func tab(_ record: CKRecord, share: SharedZone?) -> MirroredTab {
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
        for z in changed {
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
                case .failure(let e): Self.log("zone fetch result failed: \(e)")
                }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: cont.resume(returning: (mods, deletions, newToken, more))
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            op.qualityOfService = .userInitiated
            db.add(op)
        }
    }

    /// Modify records; if the zone vanished (first run, or user wiped iCloud
    /// data), recreate it and retry once. Per-record failures also surface.
    private func modify(db: CKDatabase? = nil, save: [CKRecord]?, delete: [CKRecord.ID]?, retried: Bool = false) async throws {
        do {
            try await runModify(db: db ?? self.db, save: save, delete: delete)
        } catch where Self.isZoneNotFound(error) && !retried && db == nil {
            try await recoverMissingZone()
            try await modify(save: save, delete: delete, retried: true)
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
            if case .failure(let e) = result, recordError == nil { recordError = e }
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
