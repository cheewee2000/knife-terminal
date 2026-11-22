import SwiftUI
import KnifeKit

private func mono(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "Space Mono Bold" : "Space Mono", size: size)
}

let knifeAccent = Color(red: 0xB1 / 255.0, green: 0xA5 / 255.0, blue: 0x7E / 255.0)
let knifeOrange = Color(red: 0xE3 / 255.0, green: 0x5A / 255.0, blue: 0x1E / 255.0)

struct SessionListView: View {
    @EnvironmentObject var store: MirrorStore
    @State private var query = ""
    @State private var selected: String?   // the open session; drives the push (stack) or the detail column (split)
    @State private var landscape = false
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var request = ""

    private var q: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var filteredTabs: [MirroredTab] {
        guard !q.isEmpty else { return store.tabs }
        return store.tabs.filter { $0.title.lowercased().contains(q) || ($0.cwd ?? "").lowercased().contains(q) }
    }

    /// Recent projects with no live tab on the Mac.
    private var closedProjects: [ProjectRef] {
        let closed = store.projects.filter { p in !store.tabs.contains { $0.cwd == p.path } }
        guard !q.isEmpty else { return closed }
        return closed.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    private var syncStatus: String {
        let last = store.lastSync.map { "last sync \($0.formatted(date: .omitted, time: .shortened))" } ?? "never synced"
        if let e = store.syncError { return "\(e) · \(last)" }
        return last
    }

    var body: some View {
        // One view for both layouts: a split view collapses to a plain stack when the width is
        // compact, so the size class it sees is regular only on a wide screen held sideways
        // (iPhone Duo unfolded, Pro Max, iPad) — upright it stays the single column it always was.
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selected) {
                Section {
                    HStack(alignment: .bottom, spacing: 8) {
                        ComposeField(text: $request, placeholder: "dictate or type a request…", maxLines: 6, prose: true) {
                            store.postJob(request); request = ""
                        }
                        if store.pendingJob {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { store.postJob(request); request = "" } label: {
                                Text("send").font(mono(11, bold: true)).foregroundStyle(request.isEmpty ? .secondary : knifeAccent)
                            }
                            .buttonStyle(.plain).disabled(request.isEmpty)
                        }
                    }
                    .padding(.vertical, 2)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("ask — routed to a project, run on the executor").font(mono(10)).foregroundStyle(.secondary)
                }
                Section {
                    if store.tabs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("no live sessions").font(mono(13)).foregroundStyle(.secondary)
                            Text("open Knife Terminal on your Mac").font(mono(11)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredTabs) { tab in
                            NavigationLink(value: tab.id) {
                                SessionRow(tab: tab, machine: store.machines.count > 1 ? TabIds.machine(of: tab.tabId, among: store.machines) : nil)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.closeTab(tab)
                                } label: {
                                    Text(tab.share == nil ? "close" : "leave").font(mono(11))
                                }
                            }
                        }
                    }
                } header: {
                    Text("sessions").font(mono(10)).foregroundStyle(.secondary)
                }
                if !closedProjects.isEmpty {
                    Section {
                        ForEach(closedProjects) { p in
                            ProjectRow(project: p, pending: store.pendingOpens.contains(p.path), machines: store.machines,
                                       open: { agent in store.openProject(p, agent: agent) },
                                       setRunOn: { tag in store.setRunOn(p, tag) })
                        }
                    } header: {
                        Text("projects — tap to open on the Mac (Claude, or Codex via open ▾)").font(mono(10)).foregroundStyle(.secondary)
                    }
                }
                Section {
                    VStack(spacing: 6) {
                        Text(syncStatus).font(mono(10))
                            .foregroundStyle(store.syncError == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(knifeOrange))
                            .multilineTextAlignment(.center)
                        Text(Brand.idLabel).font(mono(10)).foregroundStyle(.tertiary)
                        Link("cwandt.com", destination: URL(string: "https://cwandt.com")!)
                            .font(mono(10)).foregroundStyle(knifeAccent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "search sessions + projects")
            .navigationTitle("Knife Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: { Text("sync").font(mono(11)) }
                }
                .inVerticalBar()
            }
            .refreshable { await store.refresh() }
        } detail: {
            // not wrapped in a lookup: a tab that leaves the list while open used to leave a blank
            // screen here; the detail view says "session closed on the Mac" itself
            if let selected {
                SessionDetailView(tabRecordName: selected).id(selected) // fresh draft + scroll per session
            } else {
                Text("pick a session").font(mono(12)).foregroundStyle(.secondary)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.horizontalSizeClass, hSize == .regular && landscape ? .regular : .compact)
        // the whole window, so the keyboard coming up cannot make an upright screen look sideways
        .background {
            Color.clear.ignoresSafeArea()
                .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { landscape = $0 }
        }
        .onAppear {
            if DemoData.enabled, DemoData.openFirstTab, let first = DemoData.tabs.first {
                selected = first.id
            }
        }
    }
}

