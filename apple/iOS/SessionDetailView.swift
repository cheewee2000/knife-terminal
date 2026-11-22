import SwiftUI
import UIKit
import KnifeKit
import PhotosUI
import Speech

private func mono(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "Space Mono Bold" : "Space Mono", size: size)
}

struct SessionDetailView: View {
    let tabRecordName: String
    @EnvironmentObject var store: MirrorStore
    @Environment(\.colorScheme) private var scheme
    @State private var compose = Compose()
    @State private var showTerminal = false
    @State private var verticalBar = false // the Duo cover screen's trailing bar is there
    @State private var showUsage = false

    private var tab: MirroredTab? { store.tabs.first { $0.id == tabRecordName } }
    private var messages: [ChatMessage] { tab.flatMap { ChatTranscript.decode($0.chat) } ?? [] }
    /// Sent, not yet back from the Mac (seconds, over CloudKit): shown greyed at once.
    private struct Echo { var text: String; var sent = Date(); var after: String?; var stamp: Date }
    @State private var echoes: [Echo] = []
    /// The echoes still waiting. One is dropped once the mirror carries its text — in the
    /// transcript after the message that was last when it was sent ("yes" twice is two messages;
    /// matching any recent one hid the second), or on a screen newer than the one it was sent
    /// from — or after 30s (e.g. a prompt answer, which nothing echoes).
    private func pending(_ tab: MirroredTab, _ msgs: [ChatMessage], terminal: Bool) -> [Echo] {
        let live = echoes.filter { $0.sent.timeIntervalSinceNow > -30 }
        guard !live.isEmpty else { return [] }
        if terminal {
            let screen = StyledScreen.decode(tab.styled)?.lines.map { $0.map(\.t).joined() }.joined(separator: "\n") ?? ""
            return live.filter { tab.updatedAt == $0.stamp || !screen.contains($0.text.prefix { $0 != "\n" }.prefix(16)) }
        }
        return live.filter { e in
            let since = msgs.firstIndex { $0.id == e.after }.map { msgs[($0 + 1)...] } ?? msgs[...]
            return !since.contains { $0.kind == .user && $0.text == e.text }
        }
    }

    @ViewBuilder private func toolbarButtons(_ tab: MirroredTab, hasChat: Bool) -> some View {
        if tab.working {
            PulseDot(color: knifeAccent)
        } else if tab.attention {
            Circle().fill(knifeOrange).frame(width: 7, height: 7)
        }
        if hasChat {
            Button { showTerminal.toggle() } label: {
                Image(systemName: showTerminal ? "text.bubble" : "apple.terminal").font(.system(size: 13))
            }
        }
        Button { showUsage = true } label: {
            Image(systemName: "gauge.with.needle").font(.system(size: 13))
        }
        Button { Task { await store.refresh() } } label: { Text("sync").font(mono(11)) }
    }

