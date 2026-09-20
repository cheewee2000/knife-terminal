import Foundation

// ─── Block-level Markdown for chat replies ───
// AttributedString's markdown parser handles inline syntax (bold, code, links)
// but a SwiftUI Text flattens its blocks, so replies are split into these
// blocks first: headings, fenced code, list items (with nesting), quotes,
// rules, tables, paragraphs. Each block's text is still inline markdown.

public enum ChatBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case code([String])
    case item(depth: Int, marker: String, text: String)
    case quote(String)
    case rule
    case table([[String]])
    case text(String)
}

public enum ChatMarkdown {
    public static func blocks(_ md: String) -> [ChatBlock] {
        var out: [ChatBlock] = []
        var para: [String] = []
        var table: [[String]] = []
        var code: [String]?

        func flushPara() { if !para.isEmpty { out.append(.text(para.joined(separator: "\n"))); para = [] } }
        func flushTable() { if !table.isEmpty { out.append(.table(table)); table = [] } }

        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if line.hasPrefix("```") { out.append(.code(code!)); code = nil } else { code!.append(raw) }
                continue
            }
            if line.hasPrefix("|") {
                flushPara()
                if line.allSatisfy({ "|-: ".contains($0) }) { continue } // |---|:--| separator
                table.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            }
            flushTable()
            if line.hasPrefix("```") { flushPara(); code = []; continue }
            if line.isEmpty { flushPara(); continue }
            if let m = line.firstMatch(of: #/^(#{1,6})\s+(.+)$/#) {
                flushPara(); out.append(.heading(level: m.1.count, text: String(m.2)))
            } else if line.count >= 3, let c = line.first, "-*_".contains(c), line.allSatisfy({ $0 == c || $0 == " " }) {
                flushPara(); out.append(.rule)
            } else if let m = raw.firstMatch(of: #/^([ \t]*)([-*+]|\d+[.)])\s+(.+)$/#) {
                flushPara()
                let indent = m.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let marker = m.2.first!.isNumber ? String(m.2) : "•"
                out.append(.item(depth: indent / 2, marker: marker, text: String(m.3)))
            } else if line.hasPrefix(">") {
                flushPara(); out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        flushPara(); flushTable()
        if let code { out.append(.code(code)) } // unterminated fence (reply still streaming)
        return out
    }
}
