import Foundation
import KnifeKit

/// Reads the tail of a tab's Claude Code session transcript so the phone can
/// render the conversation instead of the raw screen. Claude Code writes one
/// JSONL per session under ~/.claude/projects/<cwd-slug>/; the newest one in
/// the tab's project is taken as that tab's session.
enum TranscriptReader {
    static func chatData(forCwd cwd: String?) -> Data? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let dir = NSHomeDirectory() + "/.claude/projects/" + slug
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var newest: (path: String, mtime: Date)?
        for name in names where name.hasSuffix(".jsonl") {
            let path = dir + "/" + name
            guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest!.mtime { newest = (path, mtime) }
        }
        // a session not touched in a day isn't what this tab is doing
        guard let newest, newest.mtime.timeIntervalSinceNow > -86_400 else { return nil }

        guard let fh = FileHandle(forReadingAtPath: newest.path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? fh.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if size > window, !lines.isEmpty { lines.removeFirst() }  // partial first line

        let msgs = ChatTranscript.parse(jsonlLines: lines).suffix(50)
        return ChatTranscript.encode(Array(msgs))
    }
}
