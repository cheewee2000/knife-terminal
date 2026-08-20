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
                TerminalMirrorView(screen: tab.screen, cols: tab.cols, rows: tab.rows, dark: scheme == .dark) { bytes in
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
// The terminal is locked to the Mac's exact cols×rows grid (anything else garbles
// TUI redraws that assume the Mac's geometry) at a readable font size; when the
// grid is bigger than the phone screen, the outer scroll view pans.

struct TerminalMirrorView: UIViewRepresentable {
    let screen: Data
    let cols: Int
    let rows: Int
    let dark: Bool
    let sendBytes: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(send: sendBytes) }

    func makeUIView(context: Context) -> MirrorScrollView {
        let v = MirrorScrollView()
        v.terminal.terminalDelegate = context.coordinator
        return v
    }

    func updateUIView(_ v: MirrorScrollView, context: Context) {
        v.apply(screen: screen, cols: max(20, cols), rows: max(5, rows), dark: dark)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private var pending = ""
        private var flushTask: Task<Void, Never>?
        private let send: (String) -> Void

        init(send: @escaping (String) -> Void) { self.send = send }

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

final class MirrorScrollView: UIScrollView {
    let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
    private var gridCols = 0
    private var gridRows = 0
    private var appliedFontSize: CGFloat = 0
    private var appliedDark: Bool?
    private var screenData = Data()
    private var fedBytes = Data()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // the outer scroll view owns all panning; SwiftTerm's own (vertical
        // scrollback) scrolling would swallow the gesture
        terminal.allowMouseReporting = false
        terminal.isScrollEnabled = false
        addSubview(terminal)
        contentInsetAdjustmentBehavior = .never
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(screen: Data, cols: Int, rows: Int, dark: Bool) {
        if dark != appliedDark { appliedDark = dark; applyTheme(dark) }
        if cols != gridCols || rows != gridRows {
            gridCols = cols
            gridRows = rows
            setNeedsLayout()
            layoutIfNeeded() // size the grid before feeding so wrapping matches the Mac
        }
        screenData = screen
        feedCurrent()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        relayoutGrid()
    }

    private func mirrorFont(_ size: CGFloat) -> UIFont {
        UIFont(name: "Space Mono", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func relayoutGrid() {
        guard gridCols > 0, bounds.width > 40 else { return }
        // largest font 9–13pt that fits the Mac's columns; below 9 the grid pans
        let em = ("W" as NSString).size(withAttributes: [.font: mirrorFont(13)]).width / 13
        var size = bounds.width / (CGFloat(gridCols) * em)
        size = (size * 2).rounded(.down) / 2
        size = max(9, min(13, size))
        let f = mirrorFont(size)
        // cell metrics exactly as SwiftTerm computes them, so width/cellW == gridCols
        let scale = max(UIScreen.main.scale, 1)
        let cellW = (("W" as NSString).size(withAttributes: [.font: f]).width * scale).rounded() / scale
        let ct = f as CTFont
        let cellH = ceil(ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) * scale) / scale
        let w = CGFloat(gridCols) * cellW + 0.5
        let h = CGFloat(gridRows) * cellH + 0.5
        var changed = false
        if appliedFontSize != size { appliedFontSize = size; terminal.font = f; changed = true }
        if terminal.frame.size != CGSize(width: w, height: h) {
            terminal.frame = CGRect(x: 0, y: 0, width: w, height: h)
            changed = true
        }
        contentSize = CGSize(width: w, height: h)
        if changed {
            fedBytes = Data() // grid changed: replay everything at the new geometry
            feedCurrent()
        }
    }

    private func feedCurrent() {
        guard gridCols > 0, !screenData.isEmpty, screenData != fedBytes else { return }
        let wasAtBottom = contentOffset.y >= contentSize.height - bounds.height - 40
        if !fedBytes.isEmpty, screenData.starts(with: fedBytes) {
            terminal.feed(byteArray: [UInt8](screenData.dropFirst(fedBytes.count))[...])
        } else {
            terminal.feed(byteArray: [UInt8]("\u{1b}c".utf8)[...]) // RIS: full reset
            terminal.feed(byteArray: [UInt8](screenData)[...])
        }
        let first = fedBytes.isEmpty
        fedBytes = screenData
        if first || wasAtBottom {
            contentOffset = CGPoint(x: contentOffset.x,
                                    y: max(0, contentSize.height - bounds.height))
        }
    }

    private func applyTheme(_ dark: Bool) {
        let t: TermTheme = dark ? .dark : .light
        terminal.installColors(t.ansi.map { SwiftTerm.Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
        terminal.nativeBackgroundColor = uiColor(t.background)
        terminal.nativeForegroundColor = uiColor(t.foreground)
        terminal.backgroundColor = uiColor(t.background)
        backgroundColor = uiColor(t.background)
    }

    private func uiColor(_ c: TermTheme.RGB) -> UIColor {
        UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}
