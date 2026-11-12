import AppKit
import SwiftTerm
import KnifeKit

struct TabOptions {
    var cwd: String?
    var cmd: String?
    var title: String?       // fixed title (project name, "man ls", …) — OSC titles don't override it
    var shownTitle: String?   // restored display title
    var restoreCmd: String?
    var guest: String?       // a session shared with us (collaborative mode): mirrored tab id, no local process
}

@MainActor
final class TabModel: NSObject, ObservableObject, Identifiable {
    let id: Int
    let view: KnifeTermView
    @Published var emoji: String
    let opts: TabOptions
    @Published var title: String
    @Published var working = false
    @Published var attention = false
    var limited = false        // the turn ended on a usage limit (StopFailure rate_limit)
    var sessionId: String?     // claude's session, from its hooks — restore resumes exactly this one
    var transcriptPath: String? // the agent's live transcript, from its hooks — the chat view reads exactly this one
    var lastReply: String?     // claude's last message at Stop, for the push
    var cols = 80
    var rows = 25
    var lastReportedCwd: String? // OSC 7, when the shell emits it

    var shellPid: pid_t { view.process?.shellPid ?? 0 }

    /// Current working directory of the shell, for session restore + context files.
    var currentCwd: String? {
        let pid = shellPid
        guard pid > 0 else { return lastReportedCwd }
        return Self.cwdOf(pid: pid) ?? lastReportedCwd
    }

    /// The kernel knows the shell's cwd: proc_pidinfo costs microseconds where
    /// spawning lsof costs ~100ms. lsof stays as the fallback.
    nonisolated static func cwdOf(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size {
            let s = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if !s.isEmpty { return s }
        }
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

        var env = Self.shellEnvironment()
        env["KNIFE_TAB"] = String(id)
        let envList = env.map { "\($0.key)=\($0.value)" }

        let shell = Self.userShell()
        var cwd = opts.cwd ?? NSHomeDirectory()
        if !FileManager.default.fileExists(atPath: cwd) { cwd = NSHomeDirectory() }
        if opts.guest == nil {
            view.startProcess(executable: shell, args: ["-l"], environment: envList, execName: nil, currentDirectory: cwd)
        }
        if let cmd = opts.cmd, opts.guest == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.view.send(txt: cmd + "\r")
            }
        }
        view.onUserInput = { [weak self] in
            guard let self else { return }
            self.limited = false
            if self.askIdle != nil { self.armAsk() } // a key while a question is up restarts its idle clock
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
            if self.sessionPid == 0 { self.sessionPid = self.shellPid } // remembered for terminate(), when the shell may already be gone
            AppModel.shared.sync?.tabOutput(self)
        }
    }

    /// What a shell we start inherits, for tabs and mini terminals alike: the launcher's
    /// terminal identity scrubbed (launched from Ghostty the app inherits
    /// TERM_PROGRAM=ghostty, GHOSTTY_*, and a TERMINFO with only xterm-ghostty —
    /// shell integrations keyed on those would misfire).
    static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && !$0.key.hasPrefix("GHOSTTY_") }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "KnifeTerminal"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        env["TERMINFO"] = nil
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    nonisolated static func userShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell, let s = String(validatingUTF8: sh), !s.isEmpty { return s }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Everything started in this tab is in the shell's session, even helpers that
    /// were reparented to launchd. SwiftTerm only signals the shell, so a helper
    /// that never handles SIGHUP (a busy-looping MCP server) outlives the tab.
    /// Session, not tty: once the shell exits the kernel detaches the tty from
    /// what it left behind, but the session id stays.
    private var sessionPid: pid_t = 0
    static func pids(inSession sid: pid_t) -> [pid_t] {
        guard sid > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return buf.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.size).filter { $0 > 0 && getsid($0) == sid }
    }

    func terminate() {
        if sessionPid == 0 { sessionPid = shellPid }
        Self.terminate(view.process, session: sessionPid)
    }

    /// Hang up a shell and make sure nothing it started outlives it (tabs and mini terminals).
    static func terminate(_ process: LocalProcess?, session sid: pid_t) {
        let left = pids(inSession: sid)
        process?.terminate()
        guard !left.isEmpty else { return }
        // Give them 2s to exit on SIGHUP, then SIGKILL whatever is left. A
        // detached sh, so the sweep still runs when the app itself is quitting.
        // ponytail: kills by pid after 2s (pid reuse is theoretically possible), and
        // takes nohup'd jobs with it; re-check the session per pid if either ever bites.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; kill -9 \(left.map(String.init).joined(separator: " ")) 2>/dev/null"]
        try? p.run()
    }

    // ─── Question auto-continue: an AskUserQuestion nobody touches for `questionTimeout` seconds
    // (default 300; `defaults write com.cwandt.knifeterminal questionTimeout -float 0` turns it off)
    // takes its first option — the recommended one — like Claude Code's own idle timeout, which
    // never runs under Remote Control. Only a picker whose options end in "Chat about this" is
    // answered, so permission prompts are never touched.
    private var askIdle: DispatchWorkItem?
    private var askPending = false
    @Published var askDeadline: Date? // when the pending question auto-picks; the footer counts down to it
    static var questionTimeout: TimeInterval { UserDefaults.standard.object(forKey: "questionTimeout") as? Double ?? 300 }

    func askStarted() { askPending = true; armAsk() }
    func askEnded() { askPending = false; askIdle?.cancel(); askIdle = nil; askDeadline = nil }

    private func armAsk() {
        askIdle?.cancel(); askDeadline = nil
        guard askPending, Self.questionTimeout > 0 else { return }
        let w = DispatchWorkItem { [weak self] in self?.askIdle = nil; self?.askDeadline = nil; self?.autoAnswer(ticks: 6, last: nil) }
        askIdle = w
        askDeadline = Date(timeIntervalSinceNow: Self.questionTimeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.questionTimeout, execute: w)
    }

    /// 1 picks the first option (a lone single-select submits on it); a later question or the
    /// review screen follows a second later, where 1 picks or submits again. ponytail: a
    /// multi-select question shows the same title after the toggle, so the loop stops there.
    private func autoAnswer(ticks: Int, last: String?) {
        guard askPending, ticks > 0, let p = ScreenPrompt.parse(view.plainScreen()),
              p.options.last?.hasPrefix("Chat about this") == true || p.options.first == "Submit answers", // the review screen
              p.title != last else { return }
        view.send(txt: "1")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.autoAnswer(ticks: ticks - 1, last: p.title) }
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
