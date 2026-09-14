import AppKit
import SwiftUI
import SwiftTerm
import KnifeKit

enum ThemeMode: String, CaseIterable { case auto, light, dark }

@MainActor
final class ThemeManager: ObservableObject {
    @Published var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "theme"); apply() }
    }
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        mode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "auto") ?? .auto
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

    var current: TermTheme { isDark ? .dark : .light }

    func cycle() {
        mode = switch mode { case .auto: .light; case .light: .dark; case .dark: .auto }
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

    var accent: NSColor { nsColor(current.accent) }
    var attention: NSColor { nsColor(current.attention) }
    var accentColor: SwiftUI.Color { Color(nsColor: accent) }
    var attentionColor: SwiftUI.Color { Color(nsColor: attention) }

    static func termFont(size: CGFloat) -> NSFont {
        NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont(name: "Space Mono", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Subtle tint for ordinary text selection.
    var selectionTint: NSColor { nsColor(current.foreground).withAlphaComponent(isDark ? 0.18 : 0.15) }

    /// Loud highlight for find matches (they render as the selection).
    var findHighlight: NSColor { NSColor.systemYellow.withAlphaComponent(0.6) }

    func style(terminal: KnifeTermView) {
        let t = current
        terminal.installColors(t.ansi.map { SwiftTerm.Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
        terminal.nativeBackgroundColor = nsColor(t.background)
        terminal.nativeForegroundColor = nsColor(t.foreground)
        terminal.caretColor = nsColor(t.cursor)
        terminal.selectedTextBackgroundColor = terminal.findBarVisible ? findHighlight : selectionTint
        terminal.font = Self.termFont(size: 13)
        terminal.refreshLinkOverlay()
        terminal.needsDisplay = true
    }
}
