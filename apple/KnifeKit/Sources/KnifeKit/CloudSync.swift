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

    public init(tabId: Int, title: String, emoji: String, cwd: String?, order: Int,
                cols: Int, rows: Int, working: Bool, attention: Bool, styled: Data) {
        self.tabId = tabId; self.title = title; self.emoji = emoji; self.cwd = cwd; self.order = order
        self.cols = cols; self.rows = rows; self.working = working; self.attention = attention; self.styled = styled
    }
}

public struct MirroredTab: Identifiable, Sendable {
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
    public var updatedAt: Date
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
}

public final class CloudSync: @unchecked Sendable {
    public static let containerID = "iCloud.com.cwandt.knifeterminal"
    public let container: CKContainer
    public let db: CKDatabase
    public let zoneID = CKRecordZone.ID(zoneName: "KnifeZone", ownerName: CKCurrentUserDefaultName)
    private let role: String // "mac" | "ios" — namespaces tokens + subscription ids
    private let defaults = UserDefaults.standard

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
        let key = "knife.zoneCreated.\(role)"
        if !force, defaults.bool(forKey: key) { return }
        let res = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        // per-zone failures don't throw at the top level — surface them
        for (_, r) in res.saveResults { if case .failure(let e) = r { throw e } }
        defaults.set(true, forKey: key)
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
        defaults.set(false, forKey: "knife.zoneCreated.\(role)")
        changeToken = nil
        try await ensureZone(force: true)
    }

    /// Silent push on any change in the zone (both sides).
    public func ensureDatabaseSubscription() async throws {
        let id = "knife-db-\(role)"
        if defaults.bool(forKey: "knife.sub.\(id)") { return }
        let sub = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        _ = try await db.modifySubscriptions(saving: [sub], deleting: [])
        defaults.set(true, forKey: "knife.sub.\(id)")
    }

    /// Visible push when the Mac creates an Alert record (iOS only).
    public func ensureAlertSubscription() async throws {
        let id = "knife-alerts"
        if defaults.bool(forKey: "knife.sub.\(id)") { return }
        let sub = CKQuerySubscription(recordType: "Alert", predicate: NSPredicate(value: true),
                                      subscriptionID: id, options: .firesOnRecordCreation)
        sub.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.alertLocalizationKey = "KNIFE_ALERT"
        info.alertLocalizationArgs = ["message"]
        info.soundName = "default"
        sub.notificationInfo = info
        _ = try await db.modifySubscriptions(saving: [sub], deleting: [])
        defaults.set(true, forKey: "knife.sub.\(id)")
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

    public func publishAlert(tabTitle: String, message: String) async throws {
        let r = CKRecord(recordType: "Alert",
                         recordID: CKRecord.ID(recordName: "alert-\(UUID().uuidString)", zoneID: zoneID))
        r["tabTitle"] = tabTitle as CKRecordValue
        r["message"] = message as CKRecordValue
        r["ts"] = Date() as CKRecordValue
        try await modify(save: [r], delete: nil)
        var alerts = defaults.stringArray(forKey: "knife.alerts") ?? []
        alerts.append(r.recordID.recordName)
        // keep the backlog bounded; older ones get cleaned on next launch
        if alerts.count > 50 { alerts.removeFirst(alerts.count - 50) }
        defaults.set(alerts, forKey: "knife.alerts")
    }

    public func clearOldAlerts() async throws {
        let names = defaults.stringArray(forKey: "knife.alerts") ?? []
        guard !names.isEmpty else { return }
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        try await modify(save: nil, delete: ids)
        defaults.set([String](), forKey: "knife.alerts")
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
        try await modify(save: nil, delete: ids)
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
                    default: break
                    }
                }
                delta.deletedTabRecordNames.append(contentsOf:
                    deletions.filter { $0.hasPrefix("tab-") })
                changeToken = token
                more = moreComing
            } catch let e as CKError where e.code == .changeTokenExpired {
                changeToken = nil
            } catch where Self.isZoneNotFound(error) {
                try await recoverMissingZone()
                return delta // zone is empty right after creation; nothing to fetch
            }
        }
        delta.inputs.sort { $0.ts < $1.ts }
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
            op.recordWasChangedBlock = { _, result in
                if case .success(let record) = result { mods.append(record) }
            }
            op.recordWithIDWasDeletedBlock = { id, _ in deletions.append(id.recordName) }
            op.recordZoneFetchResultBlock = { _, result in
                if case .success(let (token, _, moreComing)) = result {
                    newToken = token; more = moreComing
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
