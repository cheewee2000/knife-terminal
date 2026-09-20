import SwiftUI
import UIKit
import KnifeKit

private func mono(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "Space Mono Bold" : "Space Mono", size: size)
}

struct SessionDetailView: View {
    let tabRecordName: String
    @EnvironmentObject var store: MirrorStore
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var showTerminal = false
    @State private var showUsage = false
    @FocusState private var composing: Bool

    private var tab: MirroredTab? { store.tabs.first { $0.id == tabRecordName } }
    private var messages: [ChatMessage] { tab.flatMap { ChatTranscript.decode($0.chat) } ?? [] }
    /// Sent from the chat composer, not yet back from the Mac: shown greyed at once. Dropped
    /// once the mirrored transcript carries the text (or after 30s — e.g. a prompt answer).
    @State private var echoes: [(text: String, sent: Date)] = []
    private var shown: [ChatMessage] {
        let msgs = messages
        let recent = msgs.suffix(8).filter { $0.kind == .user }.map(\.text)
        let pending = echoes.filter { $0.sent.timeIntervalSinceNow > -30 && !recent.contains($0.text) }
        return msgs + pending.enumerated().map { i, e in
            ChatMessage(id: "echo-\(i)-\(e.sent.timeIntervalSince1970)", kind: .user, text: e.text, detail: "sending")
        }
    }

