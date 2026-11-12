import SwiftUI

/// A dot that breathes while something is working — the sidebar's, the chat view's, the phone's.
public struct PulseDot: View {
    let color: Color
    let size: CGFloat
    let pulsing: Bool
    @State private var dim = false

    public init(color: Color, size: CGFloat = 7, pulsing: Bool = true) {
        self.color = color; self.size = size; self.pulsing = pulsing
    }

    public var body: some View {
        #if os(macOS)
        // A SwiftUI repeatForever animation re-renders the whole hosting view on
        // the main thread every display frame; a CALayer animation runs in the
        // render server and costs the app nothing.
        PulseLayer(color: NSColor(color), pulsing: pulsing).frame(width: size, height: size)
        #else
        Circle().fill(color).frame(width: size, height: size)
            .opacity(pulsing && dim ? 0.25 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true } }
        #endif
    }
}

#if os(macOS)
private struct PulseLayer: NSViewRepresentable {
    let color: NSColor
    let pulsing: Bool

    func makeNSView(context: Context) -> PulseNSView { PulseNSView() }
    func updateNSView(_ v: PulseNSView, context: Context) {
        v.color = color
        v.pulsing = pulsing
        v.apply()
    }
}

final class PulseNSView: NSView {
    var color: NSColor = .clear
    var pulsing = false

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    // layers drop their animations when they leave the window; put it back on return
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }

    func apply() {
        guard let layer else { return }
        layer.backgroundColor = color.cgColor
        let running = layer.animation(forKey: "pulse") != nil
        if pulsing, window != nil, !running {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.25
            a.duration = 0.9; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: "pulse")
        } else if !pulsing, running {
            layer.removeAnimation(forKey: "pulse")
        }
    }
}
#endif
