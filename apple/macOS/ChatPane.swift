import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KnifeKit

/// The active tab's claude/codex session as chat (footer 'chat', ⌘⌥C): messages in full and in
/// color; tool calls minimized — a run of them is one dim line, click to open, click a call for
/// its full input (commands, todo lists), never an edit's diff. The
/// statusline's usage bars, hidden with the terminal, are drawn natively above the composer,
/// led by the model + effort of the latest turn — click it to change either.
/// Replies render as rich text (headings, lists, code, tables), colored by kind.
/// ⌘F finds within the session: every hit highlighted, ⌘G / ⌘⇧G step through them.
/// Lines typed in the composer go to the tab like the phone's; a leading / lists the CLI's slash
/// commands (built-ins + skills on disk), ↑↓ Tab ⏎ complete, a known command tints the field. No transcript → the terminal.
struct ChatPane: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var tab: TabModel
    @ObservedObject private var theme = AppModel.shared.theme
    @State private var msgs: [ChatMessage] = []
    @State private var bars: [UsageBar] = []
    @State private var codex = false // the transcript is Codex's, not Claude Code's
    // parsed + linkified inline text, by cwd + source: parsing and the link scan's disk stats ran
    // for every visible message on every poll tick. ponytail: grows with the session, dies with the pane.
    private final class InlineCache { var made: [String: AttributedString] = [:]; var blocks: [String: [ChatBlock]] = [:] }
    @State private var inlineCache = InlineCache()
    @State private var cwd: String? // the shell's, for resolving relative paths into links
    @State private var echoes: [(text: String, sent: Date)] = [] // sent, not yet in the transcript (≤30s: a prompt answer never lands)
    @State private var finding = false
    @State private var expanded: Set<String> = [] // opened tool runs (first call's id) and single calls
    @State private var prompt: ScreenPrompt? // a numbered menu on the tab's screen (permission prompt)
    @State private var askStep: [String: Int] = [:]              // question card → question now up in the terminal
    @State private var askPicked: [String: [Int: Set<Int>]] = [:] // question card → question → options clicked here
    @State private var query = ""
    @State private var hit = 0
    @State private var dropped = "" // files dropped on the pane, quoted — the composer appends them to its draft
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
                    .environment(\.openURL, openLinks)
                    .onAppear { controller.chatPanes += 1 }
                    .onDisappear { controller.chatPanes -= 1 }
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
                cwd = tab.currentCwd
                let src = TranscriptReader.source(for: tab, cwd: cwd)
                var chat: (msgs: [ChatMessage], codex: Bool)?
                if let g = tab.opts.guest { chat = (Collab.shared.chat(g), false) } // the host's mirrored transcript
                else { chat = await Task.detached { TranscriptReader.chat(src) }.value }
                guard !Task.isCancelled else { return } // switched tabs mid-read: don't paint the old tab's chat
                // unchanged → no assignment: a new array re-lays out the lazy list mid-scroll
                let new = chat?.msgs ?? []
                if msgs != new { msgs = new }
                codex = chat?.codex ?? false
                let recent = msgs.suffix(8).filter { $0.kind == .user }.map(\.text)
                echoes.removeAll { e in e.sent.timeIntervalSinceNow < -30 || recent.contains(e.text) }
                let b = UsageBar.parse(tab.view.styledScreen()); if bars != b { bars = b }
                let p = ScreenPrompt.parse(tab.view.plainScreen()); if prompt != p { prompt = p }
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
                        ForEach(items) { item($0).id($0.id) }
                        if let p = prompt, liveAskId == nil { promptCard(p).id("prompt") } // a live question is its own card
                        if tab.working { workingRow }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear { // lazy rows at the bottom anchor aren't realized until a scroll: nudge once laid out
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: prompt) {
                    guard prompt != nil, currentHit == nil else { return }
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: items.last?.id) { // next runloop: the new row is laid out by then
                    guard currentHit == nil else { return }
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: currentHit) {
                    guard let id = currentHit else { return }
                    reveal(id) // open its run / input first, then scroll once it's laid out
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            let model = msgs.last { $0.model != nil }?.model
            if !bars.isEmpty || model != nil {
                HStack(spacing: 20) {
                    if let model { modelMenu(model) }
                    ForEach(bars) { usage($0) }
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            // its own view: a keystroke re-renders the field, not every message above it
            Composer(font: mono(12), codex: codex, cwd: cwd, accent: accent, dropped: $dropped) { text in
                tab.view.typeLine(text)
                // shown at once; the transcript's copy (user record or queue entry) replaces it
                echoes.append((text.trimmingCharacters(in: .whitespacesAndNewlines), Date()))
            }
        }
        // files dropped anywhere on the chat land in the composer as shell-quoted paths, like a drop on the terminal
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { dropped += shellQuote(url.path) + " " }
                }
            }
            return !providers.isEmpty
        }
    }

    /// What's in progress: the newest tool call when it's the transcript's last entry — a
    /// folded run hides it, so the whole command shows here until Claude's next block lands.
    @ViewBuilder
    private var workingRow: some View {
        let live = msgs.last.flatMap { $0.kind == .tool ? $0 : nil }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                PulseDot(color: accent, size: 6)
                Text("working…" + (live.map { " › " + $0.text } ?? "")).font(mono(11)).lineLimit(1).foregroundStyle(theme.muted)
            }
            if let d = live?.detail { Text(d).font(mono(10)).lineLimit(6).foregroundStyle(theme.faint).padding(.leading, 12) }
        }
    }

    @ViewBuilder
    private func row(_ m: ChatMessage) -> some View {
        let cur = m.id == currentHit
        switch m.kind {
        case .user:
            // detail "queued" (waiting for Claude's turn to end) / "sending" (local echo): dimmer, tagged
            VStack(alignment: .trailing, spacing: 2) {
                plain(m.text, cur).font(mono(12)).foregroundStyle(m.detail == nil ? AnyShapeStyle(.primary) : theme.muted)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(accent.opacity(m.detail == nil ? 0.25 : 0.12))
                if let d = m.detail { Text(d).font(mono(9)).foregroundStyle(theme.faint) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            if let qs = m.ask {
                askCard(m, qs, cur)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks(m.text).enumerated()), id: \.offset) { block($0.element, cur) }
                }
            }
        case .tool:
            // minimized: one dim line; click to open the full input, click again to fold it
            let open = expanded.contains(m.id)
            VStack(alignment: .leading, spacing: 2) {
                if m.detail == nil {
                    plain("› " + m.text, cur).font(mono(10)).lineLimit(1)
                } else {
                    Button { toggle(m.id) } label: {
                        plain((open ? "⌄ " : "› ") + m.text, cur).font(mono(10)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if open, let d = m.detail { plain(d, cur).font(mono(10)).padding(.leading, 12) }
            }
            .foregroundStyle(theme.faint)
        }
    }

    // ─── Claude's multiple-choice questions (AskUserQuestion) as a card you answer in chat ───
    // The buttons drive Claude Code's picker with the keys a person would press (checked
    // against 2.1.278): a digit picks an option and moves to the next question, or toggles it
    // in a multi-select, whose Submit row sits one past "Type something"; with more than one
    // question, or any multi-select, a review screen follows where 1 submits. A lone
    // single-select question submits on its digit.

    private var paper: Color { Color(nsColor: theme.nsColor(theme.current.background)) }

    /// Only the newest unanswered question is live — that's the one on the terminal. Codex's
    /// never are: its picker sits behind ⌥↑ and takes other keys, so the card only shows the question.
    private var liveAskId: String? { codex ? nil : msgs.last { $0.ask != nil }.flatMap { $0.answers == nil ? $0.id : nil } }

    @ViewBuilder
    private func askCard(_ m: ChatMessage, _ qs: [AskQuestion], _ cur: Bool) -> some View {
        let live = m.id == liveAskId
        let step = askStep[m.id] ?? 0
        let needsReview = qs.count > 1 || qs.contains(where: \.multiSelect)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(qs.indices, id: \.self) { qi in
                let q = qs[qi]
                let picked = askPicked[m.id]?[qi] ?? []
                let answer = m.answers?[q.question]
                VStack(alignment: .leading, spacing: 5) {
                    Text((q.header ?? "question") + (q.multiSelect ? " · pick any" : "")).font(mono(10)).foregroundStyle(ansi(3))
                    inline(q.question, cur).font(mono(12))
                    ForEach(q.options.indices, id: \.self) { oi in
                        let o = q.options[oi]
                        let chosen = picked.contains(oi)
                            || answer.map { $0.components(separatedBy: ", ").contains(o.label) } == true
                        Button { pick(m, qs, qi, oi) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(oi + 1)")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.label).font(mono(11))
                                    if let d = o.description { Text(d).opacity(0.75) }
                                }
                            }
                            .frame(maxWidth: 520, alignment: .leading)
                        }
                        .buttonStyle(FootButtonStyle(on: chosen, paper: paper, wrap: true))
                        .disabled(!live || qi != step)
                    }
                    if q.multiSelect, live, qi == step {
                        Button(qi == qs.count - 1 ? "done ›" : "next ›") {
                            send(Array(repeating: "\u{1b}[B", count: q.options.count + 1) + ["\r"]) // down to its Submit row
                            askStep[m.id] = step + 1
                        }
                        .buttonStyle(FootButtonStyle(paper: paper))
                    }
                }
                .opacity(live && qi != step && step < qs.count ? 0.55 : 1)
            }
            if live, needsReview, step >= qs.count {
                Button("submit answers") { send(["1"]) }.buttonStyle(FootButtonStyle(on: true, paper: paper))
            }
            Text(m.answers == nil ? (live ? "waiting for your answer" : "not answered")
                 : m.answers!.isEmpty ? "dismissed" : "answered")
                .font(mono(9)).foregroundStyle(theme.faint)
        }
        .padding(10)
        .overlay(Rectangle().stroke(live ? ansi(3) : Color.primary.opacity(0.15), lineWidth: 1))
    }

    /// A permission prompt (or any numbered menu) read off the screen; a digit answers it.
    private func promptCard(_ p: ScreenPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = p.title { Text(t).font(mono(10)).foregroundStyle(ansi(3)) }
            ForEach(p.body.indices, id: \.self) { i in
                Text(p.body[i]).font(mono(i == p.body.count - 1 ? 12 : 11))
                    .foregroundStyle(i == p.body.count - 1 ? Color.primary : ansi(2))
            }
            ForEach(p.options.indices, id: \.self) { i in
                Button {
                    send(["\(i + 1)"])
                    prompt = nil // answered; the next screen read confirms
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)")
                        Text(p.options[i]).font(mono(11))
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                }
                .buttonStyle(FootButtonStyle(paper: paper, wrap: true))
            }
            Text("waiting for your answer").font(mono(9)).foregroundStyle(theme.faint)
        }
        .padding(10)
        .overlay(Rectangle().stroke(ansi(3), lineWidth: 1))
    }

    private func pick(_ m: ChatMessage, _ qs: [AskQuestion], _ qi: Int, _ oi: Int) {
        send(["\(oi + 1)"])
        var picked = askPicked[m.id] ?? [:]
        if qs[qi].multiSelect {
            picked[qi, default: []].formSymmetricDifference([oi])
        } else {
            picked[qi] = [oi]
            askStep[m.id] = qi + 1
        }
        askPicked[m.id] = picked
    }

    /// Keys to the tab ~150 ms apart, like the `key` socket command — menus need the gap.
    private func send(_ seqs: [String]) {
        let view = tab.view
        for (i, s) in seqs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(i)) { view.send(txt: s) }
        }
    }

    // ─── Tool calls fold away: a run of them is one dim line until clicked ───

    private enum Item: Identifiable {
        case msg(ChatMessage)
        case tools(String, [ChatMessage]) // run of 2+ calls, keyed by its first call's id
        var id: String {
            switch self { case .msg(let m): m.id; case .tools(let id, _): "run-" + id }
        }
    }

    private var items: [Item] {
        var out: [Item] = []
        var run: [ChatMessage] = []
        func flush() {
            guard let first = run.first else { return }
            if run.count > 1 { out.append(.tools(first.id, run)) }
            if run.count == 1 || expanded.contains(first.id) {
                out += run.map(Item.msg)
            }
            run = []
        }
        for m in msgs {
            if m.kind == .tool { run.append(m) } else { flush(); out.append(.msg(m)) }
        }
        flush()
        for (i, e) in echoes.enumerated() {
            out.append(.msg(ChatMessage(id: "echo-\(i)-\(e.sent.timeIntervalSince1970)", kind: .user, text: e.text, detail: "sending")))
        }
        return out
    }

    @ViewBuilder
    private func item(_ i: Item) -> some View {
        switch i {
        case .msg(let m): row(m)
        case .tools(let id, let run):
            let open = expanded.contains(id)
            var counts: [(String, Int)] = []
            let _ = run.forEach { m in
                let name = m.text.components(separatedBy: " · ")[0]
                if let k = counts.firstIndex(where: { $0.0 == name }) { counts[k].1 += 1 } else { counts.append((name, 1)) }
            }
            Button { toggle(id) } label: {
                Text((open ? "⌄ " : "› ") + "\(run.count) tools · "
                     + counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", "))
                    .font(mono(10)).lineLimit(1).foregroundStyle(theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// A find hit on a tool call opens its run (and its input, if that's where the text is) —
    /// once, into `expanded`, so it folds back like anything clicked open.
    private func reveal(_ id: String) {
        guard let i = msgs.firstIndex(where: { $0.id == id }), msgs[i].kind == .tool else { return }
        var start = i
        while start > 0, msgs[start - 1].kind == .tool { start -= 1 }
        var end = i
        while end + 1 < msgs.count, msgs[end + 1].kind == .tool { end += 1 }
        if end > start { expanded.insert(msgs[start].id) }
        if msgs[i].detail?.localizedCaseInsensitiveContains(query) == true { expanded.insert(id) }
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

    /// Block parse per message text: two Swift Regex matches per line, which is slow enough that
    /// re-parsing every visible reply on each poll tick and scroll hung long threads.
    private func blocks(_ text: String) -> [ChatBlock] {
        if let b = inlineCache.blocks[text] { return b }
        let b = ChatMarkdown.blocks(text)
        inlineCache.blocks[text] = b
        return b
    }

    /// Inline markdown (bold, `code`, links) with code and links recolored, find hits marked.
    private func inline(_ s: String, _ cur: Bool) -> Text {
        let key = (cwd ?? "") + "\u{0}" + s
        if let hit = inlineCache.made[key] { return Text(mark(hit, cur)) }
        var a = (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        linkify(&a)
        for run in a.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                a[run.range].foregroundColor = ansi(2)
                a[run.range].backgroundColor = Color.primary.opacity(0.06)
            } else if run.link != nil {
                a[run.range].foregroundColor = ansi(5)
            }
            if run.link != nil { a[run.range].underlineStyle = .single }
        }
        inlineCache.made[key] = a
        return Text(mark(a, cur))
    }

    /// Bare URLs and paths that exist on disk become links, found the way the terminal finds
    /// them (KnifeTermView.fileLink); a file.swift:12 line reference rides in the fragment.
    // ponytail: a stat per slash-bearing token on every render; cache per message if long chats stutter.
    private func linkify(_ a: inout AttributedString) {
        let text = String(a.characters)
        let all = NSRange(location: 0, length: (text as NSString).length)
        func link(_ r: NSRange, _ url: URL) {
            guard let sr = Range(r, in: text), let ar = Range<AttributedString.Index>(sr, in: a),
                  a[ar].runs.allSatisfy({ $0.link == nil }) else { return }
            a[ar].link = url
        }
        for m in KnifeTermView.urlDetector?.matches(in: text, range: all) ?? [] {
            if let url = m.url { link(m.range, url) }
        }
        for m in KnifeTermView.tokenRegex.matches(in: text, range: all) {
            guard let (url, lineRef, r) = KnifeTermView.fileLink(token: (text as NSString).substring(with: m.range), at: m.range, cwd: cwd) else { continue }
            link(r, lineRef.flatMap { URL(string: url.absoluteString + "#" + $0) } ?? url)
        }
    }

    /// Links open as they do in the terminal: URLs in the browser, file:line in VS Code, ⌥ reveals in Finder.
    private var openLinks: OpenURLAction {
        OpenURLAction { url in
            guard url.isFileURL else { return .systemAction }
            tab.view.openLink(URL(fileURLWithPath: url.path), lineRef: url.fragment,
                              reveal: NSEvent.modifierFlags.contains(.option))
            return .handled
        }
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
                .font(mono(10)).foregroundStyle(theme.muted)
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

    /// Click the model · effort to change either, staying in chat: Claude Code takes
    /// `/model <alias>` and `/effort <level>` typed into the tab (which agent it is comes from
    /// the transcript, not the model name). Codex's /model is an interactive picker with no
    /// arguments, so that one opens in the terminal. The label catches up on the next reply.
    private func modelMenu(_ label: String) -> some View {
        // label is "<model> · <effort>"; ✓ marks what's in use
        let parts = label.components(separatedBy: " · ")
        let (model, effort) = (parts[0], parts.count > 1 ? parts[1] : "")
        let aliases = ["fable", "opus", "sonnet", "haiku"]
        return Menu {
            if !codex {
                Section("model") {
                    if !aliases.contains(where: model.contains) {
                        Button("✓ " + model) {}.disabled(true) // not an alias: shown, can't be re-picked by name
                    }
                    ForEach(aliases, id: \.self) { m in
                        Button((model.contains(m) ? "✓ " : "   ") + m) { tab.view.typeLine("/model " + m) }
                    }
                }
                Section("effort") {
                    ForEach(["low", "medium", "high", "xhigh", "max", "auto"], id: \.self) { e in
                        Button((effort == e ? "✓ " : "   ") + e) { tab.view.typeLine("/effort " + e) }
                    }
                }
            } else {
                Button("model + effort picker (terminal)") {
                    tab.view.typeLine("/model")
                    UserDefaults.standard.set(false, forKey: "chatView")
                }
            }
        } label: {
            Text(label + " ▾").font(mono(10)).foregroundStyle(ansi(5))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("change model or effort")
    }

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

private struct Composer: View {
    let font: Font
    let codex: Bool
    let cwd: String?
    let accent: Color
    @Binding var dropped: String // set by the pane's drop handler; taken into the draft here
    let send: (String) -> Void
    @State private var draft = ""
    @State private var pick = 0 // highlighted row of the slash menu

    /// Slash commands the CLI will take: its built-ins, plus skills + custom commands on disk
    /// (~/.claude/commands/*.md, ~/.claude/skills/*/, and the project's .claude/ copies).
    /// ponytail: the built-in list is static — a new CLI release means editing it here.
    private var commands: [String] {
        if codex {
            return ["approvals", "clear", "compact", "diff", "init", "logout", "mcp", "mention", "model", "new", "quit", "review", "status"]
        }
        var out: Set<String> = ["add-dir", "agents", "bug", "clear", "compact", "config", "context", "cost", "doctor", "effort", "exit",
            "export", "fast", "feedback", "help", "hooks", "ide", "init", "keybindings", "login", "logout", "mcp", "memory", "model",
            "permissions", "plugin", "pr-comments", "release-notes", "rename", "resume", "review", "rewind", "sandbox", "security-review",
            "skills", "stats", "status", "statusline", "tasks", "terminal-setup", "theme", "usage", "vim", "workflows"]
        let fm = FileManager.default
        for root in [NSHomeDirectory() + "/.claude", cwd.map { $0 + "/.claude" }].compactMap({ $0 }) {
            for f in (try? fm.contentsOfDirectory(atPath: root + "/commands")) ?? [] where f.hasSuffix(".md") { out.insert(String(f.dropLast(3))) }
            for d in (try? fm.contentsOfDirectory(atPath: root + "/skills")) ?? [] where fm.fileExists(atPath: root + "/skills/\(d)/SKILL.md") { out.insert(d) }
        }
        return out.sorted()
    }

    /// The draft is a bare slash token being typed: "/" or "/cle" — nothing after it yet.
    private var typingCommand: String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }
    private var matches: [String] {
        guard let t = typingCommand else { return [] }
        let all = commands
        return t.isEmpty ? all : all.filter { $0.hasPrefix(t) } + all.filter { !$0.hasPrefix(t) && $0.contains(t) }
    }
    /// The first word is a known command → the whole field takes the accent color.
    private var isCommand: Bool {
        guard draft.hasPrefix("/") else { return false }
        return commands.contains(String(draft.dropFirst().prefix { !$0.isWhitespace }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.prefix(8).enumerated()), id: \.element) { i, c in
                        Text("/" + c).font(font).foregroundStyle(i == pick ? accent : Color.primary)
                            .padding(.horizontal, 16).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(i == pick ? Color.primary.opacity(0.07) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { complete(c) }
                    }
                }
                .padding(.vertical, 4)
                .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1) }
            }
            TextField("message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(font).lineLimit(1...6)
                .foregroundStyle(isCommand ? accent : Color.primary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .onChange(of: draft) { pick = 0 }
                .onKeyPress(.upArrow) { guard !matches.isEmpty else { return .ignored }; pick = max(0, pick - 1); return .handled }
                .onKeyPress(.downArrow) { guard !matches.isEmpty else { return .ignored }; pick = min(matches.prefix(8).count - 1, pick + 1); return .handled }
                .onKeyPress(.tab) { guard !matches.isEmpty else { return .ignored }; complete(matches[pick]); return .handled }
                .onKeyPress(.escape) { guard !matches.isEmpty else { return .ignored }; draft = ""; return .handled }
                .onChange(of: dropped) {
                    guard !dropped.isEmpty else { return }
                    if !draft.isEmpty, !draft.hasSuffix(" ") { draft += " " }
                    draft += dropped; dropped = ""
                }
                .onSubmit {
                    guard !draft.isEmpty else { return }
                    // ⏎ on a partial command completes the highlighted row; ⏎ again sends it
                    if let t = typingCommand, !matches.isEmpty, matches[pick] != t { complete(matches[pick]); return }
                    send(draft)
                    draft = ""
                }
        }
    }

    private func complete(_ c: String) { draft = "/" + c + " "; pick = 0 }
}
