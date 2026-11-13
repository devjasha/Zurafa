import SwiftUI

// The chat's small motions, in Zurafa's iridescent star colors. Each holds still with Reduce Motion.

enum Iris {
    static let pink = Color(red: 1.0, green: 0.62, blue: 0.84)
    static let lavender = Color(red: 0.74, green: 0.64, blue: 1.0)
    static let sky = Color(red: 0.55, green: 0.80, blue: 1.0)
    static let peach = Color(red: 1.0, green: 0.80, blue: 0.62)
    static let colors = [pink, lavender, sky, peach]
}

/// Zurafa's star as the mark of a turn in progress: it turns and breathes while the agent works,
/// and gives a little wiggle every so often while it waits on you.
struct WorkingStar: View {
    let waiting: Bool
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var still

    private struct Pose {
        var angle = 0.0
        var scale = 1.0
    }

    var body: some View {
        let star = Group {
            if let zurafaStar { Image(nsImage: zurafaStar).resizable().scaledToFit() }
            else { Image(systemName: "sparkle").foregroundStyle(Iris.lavender) }
        }
        .frame(width: size, height: size)
        if still {
            star
        } else if waiting {
            star.keyframeAnimator(initialValue: Pose(), repeating: true) { view, pose in
                view.rotationEffect(.degrees(pose.angle)).scaleEffect(pose.scale)
            } keyframes: { _ in
                KeyframeTrack(\.angle) {
                    CubicKeyframe(-16, duration: 0.12)
                    CubicKeyframe(14, duration: 0.16)
                    CubicKeyframe(-8, duration: 0.14)
                    CubicKeyframe(0, duration: 0.14)
                    LinearKeyframe(0, duration: 1.6)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.18, duration: 0.2)
                    SpringKeyframe(1, duration: 0.36)
                    LinearKeyframe(1, duration: 1.6)
                }
            }
        } else {
            star.keyframeAnimator(initialValue: Pose(), repeating: true) { view, pose in
                view.rotationEffect(.degrees(pose.angle)).scaleEffect(pose.scale)
            } keyframes: { _ in
                KeyframeTrack(\.angle) { LinearKeyframe(360, duration: 2.8) }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.14, duration: 1.4)
                    CubicKeyframe(1, duration: 1.4)
                }
            }
        }
    }
}

/// A band of the star's colors sweeping across text, for what the agent is doing right now.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        if still { content } else {
            content
                .overlay {
                    GeometryReader { g in
                        let band = max(g.size.width * 0.45, 40)
                        LinearGradient(colors: [.clear] + Iris.colors + [.clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + phase * (g.size.width + band))
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.9).delay(0.3).repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// A few tiny stars popping out of a point and fading: a turn just finished. Fires on each new `trigger`.
struct SparkleBurst: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var out = false
    @State private var shown = false

    var body: some View {
        ZStack {
            if shown {
                ForEach(0..<6, id: \.self) { i in
                    let angle = Double(i) / 6 * 2 * .pi - .pi / 2
                    Image(systemName: "sparkle")
                        .font(.system(size: i.isMultiple(of: 2) ? 7 : 5, weight: .bold))
                        .foregroundStyle(Iris.colors[i % Iris.colors.count])
                        .offset(x: out ? cos(angle) * 15 : 0, y: out ? sin(angle) * 15 : 0)
                        .scaleEffect(out ? 0.4 : 1.1)
                        .opacity(out ? 0 : 1)
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            guard !still else { return }
            out = false
            shown = true
            withAnimation(.easeOut(duration: 0.7)) { out = true } completion: { shown = false }
        }
    }
}

/// Three dots hopping in turn in the star's colors: a tool call still running.
struct HopDots: View {
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Iris.colors[i]).frame(width: 4.5, height: 4.5)
                    .phaseAnimator(still ? [0.0] : [0.0, -3.5, 0.0]) { dot, y in dot.offset(y: y) } animation: { y in
                        y == 0 ? .easeIn(duration: 0.22).delay(Double(i) * 0.12) : .easeOut(duration: 0.22)
                    }
            }
        }
        .frame(height: 12)
        .accessibilityLabel("Running")
    }
}

extension AnyTransition {
    /// A new chat row: rises a little into place as it fades in.
    static let rise = AnyTransition.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity)
}
