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

    private var tab: MirroredTab? { store.tabs.first { $0.id == tabRecordName } }

    var body: some View {
        VStack(spacing: 0) {
            if let tab {
                MirrorTextView(styled: tab.styled, dark: scheme == .dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                quickKeys(tab)
                inputBar(tab)
            } else {
                Text("session closed on the Mac").font(mono(12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(tab.map { "\($0.emoji) \($0.title)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let tab {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        if tab.working {
                            Circle().fill(knifeAccent).frame(width: 7, height: 7)
                        } else if tab.attention {
                            Circle().fill(knifeOrange).frame(width: 7, height: 7)
                        }
                        Button { Task { await store.refresh() } } label: { Text("sync").font(mono(11)) }
                    }
                }
            }
        }
    }

    private func quickKeys(_ tab: MirroredTab) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key("esc", "\u{1b}", tab)
                key("tab", "\t", tab)
                key("^C", "\u{03}", tab)
                key("↑", "\u{1b}[A", tab)
                key("↓", "\u{1b}[B", tab)
                key("←", "\u{1b}[D", tab)
                key("→", "\u{1b}[C", tab)
                key("⏎", "\r", tab)
                key("y⏎", "y\r", tab)
                key("1", "1", tab)
                key("2", "2", tab)
                key("3", "3", tab)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func key(_ label: String, _ seq: String, _ tab: MirroredTab) -> some View {
        Button { store.send(seq, to: tab.tabId) } label: {
            Text(label).font(mono(12))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.primary.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // Composing happens here, in a real native text field — cursor placement,
    // selection, autocomplete-free editing — then one tap sends the whole line.
    private func inputBar(_ tab: MirroredTab) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("type here, ⏎ sends", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(mono(13))
                .lineLimit(1...4)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { submit(tab) }
            Button { submit(tab) } label: { Text("send").font(mono(11, bold: true)) }
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

struct MirrorTextView: UIViewRepresentable {
    let styled: Data
    let dark: Bool

    func makeUIView(context: Context) -> MirrorTextUIView {
        let tv = MirrorTextUIView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = true
        tv.showsHorizontalScrollIndicator = false
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
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

        let firstLoad = attributedText.length == 0
        let nearBottom = contentOffset.y >= contentSize.height - bounds.height - 60
        attributedText = out
        if firstLoad || nearBottom {
            layoutIfNeeded()
            let y = max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
            setContentOffset(CGPoint(x: 0, y: y), animated: false)
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
