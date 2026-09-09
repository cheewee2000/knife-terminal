import AppKit
import CoreServices

// ─── Unix socket server: Claude Code hooks + "open <dir>" pings ───

final class UnixSocketServer {
    private let path: String
    private var fd: Int32 = -1
    private var boundInode: ino_t = 0
    private var acceptSource: DispatchSourceRead?
    private let onMessage: (String) -> Void
    private let queue = DispatchQueue(label: "knife.socket")

    init(path: String, onMessage: @escaping (String) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    func start() {
        // Another live instance owns the path: leave its socket alone.
        // rebindIfNeeded() takes over if that instance later dies.
        guard !listenerAlive() else { return }
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = makeAddr()
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); fd = -1; return }
        var st = stat()
        if stat(path, &st) == 0 { boundInode = st.st_ino }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        acceptSource = src
    }

    /// Recover when the socket file was deleted or replaced out from under us
    /// (e.g. a second app copy ran and quit): drop the orphaned fd and rebind.
    func rebindIfNeeded() {
        if fd < 0 { start(); return }
        var st = stat()
        if stat(path, &st) != 0 || st.st_ino != boundInode {
            acceptSource?.cancel(); acceptSource = nil
            close(fd); fd = -1; boundInode = 0
            start()
        }
    }

    private func listenerAlive() -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        var addr = makeAddr()
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) }
        } == 0
    }

    private func makeAddr() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count - 1)))
            }
        }
        return addr
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &chunk, chunk.count)
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
                if buf.count > 512 * 1024 { break }
            }
            close(client)
            if let s = String(data: buf, encoding: .utf8), !s.isEmpty { self?.onMessage(s) }
        }
    }

    func stop() {
        acceptSource?.cancel(); acceptSource = nil
        if fd >= 0 { close(fd); fd = -1 }
        // Only delete the file if it's still ours — never a newer instance's socket.
        var st = stat()
        if boundInode != 0, stat(path, &st) == 0, st.st_ino == boundInode { unlink(path) }
        boundInode = 0
    }
}

// ─── Claude Code alert hooks: install into ~/.claude/settings.json ───

