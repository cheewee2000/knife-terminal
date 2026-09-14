import Foundation
import CloudKit

// ─── CloudKit mirroring ───
// Private database, custom zone "KnifeZone". Three record types, each written by one side only:
//   Tab   — Mac-owned. One per open terminal tab: title/emoji/status + rendered text tail.
//   Input — iOS-owned. Keystrokes for a tab; Mac applies to the PTY and deletes.
//   Alert — Mac-owned. Created on attention; iOS has a visible-push query subscription on it.
// All reads go through zone-change fetches (no CKQuery), so no indexes are needed.

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

    public init(id: String, tabId: Int, title: String, emoji: String, cwd: String?,
                order: Int, cols: Int, rows: Int, working: Bool, attention: Bool,
                styled: Data, chat: Data, updatedAt: Date) {
        self.id = id; self.tabId = tabId; self.title = title; self.emoji = emoji
        self.cwd = cwd; self.order = order; self.cols = cols; self.rows = rows
        self.working = working; self.attention = attention
        self.styled = styled; self.chat = chat; self.updatedAt = updatedAt
    }
}

public struct RemoteInput: Sendable {
    public let recordID: CKRecord.ID
    public let tabId: Int
    public let data: String
    public let ts: Date
}

/// One recent Claude Code project on the Mac (from ~/.claude.json).
public struct ProjectRef: Codable, Sendable, Identifiable, Equatable {
    public var name: String
    public var path: String
    public var id: String { path }

    public init(name: String, path: String) { self.name = name; self.path = path }
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
    public var projects: [ProjectRef]? = nil   // nil = projects record unchanged this fetch
    public var opens: [RemoteOpen] = []
    public var closes: [RemoteClose] = []
    public var seens: [RemoteSeen] = []
    public var garbage: [CKRecord.ID] = []     // Alert records: push already fired, nobody reads them
}

public final class CloudSync: @unchecked Sendable {
    /// The CloudKit container both apps share. CW&T's by default; a build signed
    /// by another team points at its own via the KnifeCloudContainer Info.plist
    /// key (fed by the KNIFE_CLOUD_CONTAINER build setting), which has to match
    /// the container in that build's entitlements.
    public static let containerID: String = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "KnifeCloudContainer") as? String,
           !s.isEmpty, !s.hasPrefix("$(") { return s }
        return "iCloud.com.cwandt.knifeterminal"
    }()
    public let container: CKContainer
    public let db: CKDatabase
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

    /// Stop server-side alert pushes (the phone's "push when a session needs you"
    /// switch); harmless when no such subscription exists.
    public func deleteAlertSubscription() async throws {
        _ = try await db.modifySubscriptions(saving: [], deleting: ["knife-alerts"])
        setupDone.remove("knife-alerts")
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

    /// Publish the Mac's recent-projects list (single record, JSON payload).
    public func saveProjects(_ refs: [ProjectRef]) async throws {
        let r = CKRecord(recordType: "Projects",
                         recordID: CKRecord.ID(recordName: "projects", zoneID: zoneID))
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

    // ─── iOS: send input ───

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
                        delta.tabs.append(MirroredTab(
                            id: record.recordID.recordName,
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
                            updatedAt: record["updatedAt"] as? Date ?? .distantPast))
                    case "Input":
                        delta.inputs.append(RemoteInput(
                            recordID: record.recordID,
                            tabId: record["tabId"] as? Int ?? 0,
                            data: record["data"] as? String ?? "",
                            ts: record["ts"] as? Date ?? .distantPast))
                    case "Projects":
                        if let data = record["list"] as? Data,
                           let refs = try? JSONDecoder().decode([ProjectRef].self, from: data) {
                            delta.projects = refs
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

    private func zoneChanges(since token: CKServerChangeToken?) async throws
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
            self.db.add(op)
        }
    }

    /// Modify records; if the zone vanished (first run, or user wiped iCloud
    /// data), recreate it and retry once. Per-record failures also surface.
    private func modify(save: [CKRecord]?, delete: [CKRecord.ID]?, retried: Bool = false) async throws {
        do {
            try await runModify(save: save, delete: delete)
        } catch where Self.isZoneNotFound(error) && !retried {
            try await recoverMissingZone()
            try await modify(save: save, delete: delete, retried: true)
        } catch {
            Self.log("modify failed (\(save?.count ?? 0) saves, \(delete?.count ?? 0) deletes): \(error)")
            throw error
        }
    }

    private func runModify(save: [CKRecord]?, delete: [CKRecord.ID]?) async throws {
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
            self.db.add(op)
        }
    }
}
