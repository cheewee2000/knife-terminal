import SwiftUI
import AppKit
import KnifeKit

/// The active tab's claude/codex session as chat (footer 'chat', ⌘⌥C): replies in full, every
/// tool call as a line plus its full input (commands, todo lists) — never an edit's diff. The
/// statusline's usage bars, hidden with the terminal, are drawn natively above the composer.
/// Replies render as rich text (headings, lists, code, tables), colored by kind.
/// ⌘F finds within the session: every hit highlighted, ⌘G / ⌘⇧G step through them.
/// Lines typed in the composer go to the tab like the phone's. No transcript → the terminal.
struct ChatPane: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var tab: TabModel
    @ObservedObject private var theme = AppModel.shared.theme
    @State private var msgs: [ChatMessage] = []
    @State private var bars: [UsageBar] = []
    @State private var draft = ""
    @State private var finding = false
    @State private var query = ""
    @State private var hit = 0
    @FocusState private var findFocused: Bool

    // ponytail: hits are per message — ⌘G jumps message to message, all occurrences inside one
    // light up together; per-occurrence stepping needs occurrence counts threaded through blocks.
    private var hits: [String] {
        guard !query.isEmpty else { return [] }
        return msgs.filter { ($0.text + "\n" + ($0.detail ?? "")).localizedCaseInsensitiveContains(query) }.map(\.id)
    }
    private var currentHit: String? { hits.isEmpty ? nil : hits[min(hit, hits.count - 1)] }

    var body: some View {
        Group {
            if msgs.isEmpty { TerminalPane(controller: controller) } else {
                chat
                    .onAppear { controller.chatShowing = true }
                    .onDisappear { controller.chatShowing = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .knifeChatFind)) { note in
            guard note.object as? KnifeWindowController === controller,
                  let action = note.userInfo?["action"] as? Int else { return }
            switch NSTextFinder.Action(rawValue: action) {
            case .nextMatch: step(1)
            case .previousMatch: step(-1)
            default: finding = true; findFocused = true
            }
        }
        .task(id: tab.id) {
            msgs = []
            while !Task.isCancelled {
                let cwd = tab.currentCwd
                let data = await Task.detached { TranscriptReader.chatData(forCwd: cwd) }.value
                msgs = data.flatMap(ChatTranscript.decode) ?? []
                bars = UsageBar.parse(tab.view.styledScreen())
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 30) // titlebar
            if finding { findBar }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(msgs) { row($0).id($0.id) }
                        if tab.working { Text("working…").font(mono(11)).foregroundStyle(.secondary) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: msgs.last?.id) { if currentHit == nil { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: currentHit) { if let id = currentHit { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            }
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            if !bars.isEmpty {
                HStack(spacing: 20) { ForEach(bars) { usage($0) } }
                    .padding(.horizontal, 16).padding(.top, 8)
            }
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
        let cur = m.id == currentHit
        switch m.kind {
        case .user:
            plain(m.text, cur).font(mono(12))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(accent.opacity(0.25))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ChatMarkdown.blocks(m.text).enumerated()), id: \.offset) { block($0.element, cur) }
            }
        case .tool:
            let parts = m.text.components(separatedBy: " · ")
            VStack(alignment: .leading, spacing: 2) {
                (plain("› " + parts[0], cur).foregroundColor(ansi(5))
                 + plain(parts.count > 1 ? " · " + parts.dropFirst().joined(separator: " · ") : "", cur))
                    .font(mono(10)).lineLimit(1)
                if let d = m.detail { plain(d, cur).font(mono(10)).padding(.leading, 12) }
            }
            .foregroundStyle(.secondary)
        }
    }

    // ─── Rich replies: every kind of text gets the terminal theme's color for it ───
    // headings orange · code green · tool names + links gold · quotes grey · you tan

    private var accent: Color { Color(red: 0xB1 / 255.0, green: 0xA5 / 255.0, blue: 0x7E / 255.0) }
    private func ansi(_ i: Int) -> Color { Color(nsColor: theme.nsColor(theme.current.ansi[i])) }

    @ViewBuilder
    private func block(_ b: ChatBlock, _ cur: Bool) -> some View {
        switch b {
        case .heading(let level, let t):
            inline(t, cur).font(mono(level == 1 ? 17 : level == 2 ? 14 : 12)).foregroundStyle(ansi(3))
                .padding(.top, level <= 2 ? 6 : 2)
        case .code(let lines):
            plain(lines.joined(separator: "\n"), cur).font(mono(11)).foregroundStyle(ansi(2))
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
        case .item(let depth, let marker, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(accent)
                inline(t, cur)
            }
            .font(mono(12)).padding(.leading, CGFloat(depth) * 18)
        case .quote(let t):
            inline(t, cur).font(mono(12)).foregroundStyle(ansi(6))
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 2) }
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1).padding(.vertical, 4)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        ForEach(rows[i].indices, id: \.self) { j in
                            inline(rows[i][j], cur).foregroundStyle(i == 0 ? ansi(3) : .primary)
                        }
                    }
                    if i == 0 { Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1) }
                }
            }
            .font(mono(11))
            .padding(8).background(Color.primary.opacity(0.03))
        case .text(let t):
            inline(t, cur).font(mono(12))
        }
    }

    /// Inline markdown (bold, `code`, links) with code and links recolored, find hits marked.
    private func inline(_ s: String, _ cur: Bool) -> Text {
        var a = (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in a.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                a[run.range].foregroundColor = ansi(2)
                a[run.range].backgroundColor = Color.primary.opacity(0.06)
            } else if run.link != nil {
                a[run.range].foregroundColor = ansi(5)
                a[run.range].underlineStyle = .single
            }
        }
        return Text(mark(a, cur))
    }

    private func plain(_ s: String, _ cur: Bool) -> Text { Text(mark(AttributedString(s), cur)) }

    /// Highlight every occurrence of the find query; the current hit's message louder.
    private func mark(_ a: AttributedString, _ cur: Bool) -> AttributedString {
        guard finding, !query.isEmpty else { return a }
        var a = a
        var from = a.startIndex
        while let r = a[from...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = cur ? Color(nsColor: theme.findHighlight) : ansi(3).opacity(0.25)
            from = r.upperBound
        }
        return a
    }

    private var findBar: some View {
        HStack(spacing: 10) {
            TextField("find in session", text: $query)
                .textFieldStyle(.plain).font(mono(12))
                .focused($findFocused)
                .onSubmit { step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); findFocused = true }
                .onChange(of: query) { hit = 0 }
            Text(hits.isEmpty ? (query.isEmpty ? "" : "none") : "\(min(hit, hits.count - 1) + 1)/\(hits.count)")
                .font(mono(10)).foregroundStyle(.secondary)
            Button { step(-1) } label: { Text("↑").font(mono(12)) }.buttonStyle(.plain)
            Button { step(1) } label: { Text("↓").font(mono(12)) }.buttonStyle(.plain)
            Button { closeFind() } label: { Text("done").font(mono(10)) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
        .onExitCommand { closeFind() }
    }

    private func step(_ d: Int) {
        if !finding { finding = true; findFocused = true }
        guard !hits.isEmpty else { return }
        hit = (min(hit, hits.count - 1) + d + hits.count) % hits.count
    }

    private func closeFind() { finding = false; query = ""; findFocused = false }

    private func usage(_ bar: UsageBar) -> some View {
        HStack(spacing: 6) {
            Text(bar.label).font(mono(10))
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Rectangle().fill(Color.primary).frame(width: g.size.width * CGFloat(bar.pct) / 100)
                    }
                }
            Text("\(bar.pct)%" + (bar.reset.map { " · \($0)" } ?? "")).font(mono(10)).fixedSize()
        }
        .help(bar.title)
    }
}
