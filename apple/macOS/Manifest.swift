import AppKit
import KnifeKit

/// The cross-machine project manifest. Each Mac publishes its own recent
/// projects (~/.claude.json) enriched with the git remote (the project's
/// identity), a one-line description, and the last-touched time; the merged
/// view of every machine's list is written to ~/.knife/manifest.json, which
/// the job runner (knife-job.sh) routes against.
@MainActor
enum Manifest {
    static let dir = NSHomeDirectory() + "/.knife"
    static let path = dir + "/manifest.json"
    static let scriptName = "knife-job"

    /// Record-name-safe machine id: "projects-<machine>".
    static let machine: String = {
        let raw = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac"
        return String(raw.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }()

    /// Other machines' lists, as last fetched from CloudKit (record name → refs).
    static var remoteLists: [String: [ProjectRef]] = [:]
    static private(set) var merged: [ProjectRef] = []

    // ─── This machine's entries ───

    static func localRefs() -> [ProjectRef] {
        Projects.list().map { p in
            let remote = remote(of: p.path)
            return ProjectRef(name: p.name, path: p.path, remote: remote,
                              description: remote.flatMap { description(for: p.path, remote: $0) },
                              lastTouched: Date(timeIntervalSince1970: p.t))
        }
    }

    /// Merge everything and write the file the runner reads. Dates go out as
    /// unix seconds so the script's python can read them.
    static func write(local: [ProjectRef]) {
        merged = ProjectRef.merge([local] + remoteLists.filter { $0.key != "projects-" + machine }.values)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? enc.encode(merged).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// A path from any machine's entry → this machine's checkout, or nil when
    /// the project only exists elsewhere (caller clones it).
    static func resolve(path: String) -> (local: String?, ref: ProjectRef?) {
        if FileManager.default.fileExists(atPath: path) { return (path, merged.first { $0.path == path }) }
        guard let ref = merged.first(where: { $0.path == path }), let remote = ref.remote else { return (nil, nil) }
        let local = merged.first { $0.remote == remote && FileManager.default.fileExists(atPath: $0.path) && self.remote(of: $0.path) == remote }?.path
            ?? [dir + "/projects/" + cloneName(remote)].first { FileManager.default.fileExists(atPath: $0 + "/.git") }
        return (local, ref)
    }

    static func cloneName(_ remote: String) -> String {
        var n = (remote as NSString).lastPathComponent
        if n.hasSuffix(".git") { n.removeLast(4) }
        return n
    }

    // ─── git remote (cached on .git/config mtime) ───

    private static var remoteCache: [String: (mtime: Date, remote: String?)] = [:]

    static func remote(of path: String) -> String? {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: path + "/.git/config"))?[.modificationDate] as? Date
        else { return nil } // not a repo (or a worktree, whose .git is a file)
        if let c = remoteCache[path], c.mtime == m { return c.remote }
        let r = run(["git", "-C", path, "remote", "get-url", "origin"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteCache[path] = (m, (r?.isEmpty ?? true) ? nil : r)
        return remoteCache[path]?.remote
    }

    // ─── Descriptions: README first paragraph, else a model writes one; cached by remote ───

    private static let descPath = dir + "/descriptions.json"
    private static var descriptions: [String: String] = {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: descPath)))) ?? [:]
    }()
    private static var generating = false
    private static var queue: [(path: String, remote: String)] = []

    static func description(for path: String, remote: String) -> String? {
        if let d = descriptions[remote] { return d }
        if let d = readmeParagraph(path) { descriptions[remote] = d; saveDescriptions(); return d }
        if !queue.contains(where: { $0.remote == remote }) { queue.append((path, remote)); generateNext() }
        return nil
    }

    private static func readmeParagraph(_ path: String) -> String? {
        for name in ["README.md", "readme.md", "README", "README.txt"] {
            guard let text = try? String(contentsOfFile: path + "/" + name, encoding: .utf8) else { continue }
            var para: [String] = []
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { if para.isEmpty { continue } else { break } }
                if line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("[!") || line.hasPrefix("<") || line.hasPrefix("`") { continue }
                para.append(line)
            }
            let joined = para.joined(separator: " ")
                .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
            if joined.count >= 20 { return String(joined.prefix(240)) }
        }
        return nil
    }

    /// One `claude -p` at a time, in the background; the session lives under
    /// ~/.knife/router (not the project) so it doesn't bump the project's recency.
    private static func generateNext() {
        guard !generating, let next = queue.first else { return }
        generating = true
        queue.removeFirst()
        Task.detached {
            let prompt = "In one specific sentence (max 25 words), say what the software project in \(next.path) does — look at its README, manifest, and top-level source. Reply with the sentence only."
            let out = run(["claude", "-p", "--model", "haiku", "--output-format", "text", "--add-dir", next.path, prompt],
                          cwd: dir + "/router", timeout: 180)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                if let out, !out.isEmpty, out.count < 400 {
                    descriptions[next.remote] = out
                    saveDescriptions()
                    Task { await AppModel.shared.sync?.publishProjectsIfChanged() }
                }
                generating = false
                generateNext()
            }
        }
    }

    private static func saveDescriptions() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(descriptions).write(to: URL(fileURLWithPath: descPath), options: .atomic)
    }

    /// Run a command through the login shell (so `claude`/`gh` on the user's PATH resolve).
    nonisolated static func run(_ argv: [String], cwd: String? = nil, timeout: TimeInterval = 20) -> String? {
        if let cwd { try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: TabModel.userShell())
        p.arguments = ["-lc", argv.map(shellQuote).joined(separator: " ")]
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
