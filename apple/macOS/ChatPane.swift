import SwiftUI
import AppKit
import KnifeKit

/// The active tab's claude/codex session as chat (footer 'chat', ⌘⌥C): replies in full, every
/// tool call — edits included — as one line, so diffs never fill the pane. Lines typed in the
/// composer go to the tab like the phone's. No transcript for the tab → the terminal as usual.
struct ChatPane: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var tab: TabModel
    @State private var msgs: [ChatMessage] = []
    @State private var draft = ""

    var body: some View {
        Group {
            if msgs.isEmpty { TerminalPane(controller: controller) } else { chat }
        }
        .task(id: tab.id) {
            msgs = []
            while !Task.isCancelled {
                let cwd = tab.currentCwd
                let data = await Task.detached { TranscriptReader.chatData(forCwd: cwd) }.value
                msgs = data.flatMap(ChatTranscript.decode) ?? []
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 30) // titlebar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(msgs) { row($0) }
                        if tab.working { Text("working…").font(mono(11)).foregroundStyle(.secondary) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: msgs.last?.id) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            TextField("message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(mono(12)).lineLimit(1...6)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .onSubmit {
                    guard !draft.isEmpty else { return }
                    tab.view.typeLine(draft)
                    draft = ""
                }
        }
    }

    @ViewBuilder
    private func row(_ m: ChatMessage) -> some View {
        switch m.kind {
        case .user:
            Text(m.text).font(mono(12))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.07))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text((try? AttributedString(markdown: m.text, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text))
                .font(mono(12))
        case .tool:
            Text("› " + m.text).font(mono(10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
