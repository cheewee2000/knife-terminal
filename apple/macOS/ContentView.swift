import SwiftUI
import AppKit
import KnifeKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let knifeFocusSearch = Notification.Name("knife.focusSearch")
    static let knifeToggleSidebar = Notification.Name("knife.toggleSidebar")
}

// Chrome type: Helvetica Now Text (system-installed); the terminal grid stays monospace.
func ui(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "HelveticaNowText-Medium" : "HelveticaNowText-Regular", size: size)
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
                if controller.showBoard {
                    BoardView(controller: controller)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TerminalPane(controller: controller)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var meta = Projects.SidebarMeta()
    @State private var sectioned: [(ProjectSection, [Project])] = []
    @State private var query = ""
    @State private var drag: SidebarDrag?
    @State private var hoverSection: ProjectSection?
    @AppStorage("knife.collapsedSections") private var collapsedRaw = ""
    @State private var renaming: Project?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38) // room for traffic lights

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // Tabs grouped by status (needs input first); manual order kept within
                    // a group. Headers only appear once something is non-idle, so a
                    // window of plain shells looks like a plain list.
                    let grouped = TabStatus.sidebarOrder.map { status in (status, controller.tabs.filter { $0.status == status }) }
                    let showHeaders = grouped.contains { $0.0 != .idle && !$0.1.isEmpty }
                    ForEach(grouped, id: \.0) { status, tabs in
                        if !tabs.isEmpty {
                            if showHeaders { tabGroupHeader(status, count: tabs.count) }
                            ForEach(tabs) { tab in tabRow(tab) }
                        }
                    }
                    Button(action: { controller.addTab() }) {
                        HStack(spacing: 6) {
                            Text("+").font(ui(12))
                            Text("new tab").font(ui(11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                        .padding(.vertical, 6)

                    TextField("⌘K search projects", text: $query)
                        .textFieldStyle(.plain)
                        .font(ui(11))
                        .focused($searchFocused)
                        .padding(.horizontal, 10).padding(.bottom, 4)
                        .onSubmit {
                            if let first = query.trimmingCharacters(in: .whitespaces).isEmpty
                                ? projects.first : filtered.first {
                                open(project: first)
                            }
                        }
                        .onExitCommand { query = ""; searchFocused = false }

                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        // Headers are always rendered: revealing them only while dragging
                        // reflowed the whole list the instant a row was picked up, so the
                        // row under the cursor was no longer the one you grabbed.
                        ForEach(ProjectSection.allCases, id: \.self) { section in
                            let rows = isCollapsed(section) ? [] : projects(in: section)
                            sectionHeader(section)
                                .onDrop(of: [.text], delegate: ProjectSectionDrop(
                                    target: section, drag: $drag,
                                    hoverSection: $hoverSection,
                                    liveMove: liveMove(_:into:),
                                    end: endDrag))
                            ForEach(rows) { p in
                                projectRow(p)
                                    .opacity(drag == .project(p.path) ? 0.4 : 1.0)
                                    .onDrag {
                                        let path = p.path
                                        DispatchQueue.main.async { drag = .project(path) }
                                        return NSItemProvider(object: "proj:\(path)" as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: ProjectRowDrop(
                                        targetPath: p.path, targetSection: section,
                                        drag: $drag,
                                        liveMove: liveMove(_:before:in:),
                                        end: endDrag))
                            }
                        }
                    } else {
                        ForEach(filtered) { p in projectRow(p) }
                    }
                }
                .padding(.vertical, 4)
            }

        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            endDrag()
            return true
        }
        .onAppear(perform: rebuild)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            guard (n.object as? NSWindow) === controller.window else { return }
            rebuild()
        }
        .onReceive(NotificationCenter.default.publisher(for: .knifeFocusSearch)) { _ in
            if controller.window?.isKeyWindow ?? false { searchFocused = true }
        }
        .alert("rename project", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("name", text: $renameText)
            Button("save") { commitRename() }
            Button("cancel", role: .cancel) { renaming = nil }
        } message: {
            Text(renaming.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "")
        }
    }

    private var filtered: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return projects.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    private func tabRow(_ tab: TabModel) -> some View {
        TabRow(tab: tab, active: tab.id == controller.activeId,
               activate: { controller.activate(tab.id) },
               close: { controller.closeTab(tab.id) })
            .opacity(drag == .tab(tab.id) ? 0.4 : 1.0)
            .onDrag {
                let id = tab.id
                // Deferred: writing state inside onDrag re-renders the row while
                // AppKit is opening the drag session, which cancels it.
                DispatchQueue.main.async { drag = .tab(id) }
                return NSItemProvider(object: String(id) as NSString)
            }
            .onDrop(of: [.text], delegate: TabReorderDrop(
                targetId: tab.id, drag: $drag, controller: controller,
                end: endDrag))
    }

    private func tabGroupHeader(_ status: TabStatus, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(status.sidebarLabel)
                .foregroundStyle(status == .needsInput ? theme.attentionColor : Color.secondary)
            Text("\(count)").foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(ui(10))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func projects(in section: ProjectSection) -> [Project] {
        sectioned.first { $0.0 == section }?.1 ?? []
    }

    private func projectRow(_ p: Project) -> some View {
        ProjectRow(project: p, starred: meta.byPath[p.path]?.starred ?? false,
                   open: { open(project: p) },
                   toggleStar: { toggleStar(p) },
                   move: { move(p, to: $0) },
                   rename: { renameText = p.name; renaming = p })
    }

    private func sectionHeader(_ section: ProjectSection) -> some View {
        HStack(spacing: 4) {
            Text(section == .starred ? "★" : section.rawValue)
                .foregroundStyle(.secondary)
            if isCollapsed(section) {
                Text("▸ \(projects(in: section).count)")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(ui(10))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(hoverSection == section ? theme.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { toggleCollapse(section) }
    }

    private func isCollapsed(_ section: ProjectSection) -> Bool {
        collapsedRaw.split(separator: ",").contains(Substring(section.rawValue))
    }

    private func toggleCollapse(_ section: ProjectSection) {
        var set = Set(collapsedRaw.split(separator: ",").map(String.init))
        if !set.insert(section.rawValue).inserted { set.remove(section.rawValue) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    private func rebuild() {
        meta = Projects.loadMeta()
        projects = Projects.list().map { p in
            guard let n = meta.byPath[p.path]?.name, !n.isEmpty else { return p }
            return Project(path: p.path, name: n, t: p.t)
        }
        sectioned = Projects.sectioned(projects, meta: meta)
    }

    private func commitRename() {
        guard let p = renaming else { return }
        var next = meta
        var saved = next.byPath[p.path] ?? ProjectMeta()
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        saved.name = (trimmed.isEmpty || trimmed == (p.path as NSString).lastPathComponent) ? nil : trimmed
        next.byPath[p.path] = saved
        Projects.saveMeta(next)
        renaming = nil
        rebuild()
    }

    private func open(project p: Project) {
        Projects.touch(p.path)
        controller.addTab(TabOptions(cwd: p.path, cmd: "claude", title: p.name, restoreCmd: "claude -c"))
        query = ""
        searchFocused = false
        rebuild()
    }

    private func toggleStar(_ p: Project) {
        var next = meta
        var saved = next.byPath[p.path] ?? ProjectMeta()
        saved.starred.toggle()
        next.byPath[p.path] = saved
        Projects.saveMeta(next)
        rebuild()
    }

    private func move(_ p: Project, to section: ProjectSection) {
        commitDrop(p.path, into: section, snapshotOrder: nil)
    }

    /// Ends whatever drag is in flight by persisting the live order the user can
    /// already see. Every drop target funnels here, so releasing anywhere in the
    /// sidebar sticks instead of snapping back on the next rebuild.
    private func endDrag() {
        hoverSection = nil
        guard case .project(let path) = drag,
              let section = sectioned.first(where: { $0.1.contains { $0.path == path } })?.0 else {
            drag = nil
            return
        }
        commitDrop(path, into: section, snapshotOrder: projects(in: section).map(\.path))
    }

    /// Hovering a section header parks the row at the top of that section, so a
    /// header drop lands where it looks like it will instead of by recency.
    private func liveMove(_ path: String, into section: ProjectSection) {
        guard let fromSection = sectioned.firstIndex(where: { $0.1.contains { $0.path == path } }),
              let fromRow = sectioned[fromSection].1.firstIndex(where: { $0.path == path }),
              let toSection = sectioned.firstIndex(where: { $0.0 == section }),
              !(fromSection == toSection && fromRow == 0) else { return }
        let p = sectioned[fromSection].1.remove(at: fromRow)
        sectioned[toSection].1.insert(p, at: 0)
    }

    private func liveMove(_ path: String, before targetPath: String, in section: ProjectSection) {
        guard path != targetPath,
              let fromSection = sectioned.firstIndex(where: { rows in rows.1.contains { $0.path == path } }),
              let fromRow = sectioned[fromSection].1.firstIndex(where: { $0.path == path }),
              let toSection = sectioned.firstIndex(where: { $0.0 == section }),
              let toRow = sectioned[toSection].1.firstIndex(where: { $0.path == targetPath }) else { return }
        if fromSection == toSection {
            sectioned[fromSection].1.move(
                fromOffsets: IndexSet(integer: fromRow),
                toOffset: toRow > fromRow ? toRow + 1 : toRow)
        } else {
            let p = sectioned[fromSection].1.remove(at: fromRow)
            sectioned[toSection].1.insert(p, at: toRow)
        }
    }

    private func commitDrop(_ path: String, into target: ProjectSection, snapshotOrder: [String]?) {
        guard let p = projects.first(where: { $0.path == path }) else {
            drag = nil
            hoverSection = nil
            rebuild()
            return
        }
        var next = meta
        var saved = next.byPath[path] ?? ProjectMeta()
        if target == .starred {
            saved.starred = true
        } else {
            saved.starred = false
            saved.override = target == Projects.autoSection(p) ? nil : target
        }
        next.byPath[path] = saved
        for section in ProjectSection.allCases {
            let key = section.rawValue
            next.order[key]?.removeAll { $0 == path }
            if next.order[key]?.isEmpty == true { next.order.removeValue(forKey: key) }
        }
        if let snapshotOrder { next.order[target.rawValue] = snapshotOrder }
        Projects.saveMeta(next)
        drag = nil
        hoverSection = nil
        rebuild()
    }
}

private struct ProjectRow: View {
    let project: Project
    let starred: Bool
    let open: () -> Void
    let toggleStar: () -> Void
    let move: (ProjectSection) -> Void
    let rename: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(Emoji.forPath(project.path)).font(.system(size: 12))
            Text(project.name).font(ui(11)).lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button(action: toggleStar) {
                    Text(starred ? "★" : "☆").font(ui(11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(starred ? "unstar" : "star", action: toggleStar)
            Button("rename…", action: rename)
            Divider()
            Button("move to active") { move(.active) }
            Button("move to dormant") { move(.dormant) }
            Button("move to archived") { move(.archived) }
        }
        .help(project.path)
    }
}

/// What the sidebar is currently dragging. One value rather than two parallel
/// optionals, so a tab dragged onto a project row (or the reverse) can't be
/// mistaken for a drag of the target's own kind — both payloads are plain text.
enum SidebarDrag: Equatable {
    case tab(Int)
    case project(String)
}

/// Live-reorders sidebar tabs: dragging a row over another swaps them as you go.
private struct TabReorderDrop: DropDelegate {
    let targetId: Int
    @Binding var drag: SidebarDrag?
    let controller: KnifeWindowController
    let end: () -> Void

    func dropEntered(info: DropInfo) {
        guard case .tab(let from) = drag, from != targetId else { return }
        DispatchQueue.main.async { controller.moveTab(from, before: targetId) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: drag == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Also accepts project drags: releasing over the tab list must commit
        // them rather than leave the row visually moved but unsaved.
        DispatchQueue.main.async { end() }
        return true
    }
}

private struct ProjectRowDrop: DropDelegate {
    let targetPath: String
    let targetSection: ProjectSection
    @Binding var drag: SidebarDrag?
    let liveMove: (String, String, ProjectSection) -> Void
    let end: () -> Void

    func dropEntered(info: DropInfo) {
        guard case .project(let from) = drag, from != targetPath else { return }
        DispatchQueue.main.async { liveMove(from, targetPath, targetSection) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: drag == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        DispatchQueue.main.async { end() }
        return true
    }
}

private struct ProjectSectionDrop: DropDelegate {
    let target: ProjectSection
    @Binding var drag: SidebarDrag?
    @Binding var hoverSection: ProjectSection?
    let liveMove: (String, ProjectSection) -> Void
    let end: () -> Void

    func dropEntered(info: DropInfo) {
        guard case .project(let from) = drag else { return }
        DispatchQueue.main.async {
            hoverSection = target
            liveMove(from, target)
        }
    }

    func dropExited(info: DropInfo) {
        guard hoverSection == target else { return }
        DispatchQueue.main.async { hoverSection = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: drag == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        DispatchQueue.main.async { end() }
        return true
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
                footBtn("board") { controller.showBoard.toggle() }
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
                    .font(ui(9)).foregroundStyle(.tertiary)
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
            Text(label).font(ui(10)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

struct TabRow: View {
    @ObservedObject var tab: TabModel
    let active: Bool
    let activate: () -> Void
    let close: () -> Void
    @ObservedObject var theme = AppModel.shared.theme
    @State private var hovering = false
    @State private var pulse = false

    private var accent: Color { theme.accentColor }
    private var signalOrange: Color { theme.attentionColor }

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
            Text(tab.title).font(ui(11, bold: active)).lineLimit(1)
                .foregroundStyle(active ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            if hovering {
                Button(action: close) {
                    Text("×").font(ui(11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if let word = statusWord {
                Text(word)
                    .font(ui(9))
                    .foregroundStyle(tab.status == .needsInput ? signalOrange : Color.secondary)
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

    private var statusWord: String? {
        switch tab.status {
        case .idle: nil
        case .working: "working…"
        case .ready: "ready"
        case .needsInput: "needs input"
        }
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
                .font(ui(10, bold: true))
            if result.files.isEmpty {
                Text(scope == "global" ? "no global context files"
                     : (cwd != nil ? "no project context files" : "no shell running in this tab"))
                    .font(ui(10)).foregroundStyle(.secondary)
            }
            ForEach(result.files) { f in
                Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }) {
                    HStack(spacing: 8) {
                        Text((f.path as NSString).lastPathComponent).font(ui(10, bold: true))
                        Text(short((f.path as NSString).deletingLastPathComponent)).font(ui(9)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(f.size < 1024 ? "\(f.size)b" : String(format: "%.1fk", Double(f.size) / 1024))
                            .font(ui(9)).foregroundStyle(.tertiary)
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
