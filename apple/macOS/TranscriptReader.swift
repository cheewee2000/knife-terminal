import Foundation
import KnifeKit

/// Reads a tab's agent session transcript so the chat view and the phone can render
/// the conversation instead of the raw screen. Claude Code writes one JSONL per
/// session under ~/.claude/projects/<cwd-slug>/; Codex CLI under
/// ~/.codex/sessions/Y/M/D/ with the cwd in the first line. A tab's hooks report
/// its exact transcript (TabModel.transcriptPath); without one, the newest
/// transcript for the cwd that no other tab has claimed is what the tab is doing.
///
/// Whole transcripts are parsed, incrementally: each session keeps a parser and
/// its byte offset, so a refresh reads only what was appended. The phone gets
/// the last 50 messages (CloudKit record size); the Mac chat view gets them all.
enum TranscriptReader {
    private typealias Found = (path: String, mtime: Date, codex: Bool)
    private static let maxAge: TimeInterval = 86_400 // a session untouched for a day isn't this tab

    /// Where a tab's chat comes from — read on the main actor, then handed to a reader thread.
    struct Source: Sendable {
        var cwd: String?
        var transcript: String?      // from the tab's hooks
        var claimed: Set<String>     // other tabs' transcripts: never this tab's fallback
    }

    @MainActor static func source(for tab: TabModel, cwd: String?) -> Source {
        let others = AppModel.shared.windows.flatMap(\.tabs).filter { $0 !== tab }.compactMap(\.transcriptPath)
        return Source(cwd: cwd, transcript: tab.transcriptPath, claimed: Set(others))
    }

    static func chatData(_ src: Source) -> Data? {
        chat(src).flatMap { ChatTranscript.encode(Array($0.msgs.suffix(50))) }
    }

    /// Every message of the tab's transcript, plus which agent wrote it.
    static func chat(_ src: Source) -> (msgs: [ChatMessage], codex: Bool)? {
        let best: Found
        if let t = src.transcript, let m = mtime(t) {
            best = (t, m, t.contains("/.codex/"))
        } else {
            guard let cwd = src.cwd, !cwd.isEmpty,
                  let found = [newestClaude(cwd, src.claimed), newestCodex(cwd, src.claimed)].compactMap({ $0 })
                    .max(by: { $0.mtime < $1.mtime }) else { return nil }
            best = found
        }
        return (parsed(best.path, codex: best.codex), best.codex)
    }

    // ─── Incremental parse cache: path → parser + bytes consumed ───

    private struct Cached { var parser: ChatTranscript.Parser; var offset: UInt64; var partial: Data; var used: Date }
    private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    private static func parsed(_ path: String, codex: Bool) -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var c = cache[path] ?? Cached(parser: .init(codex: codex), offset: 0, partial: Data(), used: Date())
        if size < c.offset { c = Cached(parser: .init(codex: codex), offset: 0, partial: Data(), used: Date()) } // rewritten
        if size > c.offset {
            try? fh.seek(toOffset: c.offset)
            var data = c.partial + ((try? fh.readToEnd()) ?? Data())
            c.offset = size
            // hold back a trailing line that isn't finished yet
            if let nl = data.lastIndex(of: 0x0A) {
                c.partial = Data(data[data.index(after: nl)...])
                data = Data(data[..<nl])
            } else {
                c.partial = data
                data = Data()
            }
            let lines = data.split(separator: 0x0A).compactMap { String(data: Data($0), encoding: .utf8) }
            c.parser.feed(lines)
        }
        c.used = Date()
        cache[path] = c
        // ponytail: keeps the 16 most recently read sessions' messages in memory; fine for a tab count
        if cache.count > 16, let old = cache.min(by: { $0.value.used < $1.value.used })?.key { cache[old] = nil }
        return c.parser.messages
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func newestClaude(_ cwd: String, _ claimed: Set<String>) -> Found? {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let dir = NSHomeDirectory() + "/.claude/projects/" + slug
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var newest: Found?
        for name in names where name.hasSuffix(".jsonl") {
            let path = dir + "/" + name
            guard !claimed.contains(path), let m = mtime(path), m.timeIntervalSinceNow > -maxAge else { continue }
            if newest == nil || m > newest!.mtime { newest = (path, m, false) }
        }
        return newest
    }

    private static func newestCodex(_ cwd: String, _ claimed: Set<String>) -> Found? {
        let fm = FileManager.default
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy/MM/dd"
        var newest: Found?
        for day in [Date(), Date().addingTimeInterval(-maxAge)] { // today + yesterday cover maxAge
            let dir = NSHomeDirectory() + "/.codex/sessions/" + fmt.string(from: day)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let path = dir + "/" + name
                guard !claimed.contains(path), let m = mtime(path), m.timeIntervalSinceNow > -maxAge,
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
}
