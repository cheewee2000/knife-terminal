import AppKit
import SwiftUI
import Security

/// How a tab authenticates an agent. Nothing changes until the user picks: `inherit` leaves the
/// shell's environment alone; `plan` strips the agent's API-key variables so its subscription / account
/// login is what runs; `apiKey` injects the key saved in the Keychain.
enum AuthMode: String, CaseIterable {
    case inherit, plan, apiKey
    var label: String { ["inherit": "Shell default", "plan": "Plan sign-in", "apiKey": "API key"][rawValue] ?? rawValue }
}

extension Agent {
    /// Environment variables that carry this agent's API key (plan mode removes them all).
    var keyEnvVars: [String] {
        switch self {
        case .claude: return ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        case .codex: return ["OPENAI_API_KEY"]
        case .gemini: return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .agy: return []
        }
    }
    var supportsAPIKey: Bool { !keyEnvVars.isEmpty }
    var planName: String {
        switch self {
        case .claude: return "Claude subscription (Pro / Max / Team)"
        case .codex: return "ChatGPT plan (Plus / Pro / Team)"
        case .gemini: return "Google account (Gemini Code Assist)"
        case .agy: return "Google account (Antigravity / Gemini plan)"
        }
    }
    /// What the sign-in tab runs; shown with a hint where the CLI itself asks the question.
    var planLogin: (cmd: String, hint: String) {
        switch self {
        case .claude: return ("claude auth login --claudeai", "Opens your browser to sign in with your Claude plan.")
        case .codex: return ("codex login", "Opens your browser to sign in with ChatGPT.")
        case .gemini: return ("gemini", "In the tab choose “Login with Google” (type /auth if it isn't offered).")
        case .agy: return ("agy", "Follow the Google sign-in the first time it starts, then /exit.")
        }
    }
}

@MainActor
enum AgentAuth {
    static func mode(_ a: Agent) -> AuthMode { AuthMode(rawValue: UserDefaults.standard.string(forKey: "auth.\(a.rawValue)") ?? "") ?? .inherit }
    static func setMode(_ a: Agent, _ m: AuthMode) { UserDefaults.standard.set(m.rawValue, forKey: "auth.\(a.rawValue)") }

    /// What the per-agent choices do to an environment: variables to remove, and saved keys to export.
    private static func overrides() -> (unset: [String], set: [String: String]) {
        var unset: [String] = [], set: [String: String] = [:]
        for a in Agent.allCases {
            switch mode(a) {
            case .inherit: continue
            case .plan: unset += a.keyEnvVars
            case .apiKey:
                unset += a.keyEnvVars
                if let v = a.keyEnvVars.first, let k = key(a) { set[v] = k }
            }
        }
        return (unset, set)
    }

    /// Applied to every tab's environment (and so to the debate loop's agents).
    static func apply(to env: inout [String: String]) {
        let o = overrides()
        o.unset.forEach { env[$0] = nil }
        o.set.forEach { env[$0.key] = $0.value }
    }

