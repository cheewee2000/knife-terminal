import Foundation

// ─── Chat mirror of a Claude Code session ───
// The Mac parses the tail of the session's ~/.claude/projects/<slug>/*.jsonl
// transcript into these messages and publishes them alongside the styled
// screen; the phone renders them as a conversation (Claude-app style) instead
// of a raw terminal mirror.

public struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case user, assistant, tool }
    public var id: String
    public var kind: Kind
    public var text: String
    /// Tool calls: the full input under the one-line label (whole command,
    /// description, todo list) — never an edit's old/new strings or file content.
    public var detail: String?
    /// Agent turns: the model and reasoning effort that produced it ("opus-5 · high").
    public var model: String?
    /// Claude's multiple-choice questions (AskUserQuestion). `text` carries them as
    /// markdown too, for readers that only show text.
    public var ask: [AskQuestion]?
    /// The picks once answered, question → label(s); empty = dismissed; nil = still waiting.
    public var answers: [String: String]?

    public init(id: String, kind: Kind, text: String, detail: String? = nil, model: String? = nil,
                ask: [AskQuestion]? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.detail = detail; self.model = model; self.ask = ask
    }
}

public struct AskQuestion: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable {
        public var label: String
        public var description: String?
    }
    public var question: String
    public var header: String?
    public var multiSelect: Bool
    public var options: [Option]

    init?(_ q: [String: Any]) {
        guard let question = q["question"] as? String, let opts = q["options"] as? [[String: Any]] else { return nil }
        self.question = question
        header = q["header"] as? String
        multiSelect = q["multiSelect"] as? Bool ?? false
        options = opts.compactMap { o in (o["label"] as? String).map { Option(label: $0, description: o["description"] as? String) } }
    }
}

