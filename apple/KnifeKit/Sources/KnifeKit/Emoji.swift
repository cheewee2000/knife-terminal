import Foundation

// Emoji picker: keyword match on the folder name (quick, no network), hash fallback.
// Ported verbatim from the Electron renderer.
public enum Emoji {
    static let keys: [(String, String)] = [
        ("knife|blade|cut|slice", "🔪"), ("terminal|shell|cli|console", "⌨️"), ("clock|time|watch|timer|hour|minute", "⏱️"),
        ("earth|globe|planet|world|geo|map", "🌍"), ("sea|ocean|wave|tide|level|marine", "🌊"), ("sun|solar|light|lamp", "☀️"),
        ("moon|lunar|night|dark", "🌙"), ("star|space|astro|orbit|satellite", "🛰️"), ("rocket|launch", "🚀"),
        ("email|mail|inbox|newsletter", "✉️"), ("invoice|bill|receipt|payment|pay|money|cash|price", "🧾"),
        ("todo|task|list|checklist|reminder", "☑️"), ("calendar|schedule|date|event|fork", "📅"), ("news|press|paper|journal|blog", "📰"),
        ("cms|content|site|web|www|html|page", "🗂️"), ("engrav|laser|etch", "🔆"), ("camera|photo|wink|lens|image|pic", "📷"),
        ("video|film|movie|clip", "🎬"), ("music|song|audio|sound|wav|mp3|spotify|spoon", "🎵"), ("speaker|radio|pager|ring|bell|alert", "🔔"),
        ("game|play|arcade|puzzle|squirrel", "🎮"), ("bot|robot|agent|ai|gpt|llm|claude", "🤖"), ("arb|arbitrage|trade|trading|stock|crypto|market", "📈"),
        ("bunny|rabbit", "🐰"), ("flamingo", "🦩"), ("crow|bird|flight|wing|feather", "🐦‍⬛"), ("mosquito|bug|insect|fly|pest", "🦟"), ("pebble|stone|rock|haptic", "🪨"),
        ("incense|smoke|scent|candle", "🕯️"), ("glasses|eyewear|spec|vision|eye", "👓"), ("titanium|metal|steel|alu|brass|machin|cnc|mill|lathe", "⚙️"),
        ("pcb|schematic|circuit|electronic|board|kicad|easyeda", "🔌"), ("mcp|server|api|proxy|socket|daemon", "🔧"), ("design|figma|ui|ux|system|style|theme|font|type", "🎨"),
        ("art|artwork|archive|gallery|museum|paint|draw|sketch", "🖼️"), ("cad|fusion|3d|model|mesh|print|stl|cadgang", "📐"), ("parts|fast|mcmaster|hardware|tool|supply|stock", "🔩"),
        ("standard|industry|spec|norm", "📏"), ("meditat|zen|calm|breath|mind", "🧘"), ("box|crate|package|case|enclosure", "📦"), ("noodle|ramen|food|eat|kitchen|cook|recipe", "🍜"),
        ("polar|pair|bear|ice|snow|cold|arctic", "🐻‍❄️"), ("academy|school|class|course|learn|teach|study|edu", "🎓"), ("pendant|necklace|jewel|ring|remix", "📿"),
        ("pager|beeper|message|chat|sms|text", "📟"), ("human|person|people|body|health|fit", "🧍"), ("straw|drink|cup|coffee|tea|bar", "🥤"),
        ("proof|life|heart|pulse|alive|check", "💓"), ("moire|pattern|texture|grid|wave", "🌀"), ("tempra|temp|heat|thermo|weather|climate", "🌡️"),
        ("constructor|build|sim|simulation|physics|engine", "🏗️"), ("infinite|loop|forever|endless", "♾️"), ("random|dice|together|chance|shuffle", "🎲"),
        ("dropbox|sync|cloud|backup|drive", "☁️"), ("download|dl|fetch|import", "⬇️"), ("advisor|advice|consult|coach|mentor", "🧭"), ("crouton|bread|toast|bake", "🍞"),
        ("jesus|church|holy|faith|pray", "✝️"), ("tag|barcode|label|qr|scan|sticker", "🏷️"), ("darkball|ball|sphere|orb", "⚫"), ("ios|iphone|mobile|app|swift|xcode", "📱"),
        ("mac|macos|desktop|electron", "🖥️"), ("git|github|repo|code|dev|src", "💻"), ("test|spec|lab|experiment|research", "🧪"), ("doc|docs|note|wiki|readme|write|book", "📓"),
        ("home|house|room|furniture", "🏠"), ("car|auto|vehicle|drive|bike|bicycle", "🚲"), ("plant|garden|tree|leaf|flower|seed", "🌱"), ("dog|puppy|cat|kitten|pet", "🐾"),
        ("fish|shark|whale|squid|octopus", "🐙"), ("fire|flame|burn|hot", "🔥"), ("water|rain|drop|liquid|fluid", "💧"), ("wind|air|fan|breeze", "🌬️"),
        ("key|lock|auth|login|password|secure|vault", "🔑"), ("search|find|query|index", "🔍"), ("data|db|database|sql|table|sheet|csv", "🗄️"), ("chart|graph|plot|dash|analytics|stat", "📊"),
        ("shop|store|cart|commerce|shopify|order|sell", "🛒"), ("ship|deliver|post|parcel|tracking", "📬"), ("phone|call|voice|dial", "📞"), ("printer|print|ink|paper", "🖨️"),
        ("battery|power|charge|volt|energy", "🔋"), ("magnet|mag", "🧲"), ("wire|cable|usb|plug", "🔌"), ("watch|wrist|final", "⌚"), ("pen|pencil|write|draft", "✏️"),
        ("trophy|win|award|best", "🏆"), ("flag|country|nation", "🚩"), ("egg|chick|hatch|gochi|tamagotchi", "🥚"), ("wang|levy|cw|cwandt|cwt", "🔪"),
    ]
    static let fallback = ["🪚", "🔧", "🔩", "⚙️", "🧲", "🧪", "🔬", "🔭", "📐", "📏", "✏️", "📎", "🧷", "🧵", "🪵", "🪨", "🧱", "🔦", "🕯️", "💡", "🔋", "📡", "🛠️", "⚗️", "🧭", "⏱️", "⌛", "🪙", "🎛️", "🎚️", "📻", "🔑", "🪛", "🧰", "📦", "📁", "📓", "🌲", "🌵", "🍄", "🪴", "🌊", "🔥", "❄️", "⚡", "🌑", "🌕", "🐙", "🦀", "🐢", "🦉", "🐋", "🦊", "🐻", "🐚", "🪶", "🍋", "🍎", "🫐", "🧊", "🏔️", "⛺", "🛶", "⛵", "🚲", "🎲", "♟️", "🎯", "🎹", "🥁", "🎸"]