    /// zsh re-reads the user's startup files in every tab and may export an API key again (a line in
    /// ~/.zshrc), undoing `apply`. So tabs get a wrapper ZDOTDIR: each file sources the user's real one,
    /// then the choice is re-applied — plan mode unsets the key variables, API-key mode sets the saved key.
    static func wrapShell(_ env: inout [String: String], shell: String) {
        guard shell.hasSuffix("zsh") else { return }
        let (unset, set) = overrides()
        guard !unset.isEmpty else { return }
        for (v, k) in set { env["KNIFE_AUTH_VAL_" + v] = k }
        let dir = NSHomeDirectory() + "/.knife/zdotdir", fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let real = #"${KNIFE_REAL_ZDOTDIR:-$HOME}"#
        let reapply = #"""
        for v in ${=KNIFE_AUTH_UNSET}; do unset $v; done
        for v in ${=KNIFE_AUTH_SET}; do eval "export $v=\"\$KNIFE_AUTH_VAL_$v\""; done
        """#
        let files: [String: String] = [
            ".zshenv": ": ${HISTFILE:=\(real)/.zsh_history}\n[ -f \(real)/.zshenv ] && source \(real)/.zshenv\n",
            ".zprofile": "[ -f \(real)/.zprofile ] && source \(real)/.zprofile\n",
            ".zshrc": "[ -f \(real)/.zshrc ] && source \(real)/.zshrc\n\(reapply)\n",
            ".zlogin": "[ -f \(real)/.zlogin ] && source \(real)/.zlogin\n\(reapply)\n",
        ]
        for (name, body) in files {
            let path = dir + "/" + name
            if (try? String(contentsOfFile: path, encoding: .utf8)) != body { try? body.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        // launched from a Knife tab, ZDOTDIR is already the wrapper: keep the inherited real one or .zshrc sources itself
        if env["ZDOTDIR"] != dir || env["KNIFE_REAL_ZDOTDIR"] == nil { env["KNIFE_REAL_ZDOTDIR"] = env["ZDOTDIR"] ?? NSHomeDirectory() }
        env["ZDOTDIR"] = dir
        env["KNIFE_AUTH_UNSET"] = unset.joined(separator: " ")
        env["KNIFE_AUTH_SET"] = set.keys.sorted().joined(separator: " ")
    }

    // ─── Keychain ───
    private static func query(_ a: Agent) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "knife-terminal.api-key", kSecAttrAccount as String: a.rawValue]
    }
    static func key(_ a: Agent) -> String? {
        var q = query(a); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func setKey(_ a: Agent, _ k: String?) {
        SecItemDelete(query(a) as CFDictionary)
        guard let k, !k.isEmpty else { return }
        var q = query(a); q[kSecValueData as String] = Data(k.utf8)
        let st = SecItemAdd(q as CFDictionary, nil)
        if st != errSecSuccess { NSLog("knife: saving the \(a.rawValue) API key failed (OSStatus \(st))") }
    }

    // ─── Status ───
    /// A one-line "who am I signed in as", asking the CLI itself (with the environment this mode gives it).
    static func status(_ a: Agent) async -> String {
        var env = ProcessInfo.processInfo.environment; apply(to: &env)
        let m = mode(a), home = NSHomeDirectory()
        if m == .apiKey { return key(a) != nil ? "API key saved in Keychain" : "No API key saved yet" }
        switch a {
        case .claude:
            let out = await run("claude auth status", env)
            guard let d = out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "Unknown" }
            guard j["loggedIn"] as? Bool == true else { return "Not signed in" }
            let method = j["authMethod"] as? String ?? "?"
            let who = (j["email"] as? String).map { " · \($0)" } ?? ""
            return method == "api_key" ? "Using an API key from the environment\(who)" : "Signed in with \(method)\(who)"
        case .codex:
            let out = await run("codex login status", env)
            return out.split(separator: "\n").first.map(String.init) ?? "Unknown"
        case .gemini:
            if FileManager.default.fileExists(atPath: home + "/.gemini/oauth_creds.json") { return "Signed in with a Google account" }
            return env["GEMINI_API_KEY"] != nil ? "Using GEMINI_API_KEY from the environment" : "Not signed in"
        case .agy:
            return FileManager.default.fileExists(atPath: home + "/.gemini/jetski-standalone-oauth-token") ? "Signed in with a Google account" : "Not signed in"
        }
    }

    nonisolated private static func run(_ cmd: String, _ env: [String: String]) async -> String {
        await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", cmd]; p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }
}

// ─── The window ───

@MainActor
final class AgentAccountsWindow {
    static let shared = AgentAccountsWindow()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Agent Accounts"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: AgentAccountsView())
            w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct AgentAccountsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose how each agent signs in. Nothing changes until you pick: “Shell default” leaves your environment alone. “Plan sign-in” removes API-key variables from new tabs so your subscription login is used. “API key” uses a key stored in your Keychain. Changes apply to tabs opened afterwards.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Agent.allCases, id: \.self) { AgentAccountCard(agent: $0) }
            }.padding(18)
        }
    }
}

struct AgentAccountCard: View {
    let agent: Agent
    @State private var mode: AuthMode
    @State private var status = "Checking…"
    @State private var keyText = ""
    @State private var saved = false

    init(agent: Agent) { self.agent = agent; _mode = State(initialValue: AgentAuth.mode(agent)) }

    private var modes: [AuthMode] { agent.supportsAPIKey ? AuthMode.allCases : [.inherit, .plan] }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(status).font(.callout)
                Picker("", selection: $mode) { ForEach(modes, id: \.self) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: mode) { _, m in AgentAuth.setMode(agent, m); refresh() }
                switch mode {
                case .inherit:
                    Text("Uses whatever your shell provides — including any API key already in your environment.").font(.caption).foregroundStyle(.secondary)
                case .plan:
                    Text("Plan: \(agent.planName). \(agent.planLogin.hint)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Sign in with plan…") { signIn(agent.planLogin.cmd) }
                        if agent == .claude { Button("Sign in with Console (API billing)…") { signIn("claude auth login --console") } }
                    }
                case .apiKey:
                    HStack {
                        SecureField(agent.keyEnvVars[0], text: $keyText).textFieldStyle(.roundedBorder)
                        Button(saved ? "Saved ✓" : "Save") {
                            AgentAuth.setKey(agent, keyText.trimmingCharacters(in: .whitespacesAndNewlines)); keyText = ""; saved = true; refresh()
                        }.disabled(keyText.isEmpty)
                        if AgentAuth.key(agent) != nil { Button("Remove") { AgentAuth.setKey(agent, nil); saved = false; refresh() } }
                    }
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text(agent.label).font(.headline) }
        .task { refresh() }
    }

    private func refresh() { Task { status = await AgentAuth.status(agent) } }

    private func signIn(_ cmd: String) {
        let wc = AppModel.shared.frontWindow() ?? AppModel.shared.newWindow(withTab: false)
        wc.addTab(TabOptions(cwd: NSHomeDirectory(), cmd: cmd, title: "sign in · \(agent.rawValue)"))
        NSApp.activate(ignoringOtherApps: true)
    }
}