public enum ChatTranscript {
    public static func encode(_ msgs: [ChatMessage]) -> Data? { try? JSONEncoder().encode(msgs) }
    public static func decode(_ data: Data) -> [ChatMessage]? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode([ChatMessage].self, from: data)
    }

    /// Parse Claude Code transcript lines (one JSON object per line) into chat
    /// messages. Unknown shapes are skipped, never fatal.
    ///
    /// A prompt typed while Claude is mid-turn isn't a `user` record: it's a
    /// queue-operation enqueue, then either dequeued (→ a `user` record at the
    /// next turn) or absorbed into the running turn (→ a `queued_command`
    /// attachment). Absorbed ones become user messages; ones still waiting show
    /// at the end with detail "queued".
    public static func parse(jsonlLines: [String]) -> [ChatMessage] {
        var p = Parser(codex: false); p.feed(jsonlLines); return p.messages
    }

    /// Codex CLI rollout (~/.codex/sessions/Y/M/D/rollout-*.jsonl). The
    /// conversation lives in response_item records; event_msg records repeat
    /// them (agent_message/user_message) and are skipped.
    public static func parseCodex(jsonlLines: [String]) -> [ChatMessage] {
        var p = Parser(codex: true); p.feed(jsonlLines); return p.messages
    }

    /// Incremental: feed lines as the transcript grows (the Mac keeps one per
    /// session and hands it only the new bytes), read `messages` any time.
    public struct Parser: Sendable {
        public let codex: Bool
        private var out: [ChatMessage] = []
        private var queue: [(id: String, text: String)] = [] // FIFO, task notifications included so dequeue stays aligned
        private var turnModel: String? // Codex: from the latest turn_context
        private var askAt: [String: Int] = [:] // AskUserQuestion tool_use id → its message, for the answer

        public init(codex: Bool) { self.codex = codex }

        public mutating func feed(_ lines: [String]) {
            for line in lines { if codex { feedCodex(line) } else { feedClaude(line) } }
        }

        /// Everything so far, prompts still waiting in Claude's queue last.
        public var messages: [ChatMessage] {
            out + queue.compactMap { q in userText(q.text).map { ChatMessage(id: q.id, kind: .user, text: $0, detail: "queued") } }
        }

        private mutating func feedClaude(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return }
        if obj["isMeta"] as? Bool == true { return }
        if obj["isSidechain"] as? Bool == true { return }
        let uuid = obj["uuid"] as? String ?? UUID().uuidString
        if type == "queue-operation" {
            let content = obj["content"] as? String
            switch obj["operation"] as? String {
            case "enqueue": if let content { queue.append(("queued-\(obj["timestamp"] as? String ?? uuid)", content)) }
            case "dequeue": if !queue.isEmpty { queue.removeFirst() }
            case "remove": if let i = queue.firstIndex(where: { $0.text == content }) { queue.remove(at: i) }
            default: break
            }
            return
        }
        if type == "attachment", let a = obj["attachment"] as? [String: Any],
           a["type"] as? String == "queued_command",
           (a["origin"] as? [String: Any])?["kind"] as? String ?? "human" == "human" {
            if let t = userText(a["prompt"]) { out.append(ChatMessage(id: uuid, kind: .user, text: t)) }
            return
        }
        guard let message = obj["message"] as? [String: Any] else { return }

        switch type {
        case "user":
            if let text = userText(message["content"]) {
                out.append(ChatMessage(id: uuid, kind: .user, text: text))
            }
            // a question's result: {"answers": {question: label}}; an error result = dismissed
            for b in message["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "tool_result" {
                guard let useId = b["tool_use_id"] as? String, let i = askAt[useId] else { continue }
                let answers = (obj["toolUseResult"] as? [String: Any])?["answers"] as? [String: String] ?? [:]
                out[i].answers = answers
                out[i].text += answers.isEmpty ? "\n\n(dismissed)"
                    : "\n\n" + answers.map { "→ \($0.value)" }.sorted().joined(separator: "\n")
            }
        case "assistant":
            guard let blocks = message["content"] as? [[String: Any]] else { return }
            let model = modelLabel(message["model"] as? String, obj["effort"] as? String)
            for (i, block) in blocks.enumerated() {
                let id = "\(uuid)-\(i)"
                switch block["type"] as? String {
                case "text":
                    if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !t.isEmpty {
                        out.append(ChatMessage(id: id, kind: .assistant, text: t, model: model))
                    }
                case "tool_use" where block["name"] as? String == "AskUserQuestion":
                    // a question isn't plumbing: shown as Claude talking, with its choices
                    let qs = ((block["input"] as? [String: Any])?["questions"] as? [[String: Any]] ?? []).compactMap(AskQuestion.init)
                    guard !qs.isEmpty else { continue }
                    let md = qs.map { q in
                        "**\(q.header ?? "Question")** · \(q.question)\n" + q.options.enumerated().map { i, o in
                            "\(i + 1). \(o.label)" + (o.description.map { " — \($0)" } ?? "")
                        }.joined(separator: "\n")
                    }.joined(separator: "\n\n")
                    if let useId = block["id"] as? String { askAt[useId] = out.count }
                    out.append(ChatMessage(id: id, kind: .assistant, text: md, model: model, ask: qs))
                case "tool_use":
                    if let name = block["name"] as? String {
                        let input = block["input"] as? [String: Any]
                        out.append(ChatMessage(id: id, kind: .tool, text: toolLabel(name, input),
                                               detail: toolDetail(input), model: model))
                    }
                default: break
                }
            }
        default: break
        }
        }

        private mutating func feedCodex(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let p = obj["payload"] as? [String: Any] else { return }
        if obj["type"] as? String == "turn_context" {
            turnModel = modelLabel(p["model"] as? String, p["effort"] as? String)
            return
        }
        guard obj["type"] as? String == "response_item" else { return }
        let ts = obj["timestamp"] as? String ?? ""
        switch p["type"] as? String {
        case "message":
            let blocks = p["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            // imported sessions share one timestamp: fold the text into the id
            let id = "\(ts)-\(p["role"] as? String ?? "")-\(text.count)-\(text.prefix(24))"
            if p["role"] as? String == "user" {
                if let t = userText(text) { out.append(ChatMessage(id: id, kind: .user, text: t)) }
            } else if let t = Optional(text.trimmingCharacters(in: .whitespacesAndNewlines)), !t.isEmpty {
                out.append(ChatMessage(id: id, kind: .assistant, text: t, model: turnModel))
            }
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = p["name"] as? String ?? "shell"
            var input: [String: Any] = [:]
            if let args = p["arguments"] as? String, let d = args.data(using: .utf8),
               let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { input = j }
            if let action = p["action"] as? [String: Any] { input = action } // local_shell_call
            if var argv = input["command"] as? [String] {
                if argv.count >= 3, argv[1] == "-lc" { argv.removeFirst(2) } // ["bash","-lc","…"]
                input["command"] = argv.joined(separator: " ")
            }
            out.append(ChatMessage(id: p["call_id"] as? String ?? "\(ts)-\(name)", kind: .tool,
                                   text: toolLabel(name, input), detail: toolDetail(input), model: turnModel))
        default: break
        }
        }
    }

    /// User content is either a plain string or an array of blocks; slash
    /// commands arrive wrapped in XML-ish tags, tool results are plumbing.
    private static func userText(_ content: Any?) -> String? {
        var raw: String?
        if let s = content as? String {
            raw = s
        } else if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if !texts.isEmpty { raw = texts.joined(separator: "\n") }
        }
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.hasPrefix("<command-name>") {
            guard let end = t.range(of: "</command-name>") else { return nil }
            let name = String(t[t.index(t.startIndex, offsetBy: "<command-name>".count)..<end.lowerBound])
            let args = t.firstMatch(of: #/<command-args>([\s\S]*?)</command-args>/#).map { String($0.1) } ?? ""
            t = args.isEmpty ? name : name + " " + args
            return name.isEmpty ? nil : t
        }
        if t.hasPrefix("<") { return nil }   // command output, system wrappers
        if t.hasPrefix("# Context from my IDE") { return nil }   // Codex IDE wrapper
        if t.hasPrefix("[Request interrupted") { return nil }
        return t
    }

    /// "claude-opus-5" + "high" → "opus-5 · high"; nil for Claude Code's "<synthetic>" stand-ins.
    static func modelLabel(_ model: String?, _ effort: String?) -> String? {
        guard var m = model, !m.isEmpty, !m.hasPrefix("<") else { return nil }
        if m.hasPrefix("claude-") { m.removeFirst("claude-".count) }
        return [m, effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static let detailKeys = ["description", "command", "file_path", "pattern", "path", "prompt", "url", "query", "skill", "subject"]

    /// Everything the one-line label cut: each known field in full, a todo list
    /// as a checklist. Edit/Write bodies (old_string, new_string, content) are
    /// never among the keys. nil when the label already says it all.
    static func toolDetail(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if let todos = input["todos"] as? [[String: Any]] {
            return todos.map { t in
                let mark = ["completed": "[x]", "in_progress": "[~]"][t["status"] as? String ?? ""] ?? "[ ]"
                return "\(mark) \(t["content"] as? String ?? "")"
            }.joined(separator: "\n")
        }
        var parts = detailKeys.compactMap { input[$0] as? String }.filter { !$0.isEmpty }
        // the label already shows the first field whole unless it was cut
        if let first = parts.first, first.count <= 90, !first.contains("\n") { parts.removeFirst() }
        guard !parts.isEmpty else { return nil }
        let d = parts.joined(separator: "\n")
        return d.count > 1500 ? String(d.prefix(1500)) + "…" : d
    }

    private static func toolLabel(_ name: String, _ input: [String: Any]?) -> String {
        let detail = detailKeys
            .compactMap { input?[$0] as? String }
            .first { !$0.isEmpty }?
            .replacingOccurrences(of: "\n", with: " ")
        guard var d = detail, !d.isEmpty else { return name }
        if d.count > 90 { d = String(d.prefix(90)) + "…" }
        return "\(name) · \(d)"
    }
}