    var body: some View {
        let msgs = messages // decoded once per redraw
        return Group {
            if let tab {
                if showTerminal || msgs.isEmpty {
                    terminalView(tab, msgs)
                } else {
                    chatView(tab, msgs)
                }
            } else {
                Text("session closed on the Mac").font(mono(12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(tab.map { "\($0.emoji) \($0.title)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            compose.key = "draft." + tabRecordName
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
                // iPhone Duo cover screen: separate items, so each one moves into the vertical bar
                // down the trailing edge. Elsewhere one tight HStack — separate items sit ~60pt
                // wider in the top bar and truncate the title.
                if verticalBar {
                    ToolbarItemGroup(placement: .topBarTrailing) { toolbarButtons(tab, hasChat: !msgs.isEmpty) }
                        .inVerticalBar()
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 10) { toolbarButtons(tab, hasChat: !msgs.isEmpty) }
                    }
                }
            }
        }
        .background(VerticalBarProbe(present: $verticalBar))
        .sheet(isPresented: $showUsage) { usageSheet }
        // a buzz when Claude is done, another when it stops to ask
        .sensoryFeedback(.success, trigger: tab?.working ?? false) { was, now in was && !now }
        .sensoryFeedback(.warning, trigger: tab?.attention ?? false) { was, now in !was && now }
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

    private func chatView(_ tab: MirroredTab, _ msgs: [ChatMessage]) -> some View {
        let shown = msgs + pending(tab, msgs, terminal: false).map {
            ChatMessage(id: "echo-\($0.sent.timeIntervalSince1970)", kind: .user, text: $0.text, detail: "sending")
        }
        return VStack(spacing: 0) {
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
                .onChange(of: compose.focused) { _, focused in
                    if focused { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
            }
            ComposerBar(tab: tab, chat: true, model: msgs.last { $0.model != nil }?.model, c: compose) { sent($0, tab, msgs) }
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
                Button { store.send("\(i + 1)", to: tab) } label: {
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
            if p.multiSelect {
                Button { store.send(ScreenPrompt.multiSelectSubmit, to: tab) } label: {
                    Text("submit ›").font(mono(12, bold: true))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(knifeAccent, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(knifeOrange, lineWidth: 1))
    }

    private var workingRow: some View {
        HStack(spacing: 8) {
            PulseDot(color: knifeAccent)
            Text("working…").font(mono(11)).foregroundStyle(.secondary)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    // ─── Raw terminal mirror (fallback, and one tap away for TUI moments) ───

    private func terminalView(_ tab: MirroredTab, _ msgs: [ChatMessage]) -> some View {
        // The mirror ignores the keyboard: opening it covers the mirrored
        // terminal's own footer (input box + progress bars) instead of
        // squeezing the view; the bar floats above the keyboard.
        ZStack(alignment: .bottom) {
            MirrorTextView(styled: tab.styled, dark: scheme == .dark)
                .ignoresSafeArea(.keyboard)
            VStack(spacing: 0) {
                // the screen can't show what was just sent until the Mac has typed it and republished
                ForEach(pending(tab, msgs, terminal: true), id: \.sent) { e in
                    HStack(spacing: 8) {
                        Text(e.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("sending")
                    }
                    .font(mono(11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                    .background(.bar)
                }
                // its Submit row has no digit to type
                ComposerBar(tab: tab, chat: false, multiSelect: screenPrompt(tab)?.multiSelect == true,
                            model: msgs.last { $0.model != nil }?.model, c: compose) { sent($0, tab, msgs) }
            }
        }
    }

    private func sent(_ text: String, _ tab: MirroredTab, _ msgs: [ChatMessage]) {
        echoes.removeAll { $0.sent.timeIntervalSinceNow < -30 }
        if !text.isEmpty { echoes.append(Echo(text: text, after: msgs.last?.id, stamp: tab.updatedAt)) }
    }

    /// Downscaled JPEG small enough for one CloudKit record (1 MB cap, base64 inflates 4/3).
    static func jpegBase64(_ data: Data) -> String? {
        guard let img = UIImage(data: data) else { return nil }
        for side in [2048.0, 1536, 1024, 768] {
            let scale = min(1, side / max(img.size.width, img.size.height))
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let small = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpg = small.jpegData(compressionQuality: 0.7), jpg.count < 650_000 { return jpg.base64EncodedString() }
        }
        return nil
    }
}

// ─── Composing ───

/// What is being composed. Its own observable, read only by the bar: a keystroke redraws the
/// bar and not the session view above it, which decoded the transcript and the screen again
/// on every character.
@Observable final class Compose {
    /// Set once the session is known: what was left unsent in it comes back, also after a relaunch.
    var key: String? { didSet { draft = key.flatMap { UserDefaults.standard.string(forKey: $0) } ?? "" } }
    var draft = "" { didSet { if let key { UserDefaults.standard.set(draft.isEmpty ? nil : draft, forKey: key) } } }
    var focused = false
    /// Picked, not yet sent: thumbnails above the input; they go out with the next send.
    var attached: [(id: UUID, thumb: UIImage, b64: String)] = []
}

/// The input bar under a session: the chat composer, or the terminal's one-line bar.
private struct ComposerBar: View {
    let tab: MirroredTab
    let chat: Bool
    var multiSelect = false
    var model: String? = nil   // "<model> · <effort>" of the latest turn
    @Bindable var c: Compose
    let sent: (String) -> Void
    @EnvironmentObject var store: MirrorStore
    @State private var photos: [PhotosPickerItem] = []
    @State private var showLibrary = false
    @State private var showCamera = false
    private var canSend: Bool { !c.draft.isEmpty || !c.attached.isEmpty }
    /// Nothing to send and Claude busy: the send button stops it instead (Esc).
    private var stopping: Bool { !canSend && tab.working && !tab.attention }

    var body: some View {
        VStack(spacing: 0) {
            attachmentStrip
            modelRow
            if chat { composer } else { terminalBar }
        }
    }

    /// The session's model · effort above the input; tap to change either. The Mac types
    /// `/model <alias>` or `/effort <level>` into Claude Code, and the label follows.
    // ponytail: Claude is told from Codex by the model's name — the phone gets no agent flag.
    // Publish one with the tab if a Claude session on an unlisted model needs this menu.
    @ViewBuilder private var modelRow: some View {
        let parts = (model ?? "").components(separatedBy: " · ")
        if let model, ChatTranscript.models.contains(where: parts[0].contains) {
            HStack {
                Menu {
                    Section("model") {
                        ForEach(ChatTranscript.models, id: \.self) { pick($0, on: parts[0].contains($0), "/model ") }
                    }
                    Section("effort") {
                        ForEach(ChatTranscript.efforts, id: \.self) { pick($0, on: parts.count > 1 && parts[1] == $0, "/effort ") }
                    }
                } label: {
                    Text(model + " ▾").font(mono(10)).foregroundStyle(.secondary)
                }
                .menuOrder(.fixed)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 6)
            .background(.bar)
        }
    }

    private func pick(_ name: String, on: Bool, _ command: String) -> some View {
        Button { store.send(command + name + "\r", to: tab) } label: {
            if on { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            photoButton(size: 22)
            ComposeField(text: $c.draft, focused: $c.focused, placeholder: "Message", onImage: attach, onReturn: submit)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.15), lineWidth: 1).allowsHitTesting(false))
            Button(action: stopping ? stop : submit) {
                Image(systemName: stopping ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend || stopping ? knifeAccent : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !stopping)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var terminalBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if tab.title.hasPrefix("job:"), tab.attention { // routing wants a pick: one tap
                ForEach(1...3, id: \.self) { n in
                    Button { store.send("\(n)\r", to: tab) } label: {
                        Text("\(n)").font(mono(13, bold: true)).frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(knifeAccent.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if multiSelect {
                Button { store.send(ScreenPrompt.multiSelectSubmit, to: tab) } label: {
                    Text("submit ›").font(mono(11, bold: true))
                }
                .buttonStyle(.plain)
            }
            photoButton(size: 15)
            ComposeField(text: $c.draft, focused: $c.focused, placeholder: "type here, ⏎ sends", maxLines: 4, onImage: attach, onReturn: submit)
            if c.focused {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 15))
                }
                .buttonStyle(.plain)
            }
            Button(action: stopping ? stop : submit) { Text(stopping ? "stop" : "send").font(mono(11, bold: true)) }
                .buttonStyle(.plain)
                .disabled(!canSend && !stopping)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.bar)
    }

    /// Photos — taken, picked, or pasted into the box — wait as thumbnails above the input
    /// until the next send.
    private func photoButton(size: CGFloat) -> some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
            }
            Button { showLibrary = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
        } label: {
            Image(systemName: "plus").font(.system(size: size)).foregroundStyle(knifeAccent)
                .padding(.bottom, size > 20 ? 6 : 0)
        }
        .photosPicker(isPresented: $showLibrary, selection: $photos, matching: .images)
        .fullScreenCover(isPresented: $showCamera) { CameraPicker(shot: attach).ignoresSafeArea() }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { attach(data) }
                }
            }
        }
    }

    private func attach(_ img: UIImage) {
        if let data = img.jpegData(compressionQuality: 0.9) { attach(data) }
    }

    private func attach(_ data: Data) {
        guard let b64 = SessionDetailView.jpegBase64(data),
              let jpg = Data(base64Encoded: b64), let img = UIImage(data: jpg) else { return }
        c.attached.append((UUID(), img.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? img, b64))
    }

    private func stop() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        store.send("\u{1b}", to: tab)
    }

    @ViewBuilder private var attachmentStrip: some View {
        if !c.attached.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(c.attached, id: \.id) { a in
                        Image(uiImage: a.thumb).resizable().scaledToFill()
                            .frame(width: 56, height: 56).clipped()
                            .overlay(alignment: .topTrailing) {
                                Button { c.attached.removeAll { $0.id == a.id } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).padding(2)
                            }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    /// The send button, and ⏎ — which with nothing typed sends a bare Enter (answers a prompt).
    private func submit() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // each photo lands on the Mac as a pasted path; in a Claude tab a newline (Ctrl+J)
        // then keeps the message on its own line instead of running into the path
        for a in c.attached { store.send(CloudSync.imagePrefix + a.b64, to: tab) }
        let sep = !c.attached.isEmpty && !c.draft.isEmpty && !tab.chat.isEmpty ? "\n" : ""
        c.attached = []
        store.send(sep + c.draft + "\r", to: tab)
        sent(c.draft.trimmingCharacters(in: .whitespacesAndNewlines))
        c.draft = ""
    }
}

/// The text box of every composer. A UITextView, not TextField(axis: .vertical): there ⏎
/// submits or lands in the text as a newline by turns, and UIKit writes a just-cleared binding
/// back (iOS 26, 27), so the sent message stayed in the box. Here ⏎ always calls onReturn and
/// is never text, and the keyboard stays up.
struct ComposeField: UIViewRepresentable {
    @Binding var text: String
    var focused: Binding<Bool> = .constant(false)
    let placeholder: String
    var maxLines = 5
    var prose = false   // a dictated request rather than terminal input: autocorrect and capitals stay on
    var onImage: ((UIImage) -> Void)? = nil   // Paste with a picture on the clipboard attaches it
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = PasteTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = UIFont(name: "Space Mono", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.returnKeyType = .send
        if !prose { // a command must arrive as typed: no “ ” for quotes, no — for --
            tv.autocorrectionType = .no; tv.autocapitalizationType = .none
            tv.smartQuotesType = .no; tv.smartDashesType = .no; tv.smartInsertDeleteType = .no
        }
        let hint = context.coordinator.hint
        hint.text = placeholder; hint.font = tv.font; hint.textColor = .placeholderText
        hint.sizeToFit()
        tv.addSubview(hint)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.3
        hold.delegate = context.coordinator
        tv.addGestureRecognizer(hold)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self // onReturn closes over the tab as it is now
        (tv as? PasteTextView)?.onImage = onImage
        guard tv.text != text else { return }
        tv.text = text
        context.coordinator.hint.isHidden = !text.isEmpty
        tv.invalidateIntrinsicContentSize()
    }

    /// As tall as its text, up to maxLines; past that it scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        guard let w = proposal.width, w > 0, w.isFinite else { return nil }
        let line = tv.font?.lineHeight ?? 18
        let h = tv.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        return CGSize(width: w, height: min(max(h, line), ceil(line * CGFloat(maxLines))))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ComposeField
        let hint = UILabel()
        init(_ parent: ComposeField) { self.parent = parent }

        /// Keyboard down, hold the box: talk, and the words land in it as they are heard.
        /// Letting go stops listening; nothing is sent.
        @objc func hold(_ g: UILongPressGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            switch g.state {
            case .began:
                let base = tv.text.isEmpty || tv.text.hasSuffix(" ") ? tv.text ?? "" : tv.text + " "
                var last = tv.text ?? ""
                let on = Dictation.shared.start { [weak self, weak tv] heard in
                    // typed over or sent since: a late transcript must not bring the text back
                    guard let self, let tv, tv.text == last else { return }
                    last = base + heard
                    tv.text = last
                    self.textViewDidChange(tv)
                }
                guard on else { return } // the first hold only asks for the mic
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                hint.text = "listening…"; hint.sizeToFit()
                tv.backgroundColor = UIColor(knifeAccent).withAlphaComponent(0.18)
            case .ended, .cancelled, .failed:
                Dictation.shared.stop()
                hint.text = parent.placeholder; hint.sizeToFit()
                tv.backgroundColor = .clear
            default: break
            }
        }

        /// Only with the keyboard down: with it up, a hold is the loupe and the selection as ever.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { g.view?.isFirstResponder == false }
        /// The text view's own tap and hold wait for ours, or a hold would also open the keyboard.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view == g.view
        }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText s: String) -> Bool {
            // mid-composition (pinyin, kana) ⏎ belongs to the input method: it commits the candidate
            guard s == "\n", tv.markedTextRange == nil else { return true }
            parent.onReturn()
            return false
        }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            hint.isHidden = !tv.text.isEmpty
            tv.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ tv: UITextView) { parent.focused.wrappedValue = true }
        func textViewDidEndEditing(_ tv: UITextView) { parent.focused.wrappedValue = false }
    }
}

/// A text view whose Paste takes a picture off the clipboard too.
private final class PasteTextView: UITextView {
    var onImage: ((UIImage) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onImage != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let onImage, UIPasteboard.general.hasImages, let img = UIPasteboard.general.image { onImage(img) }
        else { super.paste(sender) }
    }
}

/// The system camera; hands back the shot.
private struct CameraPicker: UIViewControllerRepresentable {
    let shot: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.shot(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// ─── Hold to talk ───

/// The mic into a live transcript, on the phone when the language allows it. Not @MainActor:
/// the audio tap and the recognizer call back on their own threads.
final class Dictation {
    static let shared = Dictation()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// False when it did not start — the first time, because it is asking for the mic instead.
    func start(_ heard: @escaping (String) -> Void) -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioApplication.shared.recordPermission == .granted else {
            SFSpeechRecognizer.requestAuthorization { _ in AVAudioApplication.requestRecordPermission { _ in } }
            return false
        }
        guard request == nil, let rec = SFSpeechRecognizer(), rec.isAvailable else { return false }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.addsPunctuation = true
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        let input = engine.inputNode
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        request = req
        // ponytail: one recognition task per hold, so the transcript is whatever that task
        // reports — if a long pause ever restarts it mid-hold, keep the finished segments here.
        rec.recognitionTask(with: req) { result, _ in
            guard let text = result?.bestTranscription.formattedString, !text.isEmpty else { return }
            DispatchQueue.main.async { heard(text) }
        }
        return true
    }

    /// The last words still arrive after this, once the recognizer has finished with them.
    func stop() {
        guard let req = request else { return }
        request = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        req.endAudio()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
