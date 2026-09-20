import SwiftUI
import AppKit
import KnifeKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let knifeFocusSearch = Notification.Name("knife.focusSearch")
    static let knifeChatFind = Notification.Name("knife.chatFind") // object: window controller; userInfo["action"]: NSTextFinder.Action
    static let knifeToggleSidebar = Notification.Name("knife.toggleSidebar")
}

func mono(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "Space Mono Bold" : "Space Mono", size: size)
}

struct ContentView: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var theme = AppModel.shared.theme
    @AppStorage("sidebarCollapsed") private var collapsed = false
    @AppStorage("sideWidth") private var sideWidth: Double = 220
    @AppStorage("gitPanel") private var gitPanel = false
    @AppStorage("chatView") private var chatView = false

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
                Group {
                    if chatView, let tab = controller.activeTab {
                        ChatPane(controller: controller, tab: tab)
                            .id(tab.id) // fresh state per tab: echoes, opened runs, find never carry over
                    } else {
                        TerminalPane(controller: controller)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if gitPanel {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                    GitPanel(controller: controller).frame(width: 280)
                }
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
    @State private var elsewhere: [Project] = []   // in the manifest, checked out only on another Mac
    @State private var query = ""
    @State private var draggingTabId: Int?
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
                            .opacity(draggingTabId == tab.id ? 0.4 : 1.0)
                            .onDrag {
                                draggingTabId = tab.id
                                return NSItemProvider(object: String(tab.id) as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabReorderDrop(
                                targetId: tab.id, dragging: $draggingTabId, controller: controller))
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
                        .contextMenu { projectMenu(p, local: true) }
                    }
                    // manifest projects that only exist on another Mac — open = clone here
                    ForEach(filteredElsewhere) { p in
                        Button(action: { AppModel.shared.openProject(p.path, cmd: "claude"); query = ""; searchFocused = false }) {
                            HStack(spacing: 6) {
                                Text(Emoji.forPath(p.path)).font(.system(size: 12))
                                Text(p.name).font(mono(11)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("clone").font(mono(9))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("on another Mac — opens by cloning it here")
                        .contextMenu { projectMenu(p, local: false) }
                    }

                    JobBox()
                }
                .padding(.vertical, 4)
            }

        }
        .onDrop(of: [.text], isTargeted: nil) { _ in draggingTabId = nil; return true }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            guard (n.object as? NSWindow) === controller.window else { return }
            reload()
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in reload() } // manifest syncs every ~10s
        .onReceive(NotificationCenter.default.publisher(for: .knifeFocusSearch)) { _ in
            if controller.window?.isKeyWindow ?? false { searchFocused = true }
        }
    }

    /// Right-click a project: its folder in Finder, its repo's web page (from the git remote;
    /// for another Mac's project, the manifest's).
    @ViewBuilder
    private func projectMenu(_ p: Project, local: Bool) -> some View {
        if local {
            Button("Open Folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) }
        }
        let remote = local ? Manifest.remote(of: p.path) : Manifest.merged.first { $0.path == p.path }?.remote
        if let url = remote.flatMap(ProjectRef.webURL(forRemote:)) {
            Button("Open Repo Page (\(url.host ?? "web"))") { NSWorkspace.shared.open(url) }
        } else {
            Button("No Git Remote") {}.disabled(true)
        }
    }

    private func reload() {
        let (local, remote) = Manifest.sidebarProjects()
        projects = local; elsewhere = remote
    }

    private var filtered: [Project] { filter(projects) }
    private var filteredElsewhere: [Project] { filter(elsewhere) }

    private func filter(_ list: [Project]) -> [Project] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    private func open(project p: Project) {
        Projects.touch(p.path)
        controller.addTab(TabOptions(cwd: p.path, cmd: "claude", title: p.name, restoreCmd: "claude -c"))
        query = ""
        searchFocused = false
        reload()
    }

}

/// Job request box: routed to a project and run in a job tab (same path as the phone).
struct JobBox: View {
    @State private var request = ""

    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 6)
        TextField("ask — routed to a project, run in a job tab", text: $request, axis: .vertical)
            .textFieldStyle(.plain).font(mono(11)).lineLimit(1...4)
            .padding(.horizontal, 10).padding(.bottom, 4)
            .onSubmit {
                let t = request.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { AppModel.shared.dispatchJob(t) }
                request = ""
            }
    }
}

