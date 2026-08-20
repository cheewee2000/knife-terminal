import SwiftUI
import SwiftTerm
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
                TerminalMirrorView(screen: tab.screen, cols: tab.cols, dark: scheme == .dark) { bytes in
                    store.send(bytes, to: tab.tabId)
                }
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

    private func inputBar(_ tab: MirroredTab) -> some View {
        HStack(spacing: 8) {
            TextField("type here, ⏎ sends", text: $draft)
                .textFieldStyle(.plain)
                .font(mono(13))
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

// ─── SwiftTerm-rendered mirror of the Mac's screen ───

struct TerminalMirrorView: UIViewRepresentable {
    let screen: Data
    let cols: Int
    let dark: Bool
    let sendBytes: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(send: sendBytes) }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        tv.terminalDelegate = context.coordinator
        tv.allowMouseReporting = false
        context.coordinator.applyTheme(tv, dark: dark)
        return tv
    }

    func updateUIView(_ tv: TerminalView, context: Context) {
        let co = context.coordinator
        if co.dark != dark { co.dark = dark; co.applyTheme(tv, dark: dark) }
        co.fitFont(tv, cols: max(20, cols))
        guard screen != co.lastFed else { return }
        if !co.lastFed.isEmpty, screen.starts(with: co.lastFed) {
            let delta = screen.dropFirst(co.lastFed.count)
            tv.feed(byteArray: [UInt8](delta)[...])
        } else {
            tv.feed(byteArray: [UInt8]("\u{1b}c".utf8)[...]) // RIS: full reset
            tv.feed(byteArray: [UInt8](screen)[...])
        }
        co.lastFed = screen
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var lastFed = Data()
        var dark = false
        private var pending = ""
        private var flushTask: Task<Void, Never>?
        private let send: (String) -> Void

        init(send: @escaping (String) -> Void) { self.send = send }

        func applyTheme(_ tv: TerminalView, dark: Bool) {
            let t: TermTheme = dark ? .dark : .light
            tv.installColors(t.ansi.map { SwiftTerm.Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
            tv.nativeBackgroundColor = uiColor(t.background)
            tv.nativeForegroundColor = uiColor(t.foreground)
            tv.backgroundColor = uiColor(t.background)
        }

        private func uiColor(_ c: TermTheme.RGB) -> UIColor {
            UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
        }

        private var lastCols = 0
        func fitFont(_ tv: TerminalView, cols: Int) {
            guard cols != lastCols, tv.bounds.width > 40 else { return }
            lastCols = cols
            let probe = UIFont(name: "Space Mono", size: 100) ?? UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)
            let cell = ("W" as NSString).size(withAttributes: [.font: probe]).width / 100 // em width per point
            let size = max(4, min(14, tv.bounds.width / (CGFloat(cols) * cell)))
            tv.font = UIFont(name: "Space Mono", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        // keyboard input on the phone → coalesce → CloudKit Input record
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let s = String(bytes: data, encoding: .utf8) else { return }
            pending += s
            flushTask?.cancel()
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, let self, !self.pending.isEmpty else { return }
                self.send(self.pending)
                self.pending = ""
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
