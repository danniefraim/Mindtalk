import SwiftUI

// Motion shared by the onboarding and the main window. Everything respects
// Reduce Motion: no drifting light, no rising elements, numbers just appear.

// MARK: - Warm glow

/// Soft light drifting slowly behind the paper. Full strength on the onboarding's
/// welcome, a soft wash behind page headers elsewhere.
struct WarmGlow: View {
    let intensity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var active

    var body: some View {
        ZStack {
            DS.Colors.paper
            // It moves slowly (a quarter of a radian a second): ten frames a second is
            // plenty — and none while Mindtalk isn't the app you're in.
            TimelineView(.animation(minimumInterval: 1 / 10, paused: reduceMotion || active == .inactive)) { context in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 0.25
                MeshGradient(width: 3, height: 3, points: Self.points(t), colors: palette)
            }
            .opacity(intensity)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
            .animation(.easeInOut(duration: 0.9), value: intensity)
        }
        .ignoresSafeArea()
    }

    private static func points(_ t: Double) -> [SIMD2<Float>] {
        func f(_ v: Double) -> Float { Float(v) }
        return [
            [0, 0], [f(0.5 + sin(t) * 0.12), 0], [1, 0],
            [0, f(0.45 + cos(t * 0.8) * 0.1)], [f(0.5 + cos(t * 0.7) * 0.18), f(0.5 + sin(t * 0.9) * 0.12)], [1, f(0.4 + sin(t * 1.1) * 0.1)],
            [0, 1], [f(0.5 + sin(t * 0.6) * 0.15), 1], [1, 1],
        ]
    }

    /// Soft silver light — grey tones in light mode, a faint white haze in dark.
    private var palette: [Color] {
        let dark = scheme == .dark
        let paper = DS.Colors.paper
        let a = dark ? Color.white.opacity(0.10) : Color(white: 0.80).opacity(0.55)
        let b = dark ? Color.white.opacity(0.16) : Color(white: 0.72).opacity(0.5)
        let c = dark ? Color.white.opacity(0.07) : Color(white: 0.86).opacity(0.5)
        let d = dark ? Color.white.opacity(0.05) : Color(white: 0.88).opacity(0.35)
        return [
            a, b, c,
            paper, d, paper,
            paper, paper, paper,
        ]
    }
}

// MARK: - Entrances

/// Elements of a page rise into place one after another.
struct Staggered: ViewModifier {
    let index: Int
    let after: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.entrances) private var entrances

    func body(content: Content) -> some View {
        // Once the page has come in, what a lazy list builds again as it scrolls back
        // into view just stands there: it doesn't rise and blur in again.
        let visible = shown || !entrances
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 16)
            .blur(radius: visible || reduceMotion ? 0 : 6)
            .onAppear {
                guard entrances else { return }
                withAnimation(.spring(duration: 0.7, bounce: 0.15).delay(after + Double(index) * 0.08 + 0.1)) { shown = true }
            }
    }
}

extension EnvironmentValues {
    /// Whether elements still rise into place as they appear (`staggered`). A page in
    /// a lazy list turns it off once it has come in.
    @Entry var entrances = true
}

extension View {
    func staggered(_ index: Int, after: Double = 0) -> some View {
        modifier(Staggered(index: index, after: after))
    }
}

// MARK: - Counting numbers

/// A number that counts up to its value (and animates between values).
struct CountingNumber: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Stats.number(Int(value.rounded())))
    }
}

/// Counts from zero to `target` when it first appears.
struct CountUp: View {
    let target: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CountingNumber(value: shown || reduceMotion ? Double(target) : 0)
            .animation(.easeOut(duration: 1.1), value: shown)
            .animation(.snappy(duration: 0.5), value: target)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { shown = true } }
    }
}

// MARK: - Page transitions

/// Pages in the main window rise a little and come into focus.
struct PageShift: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .offset(y: active ? 12 : 0)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
    }
}

extension AnyTransition {
    static var page: AnyTransition {
        .asymmetric(insertion: .modifier(active: PageShift(active: true), identity: PageShift(active: false)),
                    removal: .opacity.animation(.easeOut(duration: 0.12)))
    }
}
