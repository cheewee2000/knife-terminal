import Foundation

// ─── A numbered menu Claude Code is showing on screen ───
// Permission prompts ("Bash command … Do you want to proceed? ❯ 1. Yes  2. …  Esc to
// cancel") never reach the transcript, so the chat views read them off the screen.
// A digit answers at once (checked against Claude Code 2.1.278).

public struct ScreenPrompt: Equatable, Sendable {
    public var title: String?
    public var body: [String]
    public var options: [String] // option n is options[n - 1]

    /// The menu at the bottom of `screen`, if one is up: numbered options 1…n (n ≥ 2)
    /// just above an "Esc to …" footer, under a ─── rule.
    public static func parse(_ screen: String) -> ScreenPrompt? {
        var lines = screen.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\u{00a0}", with: " ") }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let footer = lines.indices.last(where: { lines[$0].contains("Esc to ") }),
              footer >= lines.count - 3 else { return nil }
        var opts: [Int: String] = [:]
        var i = footer - 1
        while i >= 0 {
            if let m = lines[i].firstMatch(of: #/^\s*(?:❯\s*)?(\d{1,2})\.\s+(.*\S)/#), let n = Int(m.1) {
                opts[n] = String(m.2)
                if n == 1 { break }
            }
            i -= 1
        }
        guard i >= 0, opts.count >= 2, Set(opts.keys) == Set(1...opts.count) else { return nil }
        var block: [String] = []
        var j = i - 1
        while j >= 0, !isRule(lines[j]) {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { block.insert(t, at: 0) }
            j -= 1
        }
        return ScreenPrompt(title: block.first, body: Array(block.dropFirst()),
                            options: (1...opts.count).map { opts[$0]! })
    }

    private static func isRule(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count >= 10 && t.allSatisfy { $0 == "─" }
    }
}
