import AppKit
import SwiftTerm
import KnifeKit

struct TabOptions {
    var cwd: String?
    var cmd: String?
    var title: String?       // fixed title (project name, "man ls", …) — OSC titles don't override it
    var shownTitle: String?   // restored display title
    var restoreCmd: String?
}

enum TabStatus {
    case idle, working, ready, needsInput

    /// Sidebar grouping: the ones that want you first.
    static let sidebarOrder: [TabStatus] = [.needsInput, .working, .ready, .idle]
    var sidebarLabel: String {
        switch self {
        case .needsInput: "needs input"
        case .working: "working"
        case .ready: "ready"
        case .idle: "idle"
        }
    }
}

@MainActor
final class TabModel: NSObject, ObservableObject, Identifiable {
    let id: Int
    let view: KnifeTermView
    let emoji: String
    let opts: TabOptions
    @Published var title: String
    @Published var working = false
    @Published var attention = false
    @Published var status: TabStatus = .idle
    var cols = 80
    var rows = 25
    var lastReportedCwd: String? // OSC 7, when the shell emits it
    /// Claude Code session running in this tab, learned from hook payloads
    /// (every hook carries `session_id`); cleared on SessionEnd.
    var claudeSessionId: String?

    var shellPid: pid_t { view.process?.shellPid ?? 0 }

    /// Agent process alive under this tab's shell right now, if any.
    var runningAgent: String? {
        let pid = shellPid
        return pid > 0 ? Self.runningAgent(underShell: pid) : nil
    }

    var claudeRunning: Bool { runningAgent == "claude" }

    /// `pgrep -lfP <shell>` lists direct children as "<pid> <full command>";
    /// agents run as direct children of the shell whether typed or launched by us.
    nonisolated static func runningAgent(underShell pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-lfP", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") {
            guard let sp = line.firstIndex(of: " ") else { continue }
            let cmd = line[line.index(after: sp)...]
            let exe = cmd.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let name = (exe as NSString).lastPathComponent
            if name == "claude" || name == "codex" { return name }
        }
        return nil
    }

    /// Current working directory of the shell, for session restore + context files.
    var currentCwd: String? {
        let pid = shellPid
        guard pid > 0 else { return lastReportedCwd }
        return Self.cwdOf(pid: pid) ?? lastReportedCwd
    }

    /// The kernel knows the shell's cwd; asking it costs microseconds, where
    /// spawning lsof costs ~100ms — and the board probes every tab every tick.
    nonisolated static func cwdOf(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, Int32(PROC_PIDVNODEPATHINFO), 0, &info, size) == size {
            var path = info.pvi_cdir.vip_path
            let s = withUnsafeBytes(of: &path) { raw in
                raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
            }
            if !s.isEmpty { return s }
        }
        return cwdViaLsof(pid: pid)
    }

    nonisolated static func cwdViaLsof(pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    init(id: Int, opts: TabOptions) {
        self.id = id
        self.opts = opts
        self.emoji = opts.cwd != nil ? Emoji.forPath(opts.cwd) : "🔪"
        self.title = opts.shownTitle ?? opts.title ?? (opts.cwd.map { ($0 as NSString).lastPathComponent } ?? "shell \(id)")
        self.view = KnifeTermView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.processDelegate = self
        AppModel.shared.theme.style(terminal: view)

        var env = Self.shellEnv()
        env["KNIFE_TAB"] = String(id)
        let envList = env.map { "\($0.key)=\($0.value)" }

        let shell = Self.userShell()
        var cwd = opts.cwd ?? NSHomeDirectory()
        if !FileManager.default.fileExists(atPath: cwd) { cwd = NSHomeDirectory() }
        view.startProcess(executable: shell, args: ["-l"], environment: envList, execName: nil, currentDirectory: cwd)

        if let cmd = opts.cmd {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.view.send(txt: cmd + "\r")
            }
        }
        view.onUserInput = { [weak self] in
            guard let self else { return }
            self.status = .idle
            if self.working || self.attention {
                self.working = false; self.attention = false
                AppModel.shared.tabStateChanged(self)
            }
        }
        view.onBell = { [weak self] in
            guard let self else { return }
            AppModel.shared.bellRang(in: self)
        }
        view.onOutput = { [weak self] in
            guard let self else { return }
            AppModel.shared.sync?.tabOutput(self)
        }
    }

    static func userShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell, let s = String(validatingUTF8: sh), !s.isEmpty { return s }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Environment for spawned shells. The app inherits the environment of
    /// whatever launched it (Finder, Xcode, another terminal) — launched from
    /// Ghostty it carries TERM_PROGRAM=ghostty, GHOSTTY_*, and a TERMINFO that
    /// only has xterm-ghostty entries, and shell integrations keyed on those
    /// would think they're in Ghostty. Scrub the host's identity and set ours.
    static func shellEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CLAUDE_CODE_") && !$0.key.hasPrefix("GHOSTTY_")
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "KnifeTerminal"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        env["TERMINFO"] = nil
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    func terminate() {
        view.process?.terminate()
    }
}

extension TabModel: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cols = newCols; self.rows = newRows
            AppModel.shared.sync?.tabOutput(self)
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.opts.title == nil, !title.isEmpty {
                self.title = title
                AppModel.shared.tabStateChanged(self)
            }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async { [weak self] in
            if let directory, let url = URL(string: directory), url.isFileURL { self?.lastReportedCwd = url.path }
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            AppModel.shared.processExited(tabId: self.id)
        }
    }
}
