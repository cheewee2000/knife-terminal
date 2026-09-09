import SwiftUI
import KnifeKit

struct SessionListView: View {
    @EnvironmentObject var store: MirrorStore
    @Environment(\.colorScheme) private var scheme
    private var theme: TermTheme { .current(scheme) }
    @State private var query = ""
    @State private var path: [String] = []

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
        NavigationStack(path: $path) {
            List {
                Section {
                    if store.tabs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("no live sessions").font(ui(15)).foregroundStyle(.secondary)
                            Text("open Knife Terminal on your Mac").font(ui(13)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredTabs) { tab in
                            NavigationLink(value: tab.id) {
                                SessionRow(tab: tab)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.closeTab(tab)
                                } label: {
                                    Text("close").font(ui(13))
                                }
                            }
                        }
                    }
                } header: {
                    Text("sessions").font(ui(12)).foregroundStyle(.secondary)
                }
                if !closedProjects.isEmpty {
                    Section {
                        ForEach(closedProjects) { p in
                            ProjectRow(project: p, pending: store.pendingOpens.contains(p.path)) { agent in
                                store.openProject(p, agent: agent)
                            }
                        }
                    } header: {
                        Text("projects — tap to open on the Mac (Claude, or Codex via open ▾)").font(ui(12)).foregroundStyle(.secondary)
                    }
                }
                Section {
                    VStack(spacing: 6) {
                        Text(syncStatus).font(ui(12))
                            .foregroundStyle(store.syncError == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(theme.attention.color))
                            .multilineTextAlignment(.center)
                        Text(Brand.idLabel).font(ui(12)).foregroundStyle(.tertiary)
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
            if DemoData.enabled, DemoData.openFirstTab, let first = DemoData.tabs.first {
                path = [first.id]
            }
        }
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
            Text(project.name).font(ui(15)).lineLimit(1)
            Spacer()
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
    @State private var pulse = false
    @Environment(\.colorScheme) private var scheme
    private var theme: TermTheme { .current(scheme) }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tab.attention ? theme.attention.color : (tab.working ? theme.accent.color : .clear))
                .frame(width: 7, height: 7)
                .opacity(isPulsing && pulse ? 0.25 : 1)
                .animation(isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = isPulsing }
                .onChange(of: isPulsing) { _, now in pulse = now }
            Text(tab.emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(ui(15, bold: tab.attention)).lineLimit(1)
                HStack(spacing: 6) {
                    if tab.attention { Text("waiting for you").font(ui(12)).foregroundStyle(theme.attention.color) }
                    else if tab.working { Text("working").font(ui(12)).foregroundStyle(.secondary) }
                    Text(relative(tab.updatedAt)).font(ui(12)).foregroundStyle(.tertiary)
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
