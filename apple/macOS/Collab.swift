import AppKit
import CloudKit
import KnifeKit

/// Collaborative mode. Host: "Invite to Session…" puts a CKShare on the tab's mirror record and
/// opens the system Add People sheet (Messages, Mail, link). Guest: an accepted invitation becomes
/// a tab here — a real terminal view redrawn from the host's mirrored screen (so the chat view,
/// ⌘F and selection all work), whose typing goes back to the host as Input records.
@MainActor
final class Collab: NSObject, NSCloudSharingServiceDelegate {
    static let shared = Collab()
    private var cloud: CloudSync? { AppModel.shared.sync?.cloud }
    private var guests: [String: TabModel] = [:]      // mirrored tab id → our tab
    private var mirrored: [String: MirroredTab] = [:]

    // ─── Host ───

    func invite(_ tab: TabModel) {
        guard tab.opts.guest == nil else { return }
        Task {
            do {
                guard let sync = AppModel.shared.sync, await sync.publishNow(tab) else {
                    throw NSError(domain: "knife", code: 1, userInfo: [NSLocalizedDescriptionKey: "iCloud isn't available on this Mac."])
                }
                let share = try await sync.cloud.share(tabId: tab.id, title: "\(tab.emoji) \(tab.title)")
                let provider = NSItemProvider()
                provider.registerCloudKitShare(share, container: sync.cloud.container)
                let service = NSSharingService(named: .cloudSharing)!
                service.delegate = self
                service.perform(withItems: [provider])
            } catch { Self.alert("Couldn't share this session", error) }
        }
    }

    /// Host: share the whole zone with a Mac on another Apple ID (the always-on mini on its own
    /// account). It then runs Knife as a peer in our zone: its tabs on our phone, our requests to it.
    func shareZone() {
        Task {
            do {
                guard let sync = AppModel.shared.sync, sync.cloud.hostZone == nil else {
                    throw NSError(domain: "knife", code: 1, userInfo: [NSLocalizedDescriptionKey: "This Mac is itself a guest in another Mac's zone."])
                }
                let share = try await sync.cloud.shareZone()
                let provider = NSItemProvider()
                provider.registerCloudKitShare(share, container: sync.cloud.container)
                let service = NSSharingService(named: .cloudSharing)!
                service.delegate = self
                service.perform(withItems: [provider])
            } catch { Self.alert("Couldn't share this Mac's zone", error) }
        }
    }

    /// Guest: stop running in the host's zone and go back to our own.
    func leaveHostZone() {
        guard let zone = SyncPublisher.hostZone else { return }
        Task {
            try? await cloud?.leave(zone)
            SyncPublisher.hostZone = nil
            AppModel.shared.restartSync()
        }
    }

    nonisolated func options(for service: NSSharingService, share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
        [.allowPrivate, .allowReadWrite] // invitees type too — that's the point
    }

