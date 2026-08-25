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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.tabs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("no live sessions").font(mono(13)).foregroundStyle(.secondary)
                            Text("open Knife Terminal on your Mac").font(mono(11)).foregroundStyle(.tertiary)
                            if let t = store.lastSync {
                                Text("last sync \(t.formatted(date: .omitted, time: .standard))")
                                    .font(mono(10)).foregroundStyle(.tertiary)
                            }
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
                                    Text("close").font(mono(11))
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
                            ProjectRow(project: p, pending: store.pendingOpens.contains(p.path)) {
                                store.openProject(p)
                            }
                        }
                    } header: {
                        Text("projects — tap to open on the Mac").font(mono(10)).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "search sessions + projects")
            .navigationDestination(for: String.self) { id in
                if let tab = store.tabs.first(where: { $0.id == id }) {
                    SessionDetailView(tabRecordName: tab.id)
                }
            }
            .navigationTitle(Brand.idLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: { Text("sync").font(mono(11)) }
                }
            }
            .refreshable { await store.refresh() }
        }
    }
}

struct ProjectRow: View {
    let project: ProjectRef
    let pending: Bool
    let open: () -> Void

    var body: some View {
        Button(action: { if !pending { open() } }) {
            HStack(spacing: 8) {
                Text(Emoji.forPath(project.path))
                Text(project.name).font(mono(13)).lineLimit(1)
                Spacer()
                if pending {
                    ProgressView().controlSize(.small)
                } else {
                    Text("open").font(mono(11)).foregroundStyle(knifeAccent)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

struct SessionRow: View {
    let tab: MirroredTab
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
                    if tab.attention { Text("waiting for you").font(mono(10)).foregroundStyle(knifeOrange) }
                    else if tab.working { Text("working").font(mono(10)).foregroundStyle(.secondary) }
                    Text(relative(tab.updatedAt)).font(mono(10)).foregroundStyle(.tertiary)
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
