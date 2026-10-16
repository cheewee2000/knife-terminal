import SwiftUI

/// A dot that breathes while something is working — the sidebar's, the chat view's, the phone's.
public struct PulseDot: View {
    let color: Color
    let size: CGFloat
    @State private var dim = false

    public init(color: Color, size: CGFloat = 7) { self.color = color; self.size = size }

    public var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(dim ? 0.25 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true } }
    }
}
