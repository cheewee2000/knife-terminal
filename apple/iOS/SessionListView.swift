import SwiftUI
import KnifeKit

struct SessionListView: View {
    @EnvironmentObject var store: MirrorStore
    @Environment(\.colorScheme) private var scheme
    private var theme: TermTheme { .current(scheme) }
    @State private var query = ""
    @State private var path: [String] = []
    /// tab id → one line of what it last said; rebuilt after each sync, not per row,
    /// so scrolling never decodes a transcript.
    @State private var snippets: [String: String] = [:]
    @AppStorage("knife.pushAlerts") private var pushAlerts = false

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

    // ─── Grouping: the sessions that want you, first ───

    private enum Group: String, CaseIterable {
        case needsInput = "needs input", working = "working", idle = "idle"
    }

    private func group(of tab: MirroredTab) -> Group {
        tab.attention ? .needsInput : (tab.working ? .working : .idle)
    }

    private var grouped: [(Group, [MirroredTab])] {
        Group.allCases.compactMap { g in
            let rows = filteredTabs.filter { group(of: $0) == g }
            return rows.isEmpty ? nil : (g, rows)
        }
    }

    private var syncStatus: String {
        let last = store.lastSync.map { "last sync \($0.formatted(date: .omitted, time: .shortened))" } ?? "never synced"
        if let e = store.syncError { return "\(e) · \(last)" }
        return last
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.tabs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("no live sessions").font(ui(15)).foregroundStyle(.secondary)
                            Text("open Knife Terminal on your Mac").font(ui(13)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .listRowSeparator(.hidden)
                    } header: {
                        Text("sessions").font(ui(12)).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(grouped, id: \.0) { group, rows in
                        Section {
                            ForEach(rows) { tab in
                                NavigationLink(value: tab.id) {
                                    SessionRow(tab: tab, snippet: snippets[tab.id])
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        store.closeTab(tab)
                                    } label: {
                                        Text("close").font(ui(13))
                                    }
                                }
                            }
                        } header: {
                            HStack(spacing: 5) {
                                Text(group.rawValue)
                                    .foregroundStyle(group == .needsInput ? theme.attention.color : Color.secondary)
                                Text("\(rows.count)").foregroundStyle(.tertiary)
                            }
                            .font(ui(12))
                        }
                    }
                }
                if !closedProjects.isEmpty {
                    Section {
                        ForEach(closedProjects) { p in
                            ProjectRow(project: p, pending: store.pendingOpens.contains(p.path)) { agent in
                                store.openProject(p, agent: agent)
                            }
                        }
                    } header: {
                        Text("projects").font(ui(12)).foregroundStyle(.secondary)
                    } footer: {
                        Text("tap to open on your Mac").font(ui(11)).foregroundStyle(.tertiary)
                    }
                }
                Section {
                    Toggle(isOn: $pushAlerts) {
                        Text("push when a session needs you").font(ui(13))
                    }
                    .tint(theme.accent.color)
                    .onChange(of: pushAlerts) { _, on in store.setAlerts(on) }
                }
                Section {
                    VStack(spacing: 6) {
                        Text(syncStatus).font(ui(12))
                            .foregroundStyle(store.syncError == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(theme.attention.color))
                            .multilineTextAlignment(.center)
                        Link("cwandt.com", destination: URL(string: "https://cwandt.com")!)
                            .font(ui(12)).foregroundStyle(theme.accent.color)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.background.color)
            .toolbarBackground(theme.background.color, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "search sessions + projects")
            .navigationDestination(for: String.self) { id in
                if let tab = store.tabs.first(where: { $0.id == id }) {
                    SessionDetailView(tabRecordName: tab.id)
                }
            }
            .navigationTitle("Knife Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Knife Terminal").font(ui(15, bold: true))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: { Text("sync").font(ui(13)) }
                }
            }
            .refreshable { await store.refresh() }
        }
        .tint(theme.accent.color)
        .onAppear {
            rebuildSnippets()
            if DemoData.enabled, DemoData.openFirstTab, let first = DemoData.tabs.first {
                path = [first.id]
            }
        }
        .onChange(of: store.lastSync) { _, _ in rebuildSnippets() }
    }

    /// The last thing each session said — Claude's newest reply, or the tool it
    /// is running if it hasn't spoken since.
    private func rebuildSnippets() {
        var out: [String: String] = [:]
        for tab in store.tabs {
            guard let msgs = ChatTranscript.decode(tab.chat),
                  let last = msgs.last(where: { $0.kind == .assistant || $0.kind == .tool })
            else { continue }
            let flat = last.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !flat.isEmpty else { continue }
            out[tab.id] = last.kind == .tool ? "› " + flat : flat
        }
        snippets = out
    }
}

struct ProjectRow: View {
    let project: ProjectRef
    let pending: Bool
    let open: (String) -> Void   // "claude" | "codex"
    @Environment(\.colorScheme) private var scheme
    private var theme: TermTheme { .current(scheme) }

    var body: some View {
        HStack(spacing: 8) {
            Text(Emoji.forPath(project.path))
            Text(project.name).font(ui(15)).lineLimit(2)
            Spacer(minLength: 8)
            if pending {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("open with Claude Code") { open("claude") }
                    Button("open with Codex") { open("codex") }
                } label: {
                    Text("open ▾").font(ui(13)).foregroundStyle(theme.accent.color)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if !pending { open("claude") } } // row tap = Claude, the default agent
    }
}

struct SessionRow: View {
    let tab: MirroredTab
    let snippet: String?
    @State private var pulse = false
    @Environment(\.colorScheme) private var scheme
    private var theme: TermTheme { .current(scheme) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tab.attention ? theme.attention.color : (tab.working ? theme.accent.color : .clear))
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .opacity(isPulsing && pulse ? 0.25 : 1)
                .animation(isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = isPulsing }
                .onChange(of: isPulsing) { _, now in pulse = now }
            Text(tab.emoji)
            VStack(alignment: .leading, spacing: 3) {
                // Titles run long ("✳ Website interactivity and launch dates") — two
                // lines rather than a cut-off one; the group header carries the status.
                Text(tab.title).font(ui(15, bold: tab.attention)).lineLimit(2)
                if let snippet {
                    Text(snippet).font(ui(12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(relative(tab.updatedAt)).font(ui(11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
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
