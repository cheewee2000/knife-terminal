import Foundation
import KnifeKit

// Screenshot/demo mode: launched with -knifeDemo the store skips CloudKit and
// shows canned sessions. Extra args steer the first screen so screenshots can
// be captured headlessly from the simulator. Inert in normal launches.
enum DemoData {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-knifeDemo") }
    static var openFirstTab: Bool { ProcessInfo.processInfo.arguments.contains("-knifeDemoOpen") }
    static var showTerminal: Bool { ProcessInfo.processInfo.arguments.contains("-knifeDemoTerminal") }
    static var showUsage: Bool { ProcessInfo.processInfo.arguments.contains("-knifeDemoUsage") }

    static let projects: [ProjectRef] = [
        ProjectRef(name: "spoon-email", path: "/Users/me/GitHub/spoon-email"),
        ProjectRef(name: "polar-pairs", path: "/Users/me/GitHub/polar-pairs"),
        ProjectRef(name: "cwandt.com", path: "/Users/me/GitHub/cwandt.com"),
    ]

    static let tabs: [MirroredTab] = [
        MirroredTab(id: "demo-1", tabId: 1, title: "earth clock", emoji: "🌍",
                    cwd: "/Users/me/GitHub/earth-clock", order: 0, cols: 120, rows: 34,
                    working: true, attention: false,
                    styled: terminalScreen.encoded(), chat: ChatTranscript.encode(chat) ?? Data(),
                    updatedAt: Date().addingTimeInterval(-8)),
        MirroredTab(id: "demo-2", tabId: 2, title: "knife terminal", emoji: "🔪",
                    cwd: "/Users/me/GitHub/knife-terminal", order: 1, cols: 120, rows: 34,
                    working: false, attention: true,
                    styled: terminalScreen.encoded(), chat: ChatTranscript.encode(attentionChat) ?? Data(),
                    updatedAt: Date().addingTimeInterval(-140)),
        MirroredTab(id: "demo-3", tabId: 3, title: "sensor board", emoji: "⚡️",
                    cwd: "/Users/me/GitHub/sensor-board", order: 2, cols: 120, rows: 34,
                    working: false, attention: false,
                    styled: terminalScreen.encoded(), chat: Data(),
                    updatedAt: Date().addingTimeInterval(-2400)),
    ]

    static let chat: [ChatMessage] = [
        ChatMessage(id: "m1", kind: .user, text: "the terminator line looks too sharp — soften the day/night edge"),
        ChatMessage(id: "m2", kind: .tool, text: "Read EarthView.swift"),
        ChatMessage(id: "m3", kind: .assistant, text: "The edge is hard because the shader steps at a single longitude. I'll blend across ~3° with a smoothstep so dusk fades naturally."),
        ChatMessage(id: "m4", kind: .tool, text: "Edit Shaders/Terminator.metal"),
        ChatMessage(id: "m5", kind: .tool, text: "make install-mac"),
        ChatMessage(id: "m6", kind: .assistant, text: "Done — the night side now eases in over a soft twilight band. Built and installed; take a look at dusk over the Pacific."),
        ChatMessage(id: "m7", kind: .user, text: "nice. now dim city lights near the twilight band"),
        ChatMessage(id: "m8", kind: .tool, text: "Edit Shaders/CityLights.metal"),
    ]

    static let attentionChat: [ChatMessage] = [
        ChatMessage(id: "a1", kind: .user, text: "add a usage sheet to the iOS app"),
        ChatMessage(id: "a2", kind: .tool, text: "Read SessionDetailView.swift"),
        ChatMessage(id: "a3", kind: .assistant, text: "Added a gauge button in the toolbar — it parses the statusline bars out of the mirrored screen and renders native progress bars.\n\nShip it as 0.9.37, or fold it into the next release?"),
    ]

    // A believable Claude Code screen, including the footer statusline whose
    // usage bars feed the usage sheet.
    static var terminalScreen: StyledScreen {
        let dim = StyledScreen.styleDim
        var lines: [[TermRun]] = []
        func plain(_ t: String) { lines.append([TermRun(t: t)]) }
        plain("✻ earth clock — soften the day/night terminator")
        plain("")
        lines.append([TermRun(t: "● ", f: 2), TermRun(t: "Read", s: StyledScreen.styleBold), TermRun(t: " EarthView.swift", s: dim)])
        lines.append([TermRun(t: "● ", f: 2), TermRun(t: "Edit", s: StyledScreen.styleBold), TermRun(t: " Shaders/Terminator.metal", s: dim)])
        plain("")
        plain("  The edge is hard because the shader steps at a single")
        plain("  longitude. Blending across ~3° with a smoothstep so")
        plain("  dusk fades naturally.")
        plain("")
        lines.append([TermRun(t: "● ", f: 2), TermRun(t: "Bash", s: StyledScreen.styleBold), TermRun(t: " make install-mac", s: dim)])
        lines.append([TermRun(t: "  ⎿  BUILD SUCCEEDED — installed", s: dim)])
        plain("")
        lines.append([TermRun(t: "✳ Simmering… ", f: 5), TermRun(t: "(34s · ↑ 2.1k tokens · esc to interrupt)", s: dim)])
        plain("")
        lines.append([TermRun(t: "╭──────────────────────────────────────────────╮", s: dim)])
        lines.append([TermRun(t: "│ > ", s: dim), TermRun(t: "dim city lights near the twilight band")])
        lines.append([TermRun(t: "╰──────────────────────────────────────────────╯", s: dim)])
        lines.append([
            TermRun(t: "~/GitHub/earth-clock ", s: dim), TermRun(t: "│ ", s: dim), TermRun(t: "Fable 5 ", s: dim), TermRun(t: "│ ", s: dim),
            TermRun(t: "5h ", s: dim), TermRun(t: "███░░░░░░░ 32% "), TermRun(t: "(2h10m) ", s: dim),
            TermRun(t: "wk ", s: dim), TermRun(t: "█████░░░░░ 54% "), TermRun(t: "(3d) ", s: dim),
            TermRun(t: "Fable ", s: dim), TermRun(t: "██████░░░░ 61% "), TermRun(t: "(4d16h)", s: dim),
        ])
        return StyledScreen(lines: lines)
    }
}
