import SwiftUI
import AppKit
import KnifeKit

// ─── Session board: every live agent session on one screen ───
// One card per tab that has claude/codex running: status, the last exchange
// from its transcript, and a reply field that types into that tab. Made for
// clearing a queue of "needs input" without visiting each tab.

struct BoardCardData: Identifiable {
    let tabId: Int
    let agent: String          // "claude" | "codex"
    let messages: [ChatMessage] // the excerpt shown on the card
    var id: Int { tabId }
}

struct BoardView: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var theme = AppModel.shared.theme
    @State private var cards: [BoardCardData] = []
    @State private var refreshing = false
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if cards.isEmpty {
                VStack(spacing: 6) {
                    Text("no live agent sessions").font(ui(12)).foregroundStyle(.secondary)
                    Text("open a project from the sidebar").font(ui(10)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        ForEach(ordered, id: \.0.id) { card, tab in
                            SessionCard(tab: tab, messages: card.messages, agent: card.agent) {
                                controller.activate(tab.id)
                                controller.showBoard = false
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.nsColor(theme.current.background)))
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    /// Cards that want you first; otherwise sidebar order.
    private var ordered: [(BoardCardData, TabModel)] {
        let byId = Dictionary(uniqueKeysWithValues: controller.tabs.map { ($0.id, $0) })
        func rank(_ t: TabModel) -> Int {
            switch t.status { case .needsInput: 0; case .working: 1; case .ready: 2; case .idle: 3 }
        }
        return cards.enumerated()
            .compactMap { i, c in byId[c.tabId].map { (c, $0, i) } }
            .sorted { (rank($0.1), $0.2) < (rank($1.1), $1.2) }
            .map { ($0.0, $0.1) }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        // Snapshot on the main actor; the pid lookups and transcript reads happen
        // off it. The shell's real cwd is the one that matters: a tab opened with
        // ⌘T has no launch cwd at all, and `cd`-ing doesn't change the one it was
        // opened with, so both would leave the card blank.
        let snap = controller.tabs.map {
            (id: $0.id, pid: $0.shellPid, fallback: $0.lastReportedCwd ?? $0.opts.cwd, session: $0.claudeSessionId)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = snap.compactMap { t -> BoardCardData? in
                guard t.pid > 0, let agent = TabModel.runningAgent(underShell: t.pid) else { return nil }
                let cwd = TabModel.cwdOf(pid: t.pid) ?? t.fallback
                let all = TranscriptReader.messages(forCwd: cwd, sessionId: t.session)
                return BoardCardData(tabId: t.id, agent: agent, messages: Self.excerpt(all))
            }
            DispatchQueue.main.async {
                cards = fresh
                refreshing = false
            }
        }
    }

    /// The last thing you said and everything since, capped so cards stay short.
    static func excerpt(_ msgs: [ChatMessage]) -> [ChatMessage] {
        let fromUser = msgs.lastIndex { $0.kind == .user }.map { Array(msgs[$0...]) } ?? msgs
        return Array(fromUser.suffix(6))
    }
}

struct SessionCard: View {
    @ObservedObject var tab: TabModel
    let messages: [ChatMessage]
    let agent: String
    let open: () -> Void
    @ObservedObject var theme = AppModel.shared.theme
    @State private var draft = ""
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // Same height for every card; long exchanges scroll, newest at the bottom.
            ScrollView {
                body_.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(10)
        .frame(height: 300)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(tab.status == .needsInput ? theme.attentionColor : Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var isPulsing: Bool { tab.working && !tab.attention }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tab.attention ? theme.attentionColor : (tab.working ? theme.accentColor : .clear))
                .frame(width: 6, height: 6)
                .opacity(isPulsing && pulse ? 0.25 : 1.0)
                .animation(isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = isPulsing }
                .onChange(of: isPulsing) { _, now in pulse = now }
            Text(tab.emoji).font(.system(size: 12))
            Text(tab.title).font(ui(12, bold: true)).lineLimit(1)
            Spacer(minLength: 0)
            Text(statusWord)
                .font(ui(10))
                .foregroundStyle(tab.status == .needsInput ? theme.attentionColor : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    private var statusWord: String {
        switch tab.status {
        case .idle: agent
        case .working: "working…"
        case .ready: "ready"
        case .needsInput: "needs input"
        }
    }

    @ViewBuilder
    private var body_: some View {
        if messages.isEmpty {
            Text("no transcript yet").font(ui(10)).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(messages) { m in
                    switch m.kind {
                    case .user:
                        HStack {
                            Spacer(minLength: 24)
                            Text(markdown(m.text)).font(ui(11))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor.opacity(0.18)))
                        }
                    case .assistant:
                        Text(markdown(m.text)).font(ui(11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    case .tool:
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                            Text(m.text).font(Font.custom("JetBrains Mono", size: 10)).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            TextField("reply…", text: $draft)
                .textFieldStyle(.plain)
                .font(ui(11))
                .onSubmit(send)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Button("send", action: send)
                .buttonStyle(.plain)
                .font(ui(10))
                .foregroundStyle(draft.isEmpty ? Color.secondary : theme.accentColor)
                .disabled(draft.isEmpty)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Text and Enter in one chunk reads as a paste to TUIs; send the CR later (same as phone input).
        let view = tab.view
        view.send(txt: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { view.send(txt: "\r") }
        draft = ""
    }
}
