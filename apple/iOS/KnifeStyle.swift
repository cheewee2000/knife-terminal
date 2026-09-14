import SwiftUI
import UIKit
import CoreText
import KnifeKit

// Chrome type and colors, matching the Mac app: Helvetica Now Text for the UI
// and JetBrains Mono for anything terminal-shaped, with accent / attention /
// background taken from the shared TermTheme and following light/dark.
//
// Helvetica Now is a licensed font and isn't in the repo. Drop
// HelveticaNowText-Regular.otf and HelveticaNowText-Medium.otf into
// apple/Fonts and they ride along in the bundle; without them the UI falls
// back to the system font, the same way the Mac does when the font isn't
// installed.

enum KnifeFonts {
    /// Registers any bundled Helvetica Now files (they're deliberately not
    /// listed under UIAppFonts, so a checkout without them still builds).
    static let helveticaNow: Bool = {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("HelveticaNow") }
        if !urls.isEmpty {
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        }
        return UIFont(name: "HelveticaNowText-Regular", size: 12) != nil
    }()
}

/// UI chrome: rows, labels, buttons, titles.
func ui(_ size: CGFloat, bold: Bool = false) -> Font {
    if KnifeFonts.helveticaNow {
        return Font.custom(bold ? "HelveticaNowText-Medium" : "HelveticaNowText-Regular", size: size)
    }
    return .system(size: size, weight: bold ? .medium : .regular)
}

/// Terminal-shaped text: the mirror, commands, what you type into a shell.
func mono(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "JetBrains Mono Bold" : "JetBrains Mono", size: size)
}

extension TermTheme {
    static func current(_ scheme: ColorScheme) -> TermTheme { scheme == .dark ? .dark : .light }
}

extension TermTheme.RGB {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    var uiColor: UIColor { UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
}
