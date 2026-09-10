import SwiftUI
import UIKit
import KnifeKit

struct SessionDetailView: View {
    let tabRecordName: String
    @EnvironmentObject var store: MirrorStore
    @Environment(\.colorScheme) private var scheme
    private var theme: TermTheme { .current(scheme) }
    @State private var draft = ""
    @State private var showTerminal = false
    @State private var showUsage = false
    @State private var expandedTools: Set<String> = []
    /// Mirror text size; 0 means "fit the Mac's real width", which is what makes
    /// landscape show the desktop layout instead of rewrapping it.
    @AppStorage("knife.mirrorSize") private var mirrorSize: Double = 12
    @FocusState private var composing: Bool

    private var tab: MirroredTab? { store.tabs.first { $0.id == tabRecordName } }
    private var messages: [ChatMessage] { tab.flatMap { ChatTranscript.decode($0.chat) } ?? [] }

    var body: some View {
        Group {
            if let tab {
                if showTerminal || messages.isEmpty {
                    terminalView(tab)
                } else {
                    chatView(tab)
                }
            } else {
                Text("session closed on the Mac").font(ui(14)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(tab.map { "\($0.emoji) \($0.title)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background.color, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("\(tab.emoji) \(tab.title)").font(ui(14, bold: true))
                            .lineLimit(1).truncationMode(.middle)
                        if let folder = tab.cwd.map({ ($0 as NSString).lastPathComponent }), !folder.isEmpty {
                            Text(folder).font(ui(10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        if tab.working {
                            Circle().fill(theme.accent.color).frame(width: 7, height: 7)
                        } else if tab.attention {
                            Circle().fill(theme.attention.color).frame(width: 7, height: 7)
                        }
                        if !messages.isEmpty {
                            Button { showTerminal.toggle() } label: {
                                Image(systemName: showTerminal ? "text.bubble" : "apple.terminal")
                                    .font(.system(size: 13))
                            }
                        }
                        if showTerminal || messages.isEmpty {
                            Menu {
                                Picker("text size", selection: $mirrorSize) {
                                    Text("small").tag(10.0)
                                    Text("medium").tag(12.0)
                                    Text("large").tag(14.0)
                                    Text("fit Mac width").tag(0.0)
                                }
                            } label: {
                                Image(systemName: "textformat.size").font(.system(size: 13))
                            }
                        }
                        Button { showUsage = true } label: {
                            Image(systemName: "gauge.with.needle").font(.system(size: 13))
                        }
                        Button { Task { await store.refresh() } } label: { Text("sync").font(ui(13)) }
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
            Text("usage").font(ui(15, bold: true))
            if bars.isEmpty {
                Text("no usage bars on screen right now")
                    .font(ui(13)).foregroundStyle(.secondary)
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
                Text(bar.title).font(ui(13))
                Spacer()
                if let reset = bar.reset {
                    Text("resets in \(reset)").font(ui(12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Capsule().fill(Color.primary.opacity(0.08))
                    .frame(height: 8)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule()
                                .fill(bar.pct >= 90 ? theme.attention.color : theme.accent.color)
                                .frame(width: max(8, g.size.width * CGFloat(bar.pct) / 100))
                        }
                    }
                Text("\(bar.pct)%").font(ui(13, bold: true))
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
                        ForEach(messages) { m in messageRow(m) }
                        if tab.working { workingRow }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
                .background(theme.background.color)
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id ?? "") {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
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
            HStack {
                Spacer(minLength: 48)
                Text(m.text)
                    .font(ui(15))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(theme.accent.color.opacity(0.22)))
                    .textSelection(.enabled)
            }
        case .assistant:
            Text(markdown(m.text))
                .font(ui(15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .tool:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).padding(.top, 3)
                Text(m.text).font(mono(12))
                    .lineLimit(expandedTools.contains(m.id) ? nil : 1)  // tap for the rest
                    .textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if expandedTools.contains(m.id) { expandedTools.remove(m.id) } else { expandedTools.insert(m.id) }
            }
        }
    }

    private var workingRow: some View {
        HStack(spacing: 8) {
            Circle().fill(theme.accent.color).frame(width: 7, height: 7)
            Text("working…").font(ui(13)).foregroundStyle(.secondary)
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
                .font(ui(15))
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
                    .foregroundStyle(draft.isEmpty ? Color.secondary.opacity(0.5) : theme.accent.color)
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
            MirrorTextView(styled: tab.styled, dark: scheme == .dark,
                           size: CGFloat(mirrorSize), macCols: tab.cols)
                .ignoresSafeArea(.keyboard)
            terminalInputBar(tab)
        }
    }

    private func terminalInputBar(_ tab: MirroredTab) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("type here, ⏎ sends", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(mono(14))
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
            Button { submit(tab) } label: { Text("send").font(ui(13, bold: true)) }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.bar)
    }

    private func submit(_ tab: MirroredTab) {
        store.send(draft + "\r", to: tab.tabId)
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

// The Mac's statusline draws usage-limit bars like "5h ████░░░░░░ 42% (2h30m)"
// in the terminal footer. They ride along in the mirrored screen, so the phone
// can lift them back out and render native progress bars.
struct UsageBar: Identifiable {
    let label: String
    let pct: Int
    let reset: String?
    var id: String { label }

    var title: String {
        switch label {
        case "5h": return "session · 5 hour window"
        case "wk": return "week · all models"
        default: return "week · \(label)"
        }
    }

    static func parse(_ styled: Data) -> [UsageBar] {
        guard let screen = StyledScreen.decode(styled) else { return [] }
        let pattern = /(\S+) ([█░]{10}) (\d{1,3})%(?: \(([^)]+)\))?/
        var byLabel: [String: UsageBar] = [:]
        var order: [String] = []
        for line in screen.lines {
            let text = line.map(\.t).joined()
            for m in text.matches(of: pattern) {
                let label = String(m.1)
                let bar = UsageBar(label: label, pct: min(100, Int(m.3) ?? 0),
                                   reset: m.4.map(String.init))
                if byLabel[label] == nil { order.append(label) }
                byLabel[label] = bar
            }
        }
        return order.compactMap { byLabel[$0] }
    }
}

struct MirrorTextView: UIViewRepresentable {
    let styled: Data
    let dark: Bool
    let size: CGFloat      // 0 = fit the Mac's column count
    let macCols: Int

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
        return tv
    }

    func updateUIView(_ tv: MirrorTextUIView, context: Context) {
        tv.linkTextAttributes = [
            .foregroundColor: (dark ? TermTheme.dark : TermTheme.light).accent.uiColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.render(styled: styled, dark: dark, size: size, macCols: macCols)
    }
}

final class MirrorTextUIView: UITextView {
    private var lastStyled = Data()
    private var lastDark: Bool?
    private var lastWidth: CGFloat = 0
    private var lastSize: CGFloat = 12
    private var lastMacCols = 80

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            rerender()
        }
    }

    func render(styled: Data, dark: Bool, size: CGFloat, macCols: Int) {
        guard styled != lastStyled || dark != lastDark || size != lastSize || macCols != lastMacCols else { return }
        lastStyled = styled
        lastDark = dark
        lastSize = size
        lastMacCols = macCols
        rerender()
    }

    private func rerender() {
        let theme: TermTheme = (lastDark ?? false) ? .dark : .light
        backgroundColor = uiColor(theme.background)
        guard bounds.width > 40, let screen = StyledScreen.decode(lastStyled) else { return }

        let usable = bounds.width - textContainerInset.left - textContainerInset.right - 2 * textContainer.lineFragmentPadding
        // "fit Mac width" solves for the size that makes the Mac's own columns
        // land inside the screen — nothing rewraps, which is what landscape wants.
        var size = lastSize
        if size <= 0 {
            let probe = Self.font(size: 12, bold: false)
            let cellAt12 = ("W" as NSString).size(withAttributes: [.font: probe]).width
            size = max(5, min(14, (usable / CGFloat(max(20, lastMacCols))) / (cellAt12 / 12)))
        }
        let regular = Self.font(size: size, bold: false)
        let boldFont = Self.font(size: size, bold: true)
        let cellW = ("W" as NSString).size(withAttributes: [.font: regular]).width
        let cols = max(20, Int(usable / cellW))

        // Prose wraps on words; box drawing and rules wrap on characters, so the
        // desktop's frames keep their shape instead of being re-flowed as words.
        let prose = NSMutableParagraphStyle(); prose.lineBreakMode = .byWordWrapping
        let boxes = NSMutableParagraphStyle(); boxes.lineBreakMode = .byCharWrapping
        let out = NSMutableAttributedString()
        for (i, line) in screen.lines.enumerated() {
            let para = Self.isBoxDrawing(line) ? boxes : prose
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
                out.append(NSAttributedString(string: "\n", attributes: [.font: regular, .paragraphStyle: prose]))
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

    static func font(size: CGFloat, bold: Bool) -> UIFont {
        UIFont(name: bold ? "JetBrains Mono Bold" : "JetBrains Mono", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// A line carrying box-drawing or block characters is a frame, not a sentence.
    static func isBoxDrawing(_ line: [TermRun]) -> Bool {
        line.contains { run in
            run.t.unicodeScalars.contains { (0x2500...0x259F).contains(Int($0.value)) }
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
