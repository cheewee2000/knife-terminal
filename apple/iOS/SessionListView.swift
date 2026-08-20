import SwiftUI
import KnifeKit

private func mono(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "Space Mono Bold" : "Space Mono", size: size)
}

let knifeAccent = Color(red: 0xB1 / 255.0, green: 0xA5 / 255.0, blue: 0x7E / 255.0)
let knifeOrange = Color(red: 0xE3 / 255.0, green: 0x5A / 255.0, blue: 0x1E / 255.0)

struct SessionListView: View {
    @EnvironmentObject var store: MirrorStore

    var body: some View {
        NavigationStack {
            Group {
                if store.tabs.isEmpty {
                    VStack(spacing: 12) {
                        Text("no live sessions").font(mono(13)).foregroundStyle(.secondary)
                        Text("open Knife Terminal on your Mac").font(mono(11)).foregroundStyle(.tertiary)
                        if let t = store.lastSync {
                            Text("last sync \(t.formatted(date: .omitted, time: .standard))")
                                .font(mono(10)).foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    List(store.tabs) { tab in
                        NavigationLink(value: tab.id) {
                            SessionRow(tab: tab)
                        }
                    }
                    .listStyle(.plain)
                }
            }
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

struct SessionRow: View {
    let tab: MirroredTab
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tab.attention ? knifeOrange : (tab.working ? knifeAccent : .clear))
                .frame(width: 7, height: 7)
                .opacity(isPulsing ? (pulse ? 0.25 : 1) : 1)
                .onAppear { if isPulsing { startPulse() } }
                .onChange(of: isPulsing) { _, now in
                    if now { startPulse() } else { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { pulse = false } }
                }
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

    private func startPulse() {
        pulse = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }

    private func relative(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
