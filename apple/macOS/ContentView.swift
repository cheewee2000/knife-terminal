import SwiftUI
import AppKit
import KnifeKit

extension Notification.Name {
    static let knifeFocusSearch = Notification.Name("knife.focusSearch")
    static let knifeToggleSidebar = Notification.Name("knife.toggleSidebar")
}

private func mono(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "Space Mono Bold" : "Space Mono", size: size)
}

struct ContentView: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var theme = AppModel.shared.theme
    @AppStorage("sidebarCollapsed") private var collapsed = false
    @AppStorage("sideWidth") private var sideWidth: Double = 220

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !collapsed {
                    SidebarView(controller: controller)
                        .frame(width: max(160, min(480, sideWidth)))
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1)
                        .overlay(
                            Rectangle().fill(Color.clear).frame(width: 7)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { v in sideWidth = max(160, min(480, v.location.x)) })
                                .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                        )
                }
                TerminalPane(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            FooterBar(controller: controller)
        }
        .background(bg)
        .ignoresSafeArea()
    }

    private var bg: Color { Color(nsColor: theme.nsColor(theme.current.background)) }
}

// ─── Terminal host: shows the active tab's NSView ───

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var controller: KnifeWindowController

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let tab = controller.activeTab else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        let tv = tab.view
        if tv.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            tv.frame = container.bounds
            tv.autoresizingMask = [.width, .height]
            container.addSubview(tv)
        }
        DispatchQueue.main.async {
            if let w = tv.window, w.firstResponder !== tv, w.isKeyWindow {
                w.makeFirstResponder(tv)
            }
        }
    }
}

// ─── Sidebar ───

struct SidebarView: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var theme = AppModel.shared.theme
    @State private var projects: [Project] = []
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38) // room for traffic lights

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(controller.tabs) { tab in
                        TabRow(tab: tab, active: tab.id == controller.activeId,
                               activate: { controller.activate(tab.id) },
                               close: { controller.closeTab(tab.id) })
                    }
                    Button(action: { controller.addTab() }) {
                        HStack(spacing: 6) {
                            Text("+").font(mono(12))
                            Text("new tab").font(mono(11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                        .padding(.vertical, 6)

                    TextField("⌘K search projects", text: $query)
                        .textFieldStyle(.plain)
                        .font(mono(11))
                        .focused($searchFocused)
                        .padding(.horizontal, 10).padding(.bottom, 4)
                        .onSubmit {
                            if let first = filtered.first { open(project: first) }
                        }
                        .onExitCommand { query = ""; searchFocused = false }

                    ForEach(filtered) { p in
                        Button(action: { open(project: p) }) {
                            HStack(spacing: 6) {
                                Text(Emoji.forPath(p.path)).font(.system(size: 12))
                                Text(p.name).font(mono(11)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(p.path)
                    }
                }
                .padding(.vertical, 4)
            }

        }
        .onAppear { projects = Projects.list() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            guard (n.object as? NSWindow) === controller.window else { return }
            projects = Projects.list()
        }
        .onReceive(NotificationCenter.default.publisher(for: .knifeFocusSearch)) { _ in
            if controller.window?.isKeyWindow ?? false { searchFocused = true }
        }
    }

    private var filtered: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return projects }
        return projects.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    private func open(project p: Project) {
        controller.addTab(TabOptions(cwd: p.path, cmd: "claude", title: p.name, restoreCmd: "claude -c"))
        query = ""
        searchFocused = false
    }

}

// ─── Footer: spans the full window width, below sidebar + terminal ───

struct FooterBar: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var theme = AppModel.shared.theme
    @State private var hooksOn = HooksInstaller.installed()
    @State private var ctxScope: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            HStack(spacing: 12) {
                footBtn(theme.mode.rawValue) { theme.cycle() }
                footBtn(hooksOn ? "alerts on" : "alerts off") {
                    _ = HooksInstaller.install(); hooksOn = HooksInstaller.installed()
                }
                footBtn("set default") { DefaultTerminal.register() }
                footBtn("global ctx") { ctxScope = ctxScope == "global" ? nil : "global" }
                    .popover(isPresented: Binding(get: { ctxScope == "global" }, set: { if !$0 { ctxScope = nil } })) {
                        ContextPanel(scope: "global", cwd: nil)
                    }
                footBtn("tab ctx") { ctxScope = ctxScope == "session" ? nil : "session" }
                    .popover(isPresented: Binding(get: { ctxScope == "session" }, set: { if !$0 { ctxScope = nil } })) {
                        ContextPanel(scope: "session", cwd: controller.activeTab?.currentCwd)
                    }
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(mono(9)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            guard (n.object as? NSWindow) === controller.window else { return }
            hooksOn = HooksInstaller.installed()
        }
    }

    private func footBtn(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(mono(10)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

struct TabRow: View {
    @ObservedObject var tab: TabModel
    let active: Bool
    let activate: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var pulse = false

    private let accent = Color(red: 0xB1 / 255.0, green: 0xA5 / 255.0, blue: 0x7E / 255.0)
    private let signalOrange = Color(red: 0xE3 / 255.0, green: 0x5A / 255.0, blue: 0x1E / 255.0)

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tab.attention ? signalOrange : (tab.working ? accent : .clear))
                .frame(width: 6, height: 6)
                .opacity(isPulsing ? (pulse ? 0.25 : 1.0) : 1.0)
                .onAppear { if isPulsing { startPulse() } }
                .onChange(of: isPulsing) { _, now in
                    if now { startPulse() } else { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { pulse = false } }
                }
            Text(tab.emoji).font(.system(size: 12))
            Text(tab.title).font(mono(11, bold: active)).lineLimit(1)
                .foregroundStyle(active ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            if hovering {
                Button(action: close) {
                    Text("×").font(mono(11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(active ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .onHover { hovering = $0 }
    }

    private var isPulsing: Bool { tab.working && !tab.attention }

    private func startPulse() {
        pulse = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }
}

struct ContextPanel: View {
    let scope: String
    let cwd: String?

    var body: some View {
        let home = NSHomeDirectory()
        let result = scope == "global" ? (cwd: nil as String?, files: ContextFiles.global()) : ContextFiles.session(cwd: cwd)
        let short = { (p: String) -> String in p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
        return VStack(alignment: .leading, spacing: 6) {
            Text(scope == "global" ? "loaded into every session"
                 : "loaded by this tab" + (result.cwd.map { " — " + short($0) } ?? ""))
                .font(mono(10, bold: true))
            if result.files.isEmpty {
                Text(scope == "global" ? "no global context files"
                     : (cwd != nil ? "no project context files" : "no shell running in this tab"))
                    .font(mono(10)).foregroundStyle(.secondary)
            }
            ForEach(result.files) { f in
                Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }) {
                    HStack(spacing: 8) {
                        Text((f.path as NSString).lastPathComponent).font(mono(10, bold: true))
                        Text(short((f.path as NSString).deletingLastPathComponent)).font(mono(9)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(f.size < 1024 ? "\(f.size)b" : String(format: "%.1fk", Double(f.size) / 1024))
                            .font(mono(9)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 300, alignment: .leading)
    }
}