extension ToolbarContent {
    /// iPhone Duo cover screen (iOS 27.1+): the system keeps a vertical bar down the trailing edge,
    /// under the camera and clock. Items marked this way sit there with the back button and leave
    /// the top bar to the title; everywhere else they stay in the top bar.
    @ToolbarContentBuilder func inVerticalBar() -> some ToolbarContent {
        if #available(iOS 27.1, *) { axisBehavior(.verticalPreferred) } else { self }
    }
}

/// Tells SwiftUI whether the system has a vertical bar here — UIKit knows (a trait), SwiftUI has
/// no environment value for it. Changes when the phone folds or unfolds.
struct VerticalBarProbe: UIViewRepresentable {
    @Binding var present: Bool

    final class Probe: UIView {
        var report: (Bool) -> Void = { _ in }
        override func didMoveToWindow() { super.didMoveToWindow(); check() }
        func check() {
            guard #available(iOS 27.1, *) else { return }
            let now = traitCollection.verticalBarEdge != .unspecified
            DispatchQueue.main.async { self.report(now) } // not during a view update
        }
    }

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        if #available(iOS 27.1, *) {
            v.registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (v: Probe, _) in v.check() }
        }
        return v
    }
    func updateUIView(_ v: Probe, context: Context) { v.report = { if present != $0 { present = $0 } } }
}

struct ProjectRow: View {
    let project: ProjectRef
    let pending: Bool
    let machines: [String]
    let open: (String) -> Void   // "claude" | "codex"
    let setRunOn: (String?) -> Void   // machine | "cloud" | nil = the executor

    private var cloud: Bool { project.runOn == "cloud" }

    var body: some View {
        HStack(spacing: 8) {
            Text(Emoji.forPath(project.path))
            Text(project.name).font(mono(13)).lineLimit(1)
            if let w = project.runOn { Text(w).font(mono(10)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if pending {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    if !cloud {
                        Button("open with Claude Code") { open("claude") }
                        Button("open with Codex") { open("codex") }
                    }
                    Menu("run jobs on" + (project.runOn.map { " (\($0))" } ?? "")) {
                        Button("auto — the executor") { setRunOn(nil) }
                        ForEach(machines, id: \.self) { m in Button(m) { setRunOn(m) } }
                        Button("cloud — the Claude app, not Knife") { setRunOn("cloud") }
                    }
                } label: {
                    Text(cloud ? "cloud ▾" : "open ▾").font(mono(11)).foregroundStyle(knifeAccent)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if !pending && !cloud { open("claude") } } // row tap = Claude, the default agent; cloud projects live in the Claude app
    }
}

struct SessionRow: View {
    let tab: MirroredTab
    var machine: String? = nil   // which Mac runs it, when there is more than one
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tab.attention ? knifeOrange : (tab.working ? knifeAccent : .clear))
                .frame(width: 7, height: 7)
                .opacity(isPulsing && pulse ? 0.25 : 1)
                .animation(isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = isPulsing }
                .onChange(of: isPulsing) { _, now in pulse = now }
            Text(tab.emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(mono(13, bold: tab.attention)).lineLimit(1)
                HStack(spacing: 6) {
                    if tab.share != nil { Text("shared with you").font(mono(10)).foregroundStyle(knifeAccent) }
                    if tab.attention { Text("waiting for you").font(mono(10)).foregroundStyle(knifeOrange) }
                    else if tab.working { Text("working").font(mono(10)).foregroundStyle(.secondary) }
                    Text(relative(tab.updatedAt)).font(mono(10)).foregroundStyle(.tertiary)
                    if let machine, tab.share == nil { Text(machine).font(mono(10)).foregroundStyle(.tertiary) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var isPulsing: Bool { tab.working && !tab.attention }

    private func relative(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
