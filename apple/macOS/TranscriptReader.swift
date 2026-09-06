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

    static func chatData(forCwd cwd: String?) -> Data? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let candidates = [newestClaude(cwd), newestCodex(cwd)].compactMap { $0 }
        guard let best = candidates.max(by: { $0.mtime < $1.mtime }) else { return nil }
        let lines = tailLines(best.path)
        let msgs = (best.codex ? ChatTranscript.parseCodex(jsonlLines: lines)
                               : ChatTranscript.parse(jsonlLines: lines)).suffix(50)
        return ChatTranscript.encode(Array(msgs))
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func newestClaude(_ cwd: String) -> Found? {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let dir = NSHomeDirectory() + "/.claude/projects/" + slug
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