    nonisolated func sharingService(_ service: NSSharingService, didCompleteForItems items: [Any], error: Error?) {
        guard let error else { return }
        // closing the sheet without inviting anyone arrives here as a "user cancelled" error
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError) || (error as? CKError)?.code == .operationCancelled { return }
        CloudSync.log("share sheet failed: \(error)")
        Task { @MainActor in Self.alert("Couldn't save the invitation", error) }
    }

    private static func alert(_ title: String, _ error: Error) {
        let a = NSAlert(); a.messageText = title; a.informativeText = error.localizedDescription; a.runModal()
    }

    // ─── Guest ───

    func accept(_ metadata: CKShare.Metadata) {
        Task {
            do {
                try await cloud?.accept(metadata)
                // a zone-wide share: this Mac now lives in the host's zone (see CloudSync.hostZone)
                if metadata.share.recordID.recordName == CKRecordNameZoneWideShare {
                    let z = metadata.share.recordID.zoneID
                    SyncPublisher.hostZone = SharedZone(owner: z.ownerName, zone: z.zoneName, shareRecord: CKRecordNameZoneWideShare)
                    AppModel.shared.restartSync()
                    return
                }
                await pull()
            } catch { Self.alert("Couldn't join the session", error) }
        }
    }

    /// Fetch shared tabs (on the sync poll and on silent pushes); errors are logged by CloudSync.
    func pull() async {
        guard let cloud, let delta = try? await cloud.fetchSharedChanges() else { return }
        let host = cloud.hostZone?.owner   // the zone we run in is not a guest session
        if let host, delta.endedShares.contains(host) {   // the host stopped sharing: back to our own zone
            CloudSync.log("host zone \(host) is gone — back to this Mac's own zone")
            SyncPublisher.hostZone = nil
            AppModel.shared.restartSync()
            return
        }
        for t in delta.tabs where t.share?.owner != host { apply(t) }
        for id in delta.deletedTabRecordNames { drop(id) }
        for owner in delta.endedShares { for (id, m) in mirrored where m.share?.owner == owner { drop(id) } }
    }

    // ─── Our own other Macs ───
    // Every Mac on the account publishes its sessions into one zone (that is what the phone
    // lists). Each of them is a tab on every other Mac too, drawn and typed into exactly like
    // a session someone shared: closing it here closes it there, as the phone's swipe does.

    private var closing: Set<String> = []   // asked their Mac to close: don't reopen while it does

    func mirror(_ delta: ZoneDelta) {
        for id in delta.deletedTabRecordNames { drop(id); closing.remove(id) }
        guard AppModel.shared.frontWindow() != nil else { return } // only a mini terminal is left: don't pop a window open
        for t in delta.tabs where !Manifest.owns(t.tabId) && !closing.contains(t.id) { apply(t) }
    }

    func dropMirrors() {
        for (id, m) in mirrored where m.share == nil { drop(id) }
        closing = []
    }

    /// The tab was looked at here: clear "waiting for you" on the Mac that runs it.
    func seen(_ tab: TabModel) {
        guard let id = tab.opts.guest, let m = mirrored[id], m.share == nil, m.attention, let cloud else { return }
        mirrored[id]?.attention = false
        Task { try? await cloud.sendSeen(tabId: m.tabId) }
    }

    private func apply(_ m: MirroredTab) {
        mirrored[m.id] = m
        let tab = guests[m.id] ?? open(m)
        if tab.title != m.title { tab.title = m.title }
        if tab.emoji != m.emoji { tab.emoji = m.emoji }
        if tab.working != m.working || tab.attention != m.attention { tab.working = m.working; tab.attention = m.attention }
        if m.attention, NSApp.isActive, let wc = AppModel.shared.window(of: tab), wc.window?.isKeyWindow ?? false, wc.activeTab === tab {
            tab.seen() // already on screen
        }
        if let screen = StyledScreen.decode(m.styled) { tab.view.feed(text: screen.ansi()) }
    }

    private func open(_ m: MirroredTab) -> TabModel {
        let wc = AppModel.shared.frontWindow() ?? AppModel.shared.newWindow(withTab: false)
        let machine = m.share == nil ? TabIds.machine(of: m.tabId, among: Manifest.machines) ?? "another Mac" : nil
        let tab = wc.addTab(TabOptions(title: m.title, guest: m.id, machine: machine), activateIt: false)
        guests[m.id] = tab
        tab.view.remoteSend = { [weak self] data in self?.send(data, to: m.id) }
        return tab
    }

    /// The host closed the tab, or the share ended.
    private func drop(_ id: String) {
        mirrored[id] = nil
        guard let tab = guests.removeValue(forKey: id) else { return }
        AppModel.shared.window(of: tab)?.closeTab(tab.id)
    }

    /// We closed a guest tab → leave the share. One of our own Macs' sessions: close it there
    /// — unless it only went down with its window or a quit; then it comes back with its next change.
    func tabClosed(_ tab: TabModel, byUser: Bool) {
        guard let id = tab.opts.guest, guests[id] === tab else { return }
        guests[id] = nil
        guard let m = mirrored.removeValue(forKey: id), let cloud else { return }
        if let zone = m.share { Task { try? await cloud.leave(zone) } }
        else if byUser { closing.insert(id); Task { try? await cloud.sendClose(tabId: m.tabId) } }
    }

    /// The host's transcript tail, for the chat view of a guest tab.
    func chat(_ id: String) -> [ChatMessage] { mirrored[id].flatMap { ChatTranscript.decode($0.chat) } ?? [] }

    // ─── Guest typing → host, coalesced so a burst of keys is one record ───

    private var outbox: [String: String] = [:]
    private var outboxTimer: Timer?

    private func send(_ data: ArraySlice<UInt8>, to id: String) {
        outbox[id, default: ""] += String(decoding: data, as: UTF8.self)
        guard outboxTimer?.isValid != true else { return }
        outboxTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
            Task { @MainActor in Collab.shared.flushOutbox() }
        }
    }

    private func flushOutbox() {
        let pending = outbox; outbox = [:]
        guard let cloud else { return }
        for (id, text) in pending {
            guard let m = mirrored[id] else { continue }
            Task { try? await cloud.sendInput(to: m, text: text) }
        }
    }
}
