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

    public init(id: String, kind: Kind, text: String) {
        self.id = id; self.kind = kind; self.text = text
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
    public static func parse(jsonlLines: [String]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for line in jsonlLines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            if obj["isMeta"] as? Bool == true { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            let uuid = obj["uuid"] as? String ?? UUID().uuidString
            guard let message = obj["message"] as? [String: Any] else { continue }

            switch type {
            case "user":
                if let text = userText(message["content"]) {
                    out.append(ChatMessage(id: uuid, kind: .user, text: text))
                }
            case "assistant":
                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                for (i, block) in blocks.enumerated() {
                    let id = "\(uuid)-\(i)"
                    switch block["type"] as? String {
                    case "text":
                        if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !t.isEmpty {
                            out.append(ChatMessage(id: id, kind: .assistant, text: t))
                        }
                    case "tool_use":
                        if let name = block["name"] as? String {
                            out.append(ChatMessage(id: id, kind: .tool, text: toolLabel(name, block["input"] as? [String: Any])))
                        }
                    default: break
                    }
                }
            default: break
            }
        }
        return out
    }

    /// Codex CLI rollout (~/.codex/sessions/Y/M/D/rollout-*.jsonl). The
    /// conversation lives in response_item records; event_msg records repeat
    /// them (agent_message/user_message) and are skipped.
    public static func parseCodex(jsonlLines: [String]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for line in jsonlLines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["type"] as? String == "response_item",
                  let p = obj["payload"] as? [String: Any] else { continue }
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
                    out.append(ChatMessage(id: id, kind: .assistant, text: t))
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
                                       text: toolLabel(name, input)))
            default: break
            }
        }
        return out
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
            t = String(t[t.index(t.startIndex, offsetBy: "<command-name>".count)..<end.lowerBound])
            return t.isEmpty ? nil : t
        }
        if t.hasPrefix("<") { return nil }   // command output, system wrappers
        if t.hasPrefix("# Context from my IDE") { return nil }   // Codex IDE wrapper
        if t.hasPrefix("[Request interrupted") { return nil }
        return t
    }

    private static func toolLabel(_ name: String, _ input: [String: Any]?) -> String {
        let detail = ["description", "command", "file_path", "pattern", "prompt", "url", "query", "skill"]
            .compactMap { input?[$0] as? String }
            .first?
            .replacingOccurrences(of: "\n", with: " ")
        guard var d = detail, !d.isEmpty else { return name }
        if d.count > 90 { d = String(d.prefix(90)) + "…" }
        return "\(name) · \(d)"
    }
}
