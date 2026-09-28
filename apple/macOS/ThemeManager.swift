import AppKit
import SwiftTerm
import KnifeKit

enum ThemeMode: String, CaseIterable { case auto, light, dark }

@MainActor
final class ThemeManager: ObservableObject {
    @Published var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "theme"); apply() }
    }
    @Published var user: UserStyle {
        didSet { UserDefaults.standard.set(user.id, forKey: "userStyle"); apply() }
    }
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        mode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "auto") ?? .auto
        user = UserStyle.named(UserDefaults.standard.string(forKey: "userStyle"))
            ?? .forMachine(username: NSUserName(), fullName: NSFullUserName())
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.restyleAll() }
        }
    }

    var isDark: Bool {
        switch mode {
        case .light: return false
        case .dark: return true
        case .auto: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var current: TermTheme { (isDark ? TermTheme.dark : .light).applying(user, dark: isDark) }

    func cycle() {
        mode = switch mode { case .auto: .light; case .light: .dark; case .dark: .auto }
    }

    func cycleUser() {
        let all = UserStyle.all
        let i = all.firstIndex(of: user) ?? 0
        user = all[(i + 1) % all.count]
    }

    func apply() {
        NSApp.appearance = switch mode {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        restyleAll()
    }

    func restyleAll() {
        let bg = nsColor(current.background)
        for wc in AppModel.shared.windows {
            wc.window?.backgroundColor = bg
            for tab in wc.tabs { style(terminal: tab.view) }
        }
        for m in AppModel.shared.minis {
            m.window?.backgroundColor = bg
            style(terminal: m.term)
        }
        AppModel.shared.objectWillChange.send()
    }

    func nsColor(_ c: TermTheme.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    static func termFont(size: CGFloat) -> NSFont {
        NSFont(name: "Space Mono", size: size)
            ?? NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Subtle tint for ordinary text selection.
    var selectionTint: NSColor { nsColor(current.foreground).withAlphaComponent(isDark ? 0.18 : 0.15) }

    /// Loud highlight for find matches (they render as the selection).
    var findHighlight: NSColor { NSColor.systemYellow.withAlphaComponent(0.6) }

    func style(terminal: KnifeTermView) {
        let t = current
        terminal.stripBold = !user.boldText
        terminal.stripGrey = !user.greyOnBlack && isDark
        let lift = user.greyReplacementHex.map(TermTheme.RGB.init) ?? t.foreground
        terminal.greyLiftFg = (lift.r, lift.g, lift.b)
        terminal.installColors(t.ansi.map { SwiftTerm.Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
        terminal.nativeBackgroundColor = nsColor(t.background)
        terminal.nativeForegroundColor = nsColor(t.foreground)
        terminal.caretColor = nsColor(t.cursor)
        terminal.selectedTextBackgroundColor = terminal.findBarVisible ? findHighlight : selectionTint
        terminal.font = Self.termFont(size: 13 + CGFloat(user.termFontDelta))
        terminal.needsDisplay = true
    }
}
