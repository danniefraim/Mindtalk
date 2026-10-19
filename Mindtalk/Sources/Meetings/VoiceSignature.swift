import SwiftUI

// MARK: - A voice's signature
//
// The voiceprint itself, drawn: a ring of bars, each one's length a stretch of the
// print's numbers (VoiceMemory: 192 per voice). The same print gives the same
// signature every time, and two people's look nothing alike — so it is the mark a
// person is known by: large beside the name the moment the round has it, small in
// "I rummet" and in Settings beside the names Mindtalk remembers. Nothing about the
// voice can be heard back from it: it is a picture of a few averages.
//
// In the round it is also seen being made: while someone talks it grows bar by bar
// beside the cloud, drawn from how their voice rises and falls until there is a print
// of it (from a second and a half of speech), and from the print after that. The
// bars morph from one to the other, so it settles into the signature rather than
// switching.

struct VoiceSignature: View {
    enum Size {
        /// Beside a name in a row (16–18 pt): fewer bars, or they'd blur together.
        case compact
        /// The moment of the round (56 pt).
        case large

        var bars: Int { self == .compact ? 24 : 64 }
        var points: CGFloat { self == .compact ? 18 : 56 }
        var lineWidth: CGFloat { self == .compact ? 0.8 : 1.3 }
        /// Where the bars start, as a share of the radius: a wider hole when small.
        var hole: CGFloat { self == .compact ? 0.42 : 0.36 }
    }

    /// The bars' lengths (0…1), one per bar of the size.
    let values: [Double]
    let color: Color
    var size: Size = .compact
    /// How much of the ring is drawn so far (0…1): it sweeps round as it appears.
    var progress: Double = 1

    /// The signature of a print.
    init(print: [Float], color: Color, size: Size = .compact, progress: Double = 1) {
        self.init(bars: Self.bars(of: print, count: size.bars), color: color, size: size, progress: progress)
    }

    /// Bars given directly (the signature forming from the voice's levels).
    init(bars: [Double], color: Color, size: Size = .compact, progress: Double = 1) {
        self.values = bars
        self.color = color
        self.size = size
        self.progress = progress
    }

    var body: some View {
        Bars(values: AnimatableValues(values), hole: size.hole, progress: progress)
            .stroke(color, style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round))
            .frame(width: size.points, height: size.points)
            .accessibilityHidden(true)
    }

    /// The bars' lengths (0…1) from a print: the print cut into `count` stretches, the
    /// size of each stretch's numbers, lightly smoothed with its neighbours, and
    /// spread so the smallest is 0 and the largest 1 — the same print, the same bars.
    static func bars(of print: [Float], count: Int) -> [Double] {
        guard !print.isEmpty, count > 0 else { return [] }
        var raw = (0..<count).map { b -> Double in
            let lo = b * print.count / count, hi = max(lo + 1, (b + 1) * print.count / count)
            guard lo < print.count else { return 0 }
            let slice = print[lo..<min(hi, print.count)]
            return slice.reduce(0.0) { $0 + abs(Double($1)) } / Double(slice.count)
        }
        raw = raw.indices.map { i in (raw[(i + count - 1) % count] + 2 * raw[i] + raw[(i + 1) % count]) / 4 }
        guard let lo = raw.min(), let hi = raw.max(), hi > lo else { return raw.map { _ in 0.5 } }
        return raw.map { ($0 - lo) / (hi - lo) }
    }

    /// The bars while the signature is forming, from the voice's levels so far (0…1,
    /// one per 20 ms of speech): a full ring is `span` levels, so the ring fills in
    /// step with the round's progress; the bars not reached yet are 0 (not drawn).
    /// The lengths are the levels as they are, not spread out: a bar that has grown
    /// keeps its length as the next ones come.
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

    /// Bar lengths SwiftUI can animate between: the forming bars settle into the
    /// print's rather than switching to them.
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

    /// The ring of bars, drawn from an inner circle outwards; `progress` sweeps round it.
    struct Bars: Shape {
        var values: AnimatableValues
        let hole: CGFloat
        var progress: Double
        var animatableData: AnimatablePair<AnimatableValues, Double> {
            get { AnimatablePair(values, progress) }
            set { values = newValue.first; progress = newValue.second }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let n = values.values.count
            guard n > 0 else { return path }
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = min(rect.width, rect.height) / 2
            let inner = r * hole
            // Each bar grows as the sweep passes it, over a sixth of the turn.
            let sweep = progress * (1 + 1 / 6.0)
            for (i, v) in values.values.enumerated() {
                let at = Double(i) / Double(n)
                let grown = min(1, max(0, (sweep - at) * 6))
                guard grown > 0 else { continue }
                let angle = at * 2 * .pi - .pi / 2
                let len = (inner + (r - inner) * (0.12 + 0.88 * min(1, max(0, v)))) * grown + inner * (1 - grown)
                let dx = cos(angle), dy = sin(angle)
                path.move(to: CGPoint(x: c.x + dx * inner, y: c.y + dy * inner))
                path.addLine(to: CGPoint(x: c.x + dx * len, y: c.y + dy * len))
            }
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