    var body: some View {
        Group {
            if let tab {
                if showTerminal || messages.isEmpty {
                    terminalView(tab)
                } else {
                    chatView(tab)
                }
            } else {
                Text("session closed on the Mac").font(mono(12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(tab.map { "\($0.emoji) \($0.title)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let tab { store.markSeen(tab) }
            if DemoData.enabled {
                if DemoData.showTerminal { showTerminal = true }
                if DemoData.showUsage { showUsage = true }
            }
        }
        .onChange(of: tab?.attention ?? false) { _, waiting in
            if waiting, let tab { store.markSeen(tab) } // arrived while already viewing
        }
        .toolbar {
            if let tab {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        if tab.working {
                            Circle().fill(knifeAccent).frame(width: 7, height: 7)
                        } else if tab.attention {
                            Circle().fill(knifeOrange).frame(width: 7, height: 7)
                        }
                        if !messages.isEmpty {
                            Button { showTerminal.toggle() } label: {
                                Image(systemName: showTerminal ? "text.bubble" : "apple.terminal")
                                    .font(.system(size: 13))
                            }
                        }
                        Button { showUsage = true } label: {
                            Image(systemName: "gauge.with.needle").font(.system(size: 13))
                        }
                        Button { Task { await store.refresh() } } label: { Text("sync").font(mono(11)) }
                    }
                }
            }
        }
        .sheet(isPresented: $showUsage) { usageSheet }
    }

    // ─── Usage limits (parsed out of the mirrored statusline bars) ───

    private var usageBars: [UsageBar] {
        tab.map { UsageBar.parse($0.styled) } ?? []
    }

    private var usageSheet: some View {
        let bars = usageBars
        return VStack(alignment: .leading, spacing: 18) {
            Text("usage").font(mono(13, bold: true))
            if bars.isEmpty {
                Text("no usage bars on screen right now")
                    .font(mono(11)).foregroundStyle(.secondary)
            } else {
                ForEach(bars) { bar in usageRow(bar) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .presentationDetents([.height(CGFloat(90 + max(1, bars.count) * 58))])
        .presentationDragIndicator(.visible)
    }

    private func usageRow(_ bar: UsageBar) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bar.title).font(mono(11))
                Spacer()
                if let reset = bar.reset {
                    Text("resets in \(reset)").font(mono(10)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Capsule().fill(Color.primary.opacity(0.08))
                    .frame(height: 8)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule()
                                .fill(bar.pct >= 90 ? knifeOrange : knifeAccent)
                                .frame(width: max(8, g.size.width * CGFloat(bar.pct) / 100))
                        }
                    }
                Text("\(bar.pct)%").font(mono(11, bold: true))
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    // ─── Chat rendering of the Claude session (transcript from the Mac) ───

    private func chatView(_ tab: MirroredTab) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(shown) { m in messageRow(m) }
                        if let p = screenPrompt(tab) { promptCard(p, tab) }
                        if tab.working { workingRow }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: shown.last?.id ?? "") { // next runloop: the new row is laid out by then
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    }
                }
                .onChange(of: composing) { _, focused in
                    if focused { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
            }
            composer(tab)
        }
    }

    @ViewBuilder
    private func messageRow(_ m: ChatMessage) -> some View {
        switch m.kind {
        case .user:
            // detail "sending" (local echo) / "queued" (waiting on Claude's turn): greyed, tagged
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(m.text)
                        .font(mono(13))
                        .foregroundStyle(m.detail == nil ? .primary : .secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 16).fill(knifeAccent.opacity(m.detail == nil ? 0.22 : 0.1)))
                        .textSelection(.enabled)
                    if let d = m.detail { Text(d).font(mono(9)).foregroundStyle(.tertiary) }
                }
            }
        case .assistant:
            Text(markdown(m.text))
                .font(mono(13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .tool:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    Text(m.text).font(mono(11)).lineLimit(1)
                }
                if let d = m.detail { Text(d).font(mono(10)).padding(.leading, 15) }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// A numbered menu on the mirrored screen — a permission prompt, or a question's picker —
    /// answered from chat: a digit picks (Claude Code 2.1.278).
    private func screenPrompt(_ tab: MirroredTab) -> ScreenPrompt? {
        guard let screen = StyledScreen.decode(tab.styled) else { return nil }
        return ScreenPrompt.parse(screen.lines.map { $0.map(\.t).joined() }.joined(separator: "\n"))
    }

    private func promptCard(_ p: ScreenPrompt, _ tab: MirroredTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = p.title { Text(t).font(mono(11, bold: true)).foregroundStyle(knifeOrange) }
            ForEach(p.body, id: \.self) { Text($0).font(mono(12)) }
            ForEach(p.options.indices, id: \.self) { i in
                Button { store.send("\(i + 1)", to: tab.tabId) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(mono(12, bold: true))
                        Text(p.options[i]).font(mono(12)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(knifeAccent.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(knifeOrange, lineWidth: 1))
    }

    private var workingRow: some View {
        HStack(spacing: 8) {
            Circle().fill(knifeAccent).frame(width: 7, height: 7)
            Text("working…").font(mono(11)).foregroundStyle(.secondary)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func composer(_ tab: MirroredTab) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(mono(13))
                .lineLimit(1...5)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($composing)
                .onSubmit { submit(tab) }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.15), lineWidth: 1))
            Button { submit(tab) } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(draft.isEmpty ? Color.secondary.opacity(0.5) : knifeAccent)
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    // ─── Raw terminal mirror (fallback, and one tap away for TUI moments) ───

    private func terminalView(_ tab: MirroredTab) -> some View {
        // The mirror ignores the keyboard: opening it covers the mirrored
        // terminal's own footer (input box + progress bars) instead of
        // squeezing the view; the bar floats above the keyboard.
        ZStack(alignment: .bottom) {
            MirrorTextView(styled: tab.styled, dark: scheme == .dark)
                .ignoresSafeArea(.keyboard)
            terminalInputBar(tab)
        }
    }

    private func terminalInputBar(_ tab: MirroredTab) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            if tab.title.hasPrefix("job:"), tab.attention { // routing wants a pick: one tap
                ForEach(1...3, id: \.self) { n in
                    Button { store.send("\(n)\r", to: tab.tabId) } label: {
                        Text("\(n)").font(mono(13, bold: true)).frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(knifeAccent.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("type here, ⏎ sends", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(mono(13))
                .lineLimit(1...4)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($composing)
                .onSubmit { submit(tab) }
            if composing {
                Button { composing = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 15))
                }
                .buttonStyle(.plain)
            }
            Button { submit(tab) } label: { Text("send").font(mono(11, bold: true)) }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.bar)
    }

    private func submit(_ tab: MirroredTab) {
        store.send(draft + "\r", to: tab.tabId)
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !showTerminal, !t.isEmpty { echoes.removeAll { $0.sent.timeIntervalSinceNow < -30 }; echoes.append((t, Date())) }
        draft = ""
    }
}

// ─── Native mirror of the Mac's screen ───
// The Mac publishes the visible screen as styled runs; the phone renders an
// attributed string — real colors, bold/dim/underline, wrapped to the screen
// width (never side-scrolls), native selection and copy. Long horizontal rules
// and padding are squeezed so the desktop's box drawing fits the phone.

private func uiColor(_ c: TermTheme.RGB, alpha: CGFloat = 1) -> UIColor {
    UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: alpha)
}

struct MirrorTextView: UIViewRepresentable {
    let styled: Data
    let dark: Bool

    func makeUIView(context: Context) -> MirrorTextUIView {
        let tv = MirrorTextUIView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = true
        tv.showsHorizontalScrollIndicator = false
        tv.keyboardDismissMode = .interactive
        // room for the overlaid compose bar so scrolled-to-bottom content clears it
        tv.contentInset.bottom = 52
        tv.verticalScrollIndicatorInsets.bottom = 52
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        tv.linkTextAttributes = [
            .foregroundColor: UIColor(knifeAccent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        return tv
    }

    func updateUIView(_ tv: MirrorTextUIView, context: Context) {
        tv.render(styled: styled, dark: dark)
    }
}

final class MirrorTextUIView: UITextView {
    private var lastStyled = Data()
    private var lastDark: Bool?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            rerender()
        }
    }

    func render(styled: Data, dark: Bool) {
        guard styled != lastStyled || dark != lastDark else { return }
        lastStyled = styled
        lastDark = dark
        rerender()
    }

    private func rerender() {
        let theme: TermTheme = (lastDark ?? false) ? .dark : .light
        backgroundColor = uiColor(theme.background)
        guard bounds.width > 40, let screen = StyledScreen.decode(lastStyled) else { return }

        let size: CGFloat = 12
        let regular = UIFont(name: "Space Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let boldFont = UIFont(name: "Space Mono Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .bold)
        let cellW = ("W" as NSString).size(withAttributes: [.font: regular]).width
        let usable = bounds.width - textContainerInset.left - textContainerInset.right - 2 * textContainer.lineFragmentPadding
        let cols = max(20, Int(usable / cellW))

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byCharWrapping
        let out = NSMutableAttributedString()
        for (i, line) in screen.lines.enumerated() {
            for run in Self.squeeze(line, toCols: cols) {
                let style = run.s ?? 0
                var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: para]
                attrs[.font] = style & StyledScreen.styleBold != 0 ? boldFont : regular
                var fg = run.f.map { theme.rgb(code: $0) } ?? theme.foreground
                var bg = run.g.map { theme.rgb(code: $0) }
                if style & StyledScreen.styleInverse != 0 {
                    (fg, bg) = (bg ?? theme.background, fg)
                }
                attrs[.foregroundColor] = uiColor(fg, alpha: style & StyledScreen.styleDim != 0 ? 0.55 : 1)
                if let bg { attrs[.backgroundColor] = uiColor(bg) }
                if style & StyledScreen.styleUnderline != 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if style & StyledScreen.styleItalic != 0 { attrs[.obliqueness] = 0.2 }
                out.append(NSAttributedString(string: run.t, attributes: attrs))
            }
            if i < screen.lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: regular, .paragraphStyle: para]))
            }
        }