enum HooksInstaller {
    static let hookCmd = "[ -n \"$KNIFE_TAB\" ] && { printf '%s ' \"$KNIFE_TAB\"; cat; } | nc -U -w 1 \"$HOME/.knife-terminal.sock\" >/dev/null 2>&1; exit 0"
    static let events = ["Stop", "Notification", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop", "TaskCompleted", "SessionEnd"]
    // Codex CLI reads the same hook format from ~/.codex/hooks.json (no Notification/TaskCompleted events)
    static let codexEvents = ["Stop", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop", "SessionEnd"]
    static var settingsPath: String { (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json") }
    static var codexPath: String { (NSHomeDirectory() as NSString).appendingPathComponent(".codex/hooks.json") }

    static func installed() -> Bool {
        installed(at: settingsPath, events: events) && installed(at: codexPath, events: codexEvents)
    }

    private static func installed(at settingsPath: String, events: [String]) -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = cfg["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in
            guard let arr = hooks[ev], let d = try? JSONSerialization.data(withJSONObject: arr),
                  let s = String(data: d, encoding: .utf8) else { return false }
            return s.contains("knife-terminal.sock")
        }
    }

    @MainActor
    static func install() -> Bool {
        if installed() { return true }
        let alert = NSAlert()
        alert.messageText = "Add Claude Code + Codex hooks for attention alerts?"
        alert.informativeText = "Adds hooks (\(events.joined(separator: ", "))) to \(settingsPath) and \(codexPath). Each hook pings Knife (via ~/.knife-terminal.sock) so the tab shows a thinking animation while the agent works and glows with a chime when it's waiting for you. Nothing else in the files is changed."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return write(to: settingsPath, events: events) && write(to: codexPath, events: codexEvents)
    }

    @MainActor
    private static func write(to settingsPath: String, events: [String]) -> Bool {
        var cfg: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { cfg = j }
        var hooks = cfg["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var arr = hooks[ev] as? [Any] ?? []
            let d = (try? JSONSerialization.data(withJSONObject: arr)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if !d.contains("knife-terminal.sock") {
                arr.append(["matcher": "", "hooks": [["type": "command", "command": hookCmd]]])
            }
            hooks[ev] = arr
        }
        cfg["hooks"] = hooks
        do {
            try FileManager.default.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
            try (String(data: out, encoding: .utf8)! + "\n").write(toFile: settingsPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            let err = NSAlert(); err.messageText = "Could not write settings"; err.informativeText = String(describing: error)
            err.runModal()
            return false
        }
    }
}

// ─── Default terminal registration (was build/set-default.swift) ───

enum DefaultTerminal {
    static let utis = ["com.apple.terminal.shell-script", "public.shell-script", "public.unix-executable", "public.bash-script", "public.zsh-script"]
    static let schemes = ["ssh", "telnet", "x-man-page"]

    @MainActor
    static func register() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.cwandt.knifeterminal"
        var failures = 0
        var detail = ""
        for u in utis {
            let r = LSSetDefaultRoleHandlerForContentType(u as CFString, .all, bundleId as CFString)
            detail += "\(r == 0 ? "ok " : "ERR") uti    \(u)\n"; if r != 0 { failures += 1 }
        }
        for s in schemes {
            let r = LSSetDefaultHandlerForURLScheme(s as CFString, bundleId as CFString)
            detail += "\(r == 0 ? "ok " : "ERR") scheme \(s)\n"; if r != 0 { failures += 1 }
        }
        let alert = NSAlert()
        alert.messageText = failures == 0 ? "Knife Terminal is now the default terminal." : "Some handlers could not be set."
        alert.informativeText = detail + "\nKnife now opens .command/.sh/.tool files, unix executables, and ssh:// / telnet:// links. Folders: right-click → Open With → Knife Terminal."
        alert.runModal()
    }
}

// ─── Recent Claude Code projects (from ~/.claude.json) ───

struct Project: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let t: TimeInterval
}

enum ProjectSection: String, Codable, CaseIterable {
    case starred, active, dormant, archived
}

struct ProjectMeta: Codable, Equatable {
    var starred = false
    var override: ProjectSection? = nil
    var name: String? = nil   // custom display name; folder on disk is untouched
}

enum Projects {
    struct SidebarMeta: Codable {
        var byPath: [String: ProjectMeta] = [:]
        var order: [String: [String]] = [:]
    }

    static func encode(_ p: String) -> String {
        String(p.map { c in c.isLetter || c.isNumber ? c : "-" })
    }

    private static let touchKey = "knife.projectOpened"
    private static let metaKey = "knife.projectMeta"

    static func loadMeta() -> SidebarMeta {
        guard let data = UserDefaults.standard.data(forKey: metaKey),
              let meta = try? JSONDecoder().decode(SidebarMeta.self, from: data) else {
            return SidebarMeta()
        }
        return meta
    }

    static func saveMeta(_ meta: SidebarMeta) {
        var cleaned = meta
        let projects = list()
        let currentPaths = Set(projects.map(\.path))
        cleaned.byPath = cleaned.byPath.filter {
            currentPaths.contains($0.key) && $0.value != ProjectMeta()
        }
        let members = Dictionary(uniqueKeysWithValues: sectioned(projects, meta: cleaned).map {
            ($0.0.rawValue, Set($0.1.map(\.path)))
        })
        var order: [String: [String]] = [:]
        for section in ProjectSection.allCases {
            let key = section.rawValue
            let live = (cleaned.order[key] ?? []).filter { members[key]?.contains($0) == true }
            if !live.isEmpty { order[key] = live }
        }
        cleaned.order = order
        guard let data = try? JSONEncoder().encode(cleaned) else { return }
        UserDefaults.standard.set(data, forKey: metaKey)
    }

    /// Remember that a project was just opened from Knife, so it sorts to the
    /// top immediately (transcript mtimes only catch up once Claude writes).
    static func touch(_ path: String) {
        var d = UserDefaults.standard.dictionary(forKey: touchKey) as? [String: Double] ?? [:]
        d[path] = Date().timeIntervalSince1970
        if d.count > 60 {
            d = Dictionary(uniqueKeysWithValues: Array(d.sorted { $0.value > $1.value }.prefix(40)))
        }
        UserDefaults.standard.set(d, forKey: touchKey)
    }

    /// Directories scanned for projects in addition to whatever Claude Code
    /// has in ~/.claude.json (which only knows dirs `claude` was run in, and
    /// loses recency once transcripts age out of ~/.claude/projects).
    static let codeRoots = ["Code/active", "Code/tools", "Code/experiments", "Code/archive"]

    static func autoSection(_ p: Project, now: TimeInterval = Date().timeIntervalSince1970) -> ProjectSection {
        let archive = NSHomeDirectory() + "/Code/archive/"
        if p.path.hasPrefix(archive) { return .archived }
        return p.t >= now - 30 * 24 * 60 * 60 ? .active : .dormant
    }

    static func sectioned(_ projects: [Project], meta: SidebarMeta) -> [(ProjectSection, [Project])] {
        var grouped = Dictionary(uniqueKeysWithValues: ProjectSection.allCases.map { ($0, [Project]()) })
        for p in projects {
            let saved = meta.byPath[p.path] ?? ProjectMeta()
            let section = saved.starred ? ProjectSection.starred : (saved.override ?? autoSection(p))
            grouped[section, default: []].append(p)
        }
        return ProjectSection.allCases.map { section in
            let members = grouped[section, default: []]
            let byPath = Dictionary(uniqueKeysWithValues: members.map { ($0.path, $0) })
            var seen = Set<String>()
            let ordered = (meta.order[section.rawValue] ?? []).compactMap { path -> Project? in
                guard seen.insert(path).inserted else { return nil }
                return byPath[path]
            }
            let remaining = members.filter { !seen.contains($0.path) }.sorted { $0.t > $1.t }
            return (section, ordered + remaining)
        }
    }

    static func list() -> [Project] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let projDir = (home as NSString).appendingPathComponent(".claude/projects")
        let touched = UserDefaults.standard.dictionary(forKey: touchKey) as? [String: Double] ?? [:]

        var paths = Set<String>()
        if let data = fm.contents(atPath: (home as NSString).appendingPathComponent(".claude.json")),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = cfg["projects"] as? [String: Any] {
            paths.formUnion(projects.keys)
        }
        for root in codeRoots {
            let base = (home as NSString).appendingPathComponent(root)
            for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where !name.hasPrefix(".") {
                paths.insert((base as NSString).appendingPathComponent(name))
            }
        }

        return paths
            .filter { !$0.contains("/.claude-worktrees/") }
            .compactMap { p -> Project? in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
                // most recent activity: newest transcript in ~/.claude/projects
                // (appends bump file mtime, not the dir's), falling back to the
                // project folder's own mtime, or an open from Knife itself
                let enc = (projDir as NSString).appendingPathComponent(encode(p))
                var t: TimeInterval = 0
                for f in (try? fm.contentsOfDirectory(atPath: enc)) ?? [] {
                    if let a = try? fm.attributesOfItem(atPath: (enc as NSString).appendingPathComponent(f)),
                       let m = a[.modificationDate] as? Date {
                        t = max(t, m.timeIntervalSince1970)
                    }
                }
                if t == 0, let a = try? fm.attributesOfItem(atPath: p),
                   let m = a[.modificationDate] as? Date {
                    t = m.timeIntervalSince1970
                }
                t = max(t, touched[p] ?? 0)
                return Project(path: p, name: (p as NSString).lastPathComponent, t: t)
            }
            .sorted { $0.t > $1.t }
    }
}

// ─── Context files: md files Claude Code loads globally / per project ───

struct ContextFile: Identifiable {
    var id: String { path }
    let path: String
    let size: Int
}

enum ContextFiles {
    private static func stat(_ p: String) -> ContextFile? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let size = attrs[.size] as? Int else { return nil }
        return ContextFile(path: p, size: size)
    }

    static func global() -> [ContextFile] {
        let home = NSHomeDirectory()
        return ["/Library/Application Support/ClaudeCode/CLAUDE.md",
                (home as NSString).appendingPathComponent(".claude/CLAUDE.md"),
                (home as NSString).appendingPathComponent(".claude/CLAUDE.local.md")].compactMap(stat)
    }

    static func session(cwd: String?) -> (cwd: String?, files: [ContextFile]) {
        guard let cwd else { return (nil, []) }
        var files: [ContextFile] = []
        var dir = cwd
        for _ in 0..<40 {
            for n in ["CLAUDE.md", "CLAUDE.local.md"] {
                if let f = stat((dir as NSString).appendingPathComponent(n)) { files.append(f) }
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        let mem = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/\(Projects.encode(cwd))/memory/MEMORY.md")
        if let f = stat(mem) { files.append(f) }
        return (cwd, files)
    }
}