/// Live-reorders sidebar tabs: dragging a row over another swaps them as you go.
private struct TabReorderDrop: DropDelegate {
    let targetId: Int
    @Binding var dragging: Int?
    let controller: KnifeWindowController

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != targetId else { return }
        DispatchQueue.main.async { controller.moveTab(from, before: targetId) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        DispatchQueue.main.async { dragging = nil }
        return true
    }
}

// ─── Footer: spans the full window width, below sidebar + terminal ───
// Bordered square buttons in groups — view · panels · find · context · setup; a toggle that's
// on draws inverted. Tooltips carry the keyboard shortcut.

struct FooterBar: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var theme = AppModel.shared.theme
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("gitPanel") private var gitPanel = false
    @AppStorage("chatView") private var chatView = false
    @State private var hooksOn = HooksInstaller.installed()
    @State private var ctxScope: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            HStack(spacing: 8) {
                HStack(spacing: -1) { // segmented: shared borders
                    btn("terminal", on: !chatView, help: "terminal view  ⌘⌥C") { chatView = false }
                    btn("chat", on: chatView, help: "chat view  ⌘⌥C") { chatView = true }
                }
                sep
                btn("sidebar", on: !sidebarCollapsed, help: "sidebar  ⌘B") { sidebarCollapsed.toggle() }
                btn("git", on: gitPanel, help: "git panel  ⌘⌥B") { gitPanel.toggle() }
                sep
                btn("find", help: "find in this tab  ⌘F · next ⌘G") {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    (NSApp.delegate as? AppDelegate)?.find(item)
                }
                sep
                btn("global ctx", on: ctxScope == "global", help: "context shared by every session") {
                    ctxScope = ctxScope == "global" ? nil : "global"
                }
                .popover(isPresented: Binding(get: { ctxScope == "global" }, set: { if !$0 { ctxScope = nil } })) {
                    ContextPanel(scope: "global", cwd: nil)
                }
                btn("tab ctx", on: ctxScope == "session", help: "context for this tab's session") {
                    ctxScope = ctxScope == "session" ? nil : "session"
                }
                .popover(isPresented: Binding(get: { ctxScope == "session" }, set: { if !$0 { ctxScope = nil } })) {
                    ContextPanel(scope: "session", cwd: controller.activeTab?.currentCwd)
                }
                sep
                btn("theme: " + theme.mode.rawValue, help: "cycle auto · light · dark") { theme.cycle() }
                btn(hooksOn ? "alerts on" : "alerts off", on: hooksOn, help: "Claude Code hooks for working/attention alerts") {
                    _ = HooksInstaller.install(); hooksOn = HooksInstaller.installed()
                }
                btn("set default", help: "make Knife the default terminal") { DefaultTerminal.register() }
                Spacer(minLength: 8)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(mono(9)).foregroundStyle(.tertiary).fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            guard (n.object as? NSWindow) === controller.window else { return }
            hooksOn = HooksInstaller.installed()
        }
    }

    private var sep: some View { Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14) }

    private func btn(_ label: String, on: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label) }
            .buttonStyle(FootButtonStyle(on: on, paper: Color(nsColor: theme.nsColor(theme.current.background))))
            .help(help)
    }
}

/// Square, 1px-bordered, Space Mono; hover tints, press darkens, `on` inverts (ink fill, paper text).
struct FootButtonStyle: ButtonStyle {
    var on = false
    let paper: Color

    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, on: on, paper: paper) }

    private struct Face: View {
        let configuration: Configuration
        let on: Bool
        let paper: Color
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(mono(10)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? paper : Color.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(on ? Color.primary.opacity(configuration.isPressed ? 0.7 : 0.9)
                               : Color.primary.opacity(configuration.isPressed ? 0.16 : hover ? 0.07 : 0))
                .overlay(Rectangle().stroke(Color.primary.opacity(on ? 0.9 : 0.35), lineWidth: 1))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
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
                .opacity(isPulsing && pulse ? 0.25 : 1.0)
                .animation(isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = isPulsing }
                .onChange(of: isPulsing) { _, now in pulse = now }
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
        .background(active ? Color.primary.opacity(0.16) : Color.clear)
        .overlay(alignment: .leading) {
            if active { Rectangle().fill(accent).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .onHover { hovering = $0 }
    }

    private var isPulsing: Bool { tab.working && !tab.attention }
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
