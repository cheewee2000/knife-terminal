import SwiftUI
import AppKit

/// The repo behind the active tab: branch, changes, last commit, its pull requests with their
/// checks, and open issues with "agent" (a new claude tab on the issue). Everything goes through
/// `git` and the `gh` CLI's own login; nothing is stored.
struct GitPanel: View {
    @ObservedObject var controller: KnifeWindowController
    @State private var info: GitInfo?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear.frame(height: 30) // titlebar
                HStack {
                    Text(info.map { ($0.root as NSString).lastPathComponent } ?? "git").font(mono(11))
                    Spacer()
                    Button(loading ? "…" : "refresh") { Task { await reload() } }
                        .buttonStyle(.plain).font(mono(10)).foregroundStyle(.secondary)
                }
                if let info {
                    Text(info.branch).font(mono(10)).foregroundStyle(.secondary)
                    if let last = info.last { Text(last).font(mono(10)).foregroundStyle(.secondary).lineLimit(2) }
                    section(info.changes.isEmpty ? "clean" : "\(info.changes.count) changed")
                    ForEach(info.changes.prefix(12), id: \.self) { Text($0).font(mono(10)).lineLimit(1) }
                    if info.changes.count > 12 { Text("+\(info.changes.count - 12) more").font(mono(10)).foregroundStyle(.secondary) }
                    if let prs = info.prs {
                        section(prs.isEmpty ? "no open pull requests" : "pull requests")
                        ForEach(prs) { pr in
                            row("\(pr.checks) #\(pr.number) \(pr.title)") { NSWorkspace.shared.open(pr.url) }
                        }
                    }
                    if let issues = info.issues {
                        section(issues.isEmpty ? "no open issues" : "issues")
                        ForEach(issues) { issue in
                            HStack(alignment: .top, spacing: 6) {
                                row("#\(issue.number) \(issue.title)") { NSWorkspace.shared.open(issue.url) }
                                Button("agent") { startAgent(on: issue, in: info.root) }
                                    .buttonStyle(.plain).font(mono(10)).foregroundStyle(.secondary)
                                    .help("new tab running claude on this issue")
                            }
                        }
                    }
                    if info.prs == nil && info.issues == nil {
                        Text("gh: no GitHub remote, or not signed in (gh auth login)").font(mono(10)).foregroundStyle(.secondary)
                    }
                } else if !loading {
                    Text("not a git repo").font(mono(10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: controller.activeId) {
            // ponytail: polls every 60 s while shown; watch .git/ with FSEvents if that feels slow
            while !Task.isCancelled { await reload(); try? await Task.sleep(for: .seconds(60)) }
        }
    }

    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.top, 6)
            Text(title).font(mono(10)).foregroundStyle(.secondary)
        }
    }

    private func row(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(mono(10)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func startAgent(on issue: GitInfo.Item, in root: String) {
        let prompt = "Work on GitHub issue #\(issue.number): \(issue.title). Read it first with: gh issue view \(issue.number) --comments"
        controller.addTab(TabOptions(cwd: root, cmd: "claude " + shellQuote(prompt),
                                     title: "#\(issue.number) " + (root as NSString).lastPathComponent, restoreCmd: "claude -c"))
    }

    private func reload() async {
        guard let tab = controller.activeTab else { info = nil; return }
        loading = true
        let pid = tab.shellPid, fallback = tab.lastReportedCwd
        info = await Task.detached { GitInfo.load(cwd: (pid > 0 ? TabModel.cwdOf(pid: pid) : nil) ?? fallback) }.value
        loading = false
    }
}

struct GitInfo {
    struct Item: Identifiable { var number: Int; var title: String; var url: URL; var checks = ""; var id: Int { number } }
    var root: String
    var branch: String          // "main...origin/main [ahead 1]"
    var changes: [String]       // porcelain lines: " M file"
    var last: String?
    var prs: [Item]?            // nil: gh failed (no remote, not signed in)
    var issues: [Item]?

    nonisolated static func load(cwd: String?) -> GitInfo? {
        guard let cwd, let root = Manifest.run(["git", "rev-parse", "--show-toplevel"], cwd: cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else { return nil }
        let status = (Manifest.run(["git", "status", "-sb", "--porcelain"], cwd: root) ?? "").split(separator: "\n").map(String.init)
        let last = Manifest.run(["git", "log", "-1", "--format=%h %s · %cr"], cwd: root)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prs = items(Manifest.run(["gh", "pr", "list", "--limit", "10", "--json", "number,title,url,statusCheckRollup"], cwd: root))
        let issues = items(Manifest.run(["gh", "issue", "list", "--limit", "20", "--json", "number,title,url"], cwd: root))
        return GitInfo(root: root, branch: status.first.map { String($0.dropFirst(3)) } ?? "",
                       changes: Array(status.dropFirst()), last: last, prs: prs, issues: issues)
    }

    private nonisolated static func items(_ json: String?) -> [Item]? {
        guard let data = json?.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.compactMap { j in
            guard let n = j["number"] as? Int, let t = j["title"] as? String,
                  let u = (j["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Item(number: n, title: t, url: u, checks: checkMark(j["statusCheckRollup"] as? [[String: Any]]))
        }
    }

    /// ✗ any check failed · … some still running · ✓ all passed · "" none
    nonisolated static func checkMark(_ checks: [[String: Any]]?) -> String {
        guard let checks, !checks.isEmpty else { return "" }
        let states = checks.map { c in (c["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (c["state"] as? String) ?? "PENDING" }
        if states.contains(where: ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains) { return "✗" }
        return states.allSatisfy(["SUCCESS", "NEUTRAL", "SKIPPED"].contains) ? "✓" : "…"
    }
}