        Self.linkify(out)

        let firstLoad = attributedText.length == 0
        let nearBottom = contentOffset.y >= contentSize.height - bounds.height - 60
        attributedText = out
        if firstLoad || nearBottom {
            layoutIfNeeded()
            let y = max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
            setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

    /// Mark URLs as tappable links (UITextView opens them natively). The screen
    /// arrives as styled runs, so detection has to run on the final string.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func linkify(_ out: NSMutableAttributedString) {
        guard let detector = linkDetector else { return }
        let s = out.string as NSString
        for m in detector.matches(in: out.string, range: NSRange(location: 0, length: s.length)) {
            guard let url = m.url else { continue }
            out.addAttribute(.link, value: url, range: m.range)
        }
    }

    /// Shrink runs of repeated "horizontal" characters (rules, padding) so the
    /// desktop's box drawing fits `cols`; leading indentation is left alone.
    static func squeeze(_ line: [TermRun], toCols cols: Int) -> [TermRun] {
        let squeezable: Set<Character> = ["─", "━", "═", "╌", "┄", "┈", "╍", "┅", "┉", "⎯", "▁", "▔", "-", "=", "_", "·", " "]
        var overflow = line.reduce(0) { $0 + $1.t.count } - cols
        guard overflow > 0 else { return line }
        var out: [TermRun] = []
        var seenInk = false
        for var run in line {
            if overflow <= 0 { out.append(run); continue }
            var newText = ""
            var i = run.t.startIndex
            while i < run.t.endIndex {
                let ch = run.t[i]
                var j = run.t.index(after: i)
                while j < run.t.endIndex, run.t[j] == ch { j = run.t.index(after: j) }
                var len = run.t.distance(from: i, to: j)
                let isIndent = ch == " " && !seenInk
                if ch != " " { seenInk = true }
                if overflow > 0, len > 4, !isIndent, squeezable.contains(ch) {
                    let cut = min(len - 4, overflow)
                    len -= cut
                    overflow -= cut
                }
                newText += String(repeating: ch, count: len)
                i = j
            }
            run.t = newText
            out.append(run)
        }
        return out
    }
}
