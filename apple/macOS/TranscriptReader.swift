import Foundation
import KnifeKit

/// Reads the tail of a tab's agent session transcript so the phone can render
/// the conversation instead of the raw screen. Claude Code writes one JSONL per
/// session under ~/.claude/projects/<cwd-slug>/; Codex CLI under
/// ~/.codex/sessions/Y/M/D/ with the cwd in the first line. Whichever agent
/// touched a transcript for this cwd most recently is what the tab is doing.
enum TranscriptReader {
    private typealias Found = (path: String, mtime: Date, codex: Bool)
    private static let maxAge: TimeInterval = 86_400 // a session untouched for a day isn't this tab

    static func messages(forCwd cwd: String?, sessionId: String? = nil) -> [ChatMessage] {
        guard let cwd, !cwd.isEmpty else { return [] }
        let best: Found?
        if let id = sessionId, !id.isEmpty {
            let path = claudeDirectory(cwd) + "/" + id + ".jsonl"
            best = FileManager.default.fileExists(atPath: path)
                ? (path, .distantPast, false)
                : newest(forCwd: cwd)
        } else {
            best = newest(forCwd: cwd)
        }
        guard let best else { return [] }
        let lines = tailLines(best.path)
        let msgs = (best.codex ? ChatTranscript.parseCodex(jsonlLines: lines)
                               : ChatTranscript.parse(jsonlLines: lines)).suffix(50)
        return Array(msgs)
    }

    static func chatData(forCwd cwd: String?, sessionId: String? = nil) -> Data? {
        let msgs = messages(forCwd: cwd, sessionId: sessionId)
        return msgs.isEmpty ? nil : ChatTranscript.encode(msgs) // nil = not an agent tab, as before
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func claudeDirectory(_ cwd: String) -> String {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return NSHomeDirectory() + "/.claude/projects/" + slug
    }

    private static func newest(forCwd cwd: String) -> Found? {
        [newestClaude(cwd), newestCodex(cwd)]
            .compactMap { $0 }
            .max(by: { $0.mtime < $1.mtime })
    }

    private static func newestClaude(_ cwd: String) -> Found? {
        let dir = claudeDirectory(cwd)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var newest: Found?
        for name in names where name.hasSuffix(".jsonl") {
            let path = dir + "/" + name
            guard let m = mtime(path), m.timeIntervalSinceNow > -maxAge else { continue }
            if newest == nil || m > newest!.mtime { newest = (path, m, false) }
        }
        return newest
    }

    private static func newestCodex(_ cwd: String) -> Found? {
        let fm = FileManager.default
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy/MM/dd"
        var newest: Found?
        for day in [Date(), Date().addingTimeInterval(-maxAge)] { // today + yesterday cover maxAge
            let dir = NSHomeDirectory() + "/.codex/sessions/" + fmt.string(from: day)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let path = dir + "/" + name
                guard let m = mtime(path), m.timeIntervalSinceNow > -maxAge,
                      newest == nil || m > newest!.mtime,
                      let fh = FileHandle(forReadingAtPath: path) else { continue }
                defer { try? fh.close() }
                // first line is session_meta {"payload":{"cwd":…}}
                guard let head = try? fh.read(upToCount: 4096),
                      let nl = head.firstIndex(of: 0x0A),
                      let meta = (try? JSONSerialization.jsonObject(with: head[..<nl])) as? [String: Any],
                      (meta["payload"] as? [String: Any])?["cwd"] as? String == cwd else { continue }
                newest = (path, m, true)
            }
        }
        return newest
    }

    private static func tailLines(_ path: String) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? fh.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if size > window, !lines.isEmpty { lines.removeFirst() }  // partial first line
        return lines
    }
}
