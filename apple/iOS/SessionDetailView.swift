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
                MirrorTextView(text: tab.text, dark: scheme == .dark)
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

// ─── Native mirror of the Mac's screen text ───
// The Mac publishes the rendered terminal text; the phone shows it in a plain
// UITextView — wraps to the screen width (never side-scrolls), native selection
// and copy, follows the bottom unless you've scrolled up to read.

struct MirrorTextView: UIViewRepresentable {
    let text: String
    let dark: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = true
        tv.showsHorizontalScrollIndicator = false
        tv.textContainer.lineBreakMode = .byCharWrapping
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        tv.font = UIFont(name: "Space Mono", size: 12) ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let t: TermTheme = dark ? .dark : .light
        tv.backgroundColor = uiColor(t.background)
        tv.textColor = uiColor(t.foreground)
        guard tv.text != text else { return }
        let firstLoad = (tv.text ?? "").isEmpty
        let nearBottom = tv.contentOffset.y >= tv.contentSize.height - tv.bounds.height - 60
        tv.text = text
        if firstLoad || nearBottom {
            tv.layoutIfNeeded()
            let y = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
            tv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

    private func uiColor(_ c: TermTheme.RGB) -> UIColor {
        UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}
