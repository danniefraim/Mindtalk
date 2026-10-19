import SwiftUI

// MARK: - A voice's signature
//
// The voiceprint itself, drawn: a soft closed curve round a centre, its radius at each
// point a stretch of the print's numbers (VoiceMemory: 192 per voice), filled with a
// glow of the speaker's colour and edged with a bright line. The same print gives the
// same curve every time, and two people's look nothing alike — so it is the mark a
// person is known by: large beside the name the moment the round has it, in the
// column "I rummet" after that, small in Settings beside the names Mindtalk
// remembers. Nothing about the voice can be heard back from it: it is a picture of a
// few averages.
//
// In the round it is also seen being made: while someone talks the curve sweeps round
// beside the cloud, drawn from how their voice rises and falls until there is a print
// of it (from a second and a half of speech), and from the print after that. The
// radii morph from one to the other, so it settles into the signature rather than
// switching.

struct VoiceSignature: View {
    enum Size {
        /// Beside a name in a chip (18 pt).
        case compact
        /// A row of "I rummet" (44 pt).
        case room
        /// Beside the cloud while it forms, and in the reveal (72 pt).
        case large

        /// Points on the curve. The room and the reveal share one count: the reveal's
        /// signature lands on the row's and must be the same shape.
        var bars: Int { self == .compact ? 32 : 48 }
        var points: CGFloat {
            switch self {
            case .compact: return 18
            case .room: return 44
            case .large: return 72
            }
        }
        var lineWidth: CGFloat { self == .compact ? 0.8 : 1.2 }
        /// The curve's smallest radius, as a share of the whole: a rounder shape when small.
        var base: CGFloat { self == .compact ? 0.52 : 0.46 }
        /// The glow's blur on a dark surface (none in a chip).
        var glow: CGFloat {
            switch self {
            case .compact: return 0
            case .room: return 6
            case .large: return 8
            }
        }
    }

    /// The radii (0…1), one per point of the size.
    let values: [Double]
    let color: Color
    var size: Size = .compact
    /// How much of the curve is drawn so far (0…1): it sweeps round as it appears.
    var progress: Double = 1
    /// Drawn at another width than the size's (the reveal's signature shrinking into
    /// its row); the line and the glow stay as they are.
    var diameter: CGFloat?
    @Environment(\.colorScheme) private var scheme

    /// The signature of a print.
    init(print: [Float], color: Color, size: Size = .compact, progress: Double = 1, diameter: CGFloat? = nil) {
        self.init(bars: Self.bars(of: print, count: size.bars), color: color, size: size, progress: progress, diameter: diameter)
    }

    /// Radii given directly (the signature forming from the voice's levels).
    init(bars: [Double], color: Color, size: Size = .compact, progress: Double = 1, diameter: CGFloat? = nil) {
        self.values = bars
        self.color = color
        self.size = size
        self.progress = progress
        self.diameter = diameter
    }

    var body: some View {
        // On a light surface (a chip in Settings) ink and grey, no glow; on a dark one
        // the speaker's colour, lit from within.
        let light = scheme == .light
        let line = light ? DS.Colors.ink : color
        let fill = light ? DS.Colors.muted : color
        let radii = AnimatableValues(values)
        let width = diameter ?? size.points
        ZStack {
            Curve(values: radii, base: size.base, progress: progress)
                .fill(RadialGradient(colors: [fill.opacity(light ? 0.3 : 0.35), fill.opacity(0.08)],
                                     center: .center, startRadius: 0, endRadius: width / 2))
            if size != .compact {
                // Depth: a second, smaller curve from the other half of the print.
                Curve(values: radii, base: size.base, progress: progress, inner: true)
                    .stroke(line.opacity(0.2), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
            }
            Curve(values: radii, base: size.base, progress: progress, open: true)
                .stroke(line.opacity(0.9), style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round, lineJoin: .round))
                .shadow(color: light ? .clear : color.opacity(0.35), radius: size.glow)
        }
        .frame(width: width, height: width)
        .accessibilityHidden(true)
    }

    /// The radii (0…1) from a print: the print cut into `count` stretches, the size of
    /// each stretch's numbers, smoothed with its neighbours (three times over, so the
    /// curve rolls rather than spikes), and spread so the smallest is 0 and the largest 1 — the
    /// same print, the same curve.
    static func bars(of print: [Float], count: Int) -> [Double] {
        guard !print.isEmpty, count > 0 else { return [] }
        var raw = (0..<count).map { b -> Double in
            let lo = b * print.count / count, hi = max(lo + 1, (b + 1) * print.count / count)
            guard lo < print.count else { return 0 }
            let slice = print[lo..<min(hi, print.count)]
            return slice.reduce(0.0) { $0 + abs(Double($1)) } / Double(slice.count)
        }
        for _ in 0..<3 {
            raw = raw.indices.map { i in (raw[(i + count - 1) % count] + 2 * raw[i] + raw[(i + 1) % count]) / 4 }
        }
        guard let lo = raw.min(), let hi = raw.max(), hi > lo else { return raw.map { _ in 0.5 } }
        return raw.map { ($0 - lo) / (hi - lo) }
    }

