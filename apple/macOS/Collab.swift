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

    nonisolated func options(for service: NSSharingService, share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
        [.allowPrivate, .allowReadWrite] // invitees type too — that's the point
    }

    nonisolated func sharingService(_ service: NSSharingService, didCompleteForItems items: [Any], error: Error?) {
        guard let error, (error as? CKError)?.code != .operationCancelled else { return }
        Task { @MainActor in Self.alert("Couldn't save the invitation", error) }
    }

    private static func alert(_ title: String, _ error: Error) {
        let a = NSAlert(); a.messageText = title; a.informativeText = error.localizedDescription; a.runModal()
    }

    // ─── Guest ───

    func accept(_ metadata: CKShare.Metadata) {
        Task {
            do { try await cloud?.accept(metadata); await pull() }
            catch { Self.alert("Couldn't join the session", error) }
        }
    }

    /// Fetch shared tabs (on the sync poll and on silent pushes); errors are logged by CloudSync.
    func pull() async {
        guard let cloud, let delta = try? await cloud.fetchSharedChanges() else { return }
        for t in delta.tabs { apply(t) }
        for id in delta.deletedTabRecordNames { drop(id) }
        for owner in delta.endedShares { for (id, m) in mirrored where m.share?.owner == owner { drop(id) } }
    }

    private func apply(_ m: MirroredTab) {
        mirrored[m.id] = m
        let tab = guests[m.id] ?? open(m)
        if tab.title != m.title { tab.title = m.title }
        if tab.emoji != m.emoji { tab.emoji = m.emoji }
        if tab.working != m.working || tab.attention != m.attention { tab.working = m.working; tab.attention = m.attention }
        if let screen = StyledScreen.decode(m.styled) { tab.view.feed(text: screen.ansi()) }
    }

    private func open(_ m: MirroredTab) -> TabModel {
        let wc = AppModel.shared.frontWindow() ?? AppModel.shared.newWindow(withTab: false)
        let tab = wc.addTab(TabOptions(title: m.title, guest: m.id), activateIt: false)
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

    /// We closed a guest tab → leave the share.
    func tabClosed(_ tab: TabModel) {
        guard let id = tab.opts.guest, guests[id] === tab else { return }
        guests[id] = nil
        if let zone = mirrored.removeValue(forKey: id)?.share, let cloud { Task { try? await cloud.leave(zone) } }
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