    struct Rule { let prefix: NSRegularExpression; let substring: NSRegularExpression; let emoji: String }
    static let rules: [Rule] = keys.compactMap { k, e in
        guard let p = try? NSRegularExpression(pattern: "^(" + k + ")", options: .caseInsensitive),
              let s = try? NSRegularExpression(pattern: "(" + k + ")", options: .caseInsensitive) else { return nil }
        return Rule(prefix: p, substring: s, emoji: e)
    }

    public static func forPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "🔪" }
        let name = (path as NSString).lastPathComponent
        // split camelCase, then on non-alphanumerics
        var spaced = ""
        var prev: Character? = nil
        for c in name {
            if let p = prev, p.isLowercase, c.isUppercase { spaced.append(" ") }
            spaced.append(c); prev = c
        }
        let tokens = spaced.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var best: String? = nil
        var bestLen = 0
        for (i, t) in tokens.enumerated() {
            let range = NSRange(t.startIndex..., in: t)
            for r in rules {
                var m = r.prefix.firstMatch(in: t, range: range)
                if m == nil, t.count >= 6 { m = r.substring.firstMatch(in: t, range: range) }
                if let m, m.numberOfRanges > 1, let g = Range(m.range(at: 1), in: t) {
                    let len = t.distance(from: g.lowerBound, to: g.upperBound) + (i == 0 ? 3 : 0)
                    if len > bestLen { best = r.emoji; bestLen = len }
                }
            }
        }
        if let best { return best }
        var h: UInt32 = 0
        for u in path.unicodeScalars { h = h &* 31 &+ u.value }
        return fallback[Int(h % UInt32(fallback.count))]
    }
}
