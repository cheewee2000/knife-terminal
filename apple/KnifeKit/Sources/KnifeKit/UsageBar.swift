import Foundation

// The Mac's statusline draws usage-limit bars like "5h ████░░░░░░ 42% (2h30m)"
// in the terminal footer. They ride along in the mirrored screen, so the phone
// and the Mac's chat view lift them back out and render native progress bars.
public struct UsageBar: Identifiable, Sendable {
    public let label: String
    public let pct: Int
    public let reset: String?
    public var id: String { label }

    public var title: String {
        switch label {
        case "5h": return "session · 5 hour window"
        case "wk": return "week · all models"
        default: return "week · \(label)"
        }
    }

    public static func parse(_ styled: Data) -> [UsageBar] {
        guard let screen = StyledScreen.decode(styled) else { return [] }
        let pattern = #/(\S+) ([█░]{10}) (\d{1,3})%(?: \(([^)]+)\))?/#
        var byLabel: [String: UsageBar] = [:]
        var order: [String] = []
        for line in screen.lines {
            let text = line.map(\.t).joined()
            for m in text.matches(of: pattern) {
                let label = String(m.1)
                let bar = UsageBar(label: label, pct: min(100, Int(m.3) ?? 0),
                                   reset: m.4.map(String.init))
                if byLabel[label] == nil { order.append(label) }
                byLabel[label] = bar
            }
        }
        return order.compactMap { byLabel[$0] }
    }
}