    /// The radii while the signature is forming, from the voice's levels so far (0…1,
    /// one per 20 ms of speech): a full turn is `span` levels, so the curve fills in
    /// step with the round's progress; the points not reached yet are 0 (not drawn).
    /// The radii are the levels as they are, not spread out: a point that has grown
    /// keeps its radius as the next ones come.
    static func bars(fromLevels levels: [Float], span: Int, count: Int) -> [Double] {
        guard count > 0, span > 0 else { return [] }
        let raw = (0..<count).map { b -> Double in
            let lo = b * span / count, hi = max(lo + 1, (b + 1) * span / count)
            guard lo < levels.count else { return 0 }
            let slice = levels[lo..<min(hi, levels.count)]
            return slice.reduce(0.0) { $0 + Double($1) } / Double(slice.count)
        }
        return raw.indices.map { i in
            let before = i > 0 ? raw[i - 1] : raw[i], after = i + 1 < count && raw[i + 1] > 0 ? raw[i + 1] : raw[i]
            return raw[i] > 0 ? (before + 2 * raw[i] + after) / 4 : 0
        }
    }

    /// Radii SwiftUI can animate between: the forming curve settles into the print's
    /// rather than switching to it.
    struct AnimatableValues: VectorArithmetic {
        var values: [Double]
        init(_ values: [Double]) { self.values = values }

        static var zero: AnimatableValues { AnimatableValues([]) }

        static func + (lhs: AnimatableValues, rhs: AnimatableValues) -> AnimatableValues {
            AnimatableValues((0..<max(lhs.values.count, rhs.values.count)).map { i in
                (i < lhs.values.count ? lhs.values[i] : 0) + (i < rhs.values.count ? rhs.values[i] : 0)
            })
        }

        static func - (lhs: AnimatableValues, rhs: AnimatableValues) -> AnimatableValues {
            AnimatableValues((0..<max(lhs.values.count, rhs.values.count)).map { i in
                (i < lhs.values.count ? lhs.values[i] : 0) - (i < rhs.values.count ? rhs.values[i] : 0)
            })
        }

        mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }

        var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
    }

    /// The curve: a smooth closed line (Catmull-Rom through the points) whose radius
    /// at each point is `base` plus its value; `progress` sweeps it round, each point
    /// rising from the base as the sweep passes. `open` draws only the part swept so
    /// far, as a line with a soft end (the outline while forming); `inner` is the
    /// smaller curve inside, read from half a turn on.
    struct Curve: Shape {
        var values: AnimatableValues
        let base: CGFloat
        var progress: Double
        var open = false
        var inner = false
        var animatableData: AnimatablePair<AnimatableValues, Double> {
            get { AnimatablePair(values, progress) }
            set { values = newValue.first; progress = newValue.second }
        }

        func path(in rect: CGRect) -> Path {
            let n = values.values.count
            guard n > 2 else { return Path() }
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = min(rect.width, rect.height) / 2 * (inner ? 0.5 : 1)
            let least = r * base
            let shift = inner ? n / 2 : 0
            // Each point rises as the sweep passes it, over a sixth of the turn. While
            // forming, the first points rise softly too (no step at the top where the
            // sweep began); they fill out as the curve closes.
            let sweep = progress * (1 + 1 / 6.0)
            let closing = min(1, max(0, (progress - 0.8) / 0.2))
            var points: [CGPoint] = []
            var reached = 0
            var whole = true
            for i in 0..<n {
                let at = Double(i) / Double(n)
                let entry = min(1, at * 10) + (1 - min(1, at * 10)) * closing
                let grown = min(1, max(0, (sweep - at) * 6)) * entry
                let v = min(1, max(0, values.values[(i + shift) % n]))
                let radius = least + (r - least) * (0.12 + 0.88 * v) * grown
                let angle = at * 2 * .pi - .pi / 2
                points.append(CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius))
                if grown > 0 { reached = i + 1 }
                if grown < 1 { whole = false }
            }
            if open && !whole { return Self.spline(through: Array(points.prefix(reached)), closed: false) }
            return Self.spline(through: points, closed: true)
        }

        /// A Catmull-Rom spline through the points, as cubic curves.
        static func spline(through p: [CGPoint], closed: Bool) -> Path {
            var path = Path()
            let n = p.count
            guard n > 1 else { return path }
            func at(_ i: Int) -> CGPoint { closed ? p[(i + n) % n] : p[min(max(i, 0), n - 1)] }
            path.move(to: p[0])
            for i in 0..<(closed ? n : n - 1) {
                let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
            if closed { path.closeSubpath() }
            return path
        }
    }

    #if DEBUG
    /// A print for screenshots and self-tests: the same seed, the same numbers, and no
    /// one's voice.
    static func demoPrint(_ seed: String, count: Int = 192) -> [Float] {
        var state = seed.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        var out: [Float] = []
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out.append(Float(Double(state >> 33) / Double(1 << 31)) * 2 - 1)
        }
        let norm = out.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return out.map { $0 / max(norm, 1e-6) }
    }

    /// Levels for screenshots: a voice rising and falling over `count` frames of 20 ms.
    static func demoLevels(_ seed: String, count: Int) -> [Float] {
        let noise = demoPrint(seed, count: count)
        return (0..<count).map { i in
            let t = Double(i) / 50
            let wave = 0.45 + 0.25 * sin(t * 5.3) + 0.15 * sin(t * 13.1 + 1)
            return Float(min(1, max(0.05, wave + Double(noise[i]) * 1.2)))
        }
    }
    #endif
}
