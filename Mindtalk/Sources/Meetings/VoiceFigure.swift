import AppKit
import SwiftUI

// MARK: - A voice's own figure
//
// Every voice gets a figure of its own: a closed curve in space (a Lissajous knot)
// whose two rhythms and turns come from the voiceprint (VoiceMemory: 192 numbers per
// voice) — the same person, the same figure, every time. In the introduction round
// a cloud of light falls into it (Constellation); in a meeting and in Settings a
// small drawing of it sits beside the name. A voice Mindtalk doesn't remember (or
// with voice recognition off) gets a figure from its number instead — nothing about
// the voice itself is used then.

struct VoiceFigure: Codable, Hashable {
    /// The two rhythms: how many times the curve swings across and up.
    var a: Int
    var b: Int
    /// How the swings are offset, and how the curve turns in depth.
    var phase: Double
    var depth: Double

    /// How far depth may drift from height: much more, and the loop flattens into a line.
    private static let maxDepth = 0.6

    /// Coprime pairs, so every figure is one unbroken loop.
    private static let rhythms = [(3, 2), (5, 4), (2, 3), (4, 3), (3, 4), (5, 2), (2, 5), (4, 5), (5, 3), (3, 5)]

    /// The point at `u` (0…1 around the loop), inside a unit cube.
    func point(_ u: Double) -> SIMD3<Double> {
        let w = u * 2 * .pi
        return SIMD3(sin(Double(a) * w + phase) * 0.95, sin(Double(b) * w) * 0.8, cos(Double(b) * w + depth) * 0.5)
    }

    /// The figure's rhythm as one number, to tell figures apart (3 and 2 → 32).
    var rhythm: Int { a * 10 + b }

    /// From a voiceprint: the rhythm from where its energy lies — the strongest one
    /// no one in `taken` has, so people you know look different — and the offsets
    /// from two smooth projections of the print.
    static func from(print: [Float], avoiding taken: Set<Int> = []) -> VoiceFigure {
        guard print.count >= rhythms.count * 4 else { return from(seed: "?") }
        let size = print.count / rhythms.count
        let energy = (0..<rhythms.count).map { g in print[(g * size)..<((g + 1) * size)].reduce(Float(0)) { $0 + $1 * $1 } }
        let ranked = energy.indices.sorted { energy[$0] > energy[$1] }
        let pick = ranked.first { !taken.contains(rhythms[$0].0 * 10 + rhythms[$0].1) } ?? ranked[0]
        func angle(_ f: Double) -> Double {
            var s = 0.0, c = 0.0
            for (i, v) in print.enumerated() { s += Double(v) * sin(Double(i) * f); c += Double(v) * cos(Double(i) * f) }
            return atan2(s, c)
        }
        return VoiceFigure(a: rhythms[pick].0, b: rhythms[pick].1, phase: angle(0.37), depth: angle(0.91) / .pi * maxDepth)
    }

    /// The average of several prints — steadier than any one recording.
    static func mean(_ prints: [[Float]]) -> [Float]? {
        guard let first = prints.first else { return nil }
        var mean = [Float](repeating: 0, count: first.count)
        for p in prints where p.count == first.count { for i in p.indices { mean[i] += p[i] } }
        return mean
    }

    /// From anything else (the speaker's number): the same seed, the same figure.
    static func from(seed: String) -> VoiceFigure {
        var state = seed.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
        let pick = rhythms[Int(next() * Double(rhythms.count)) % rhythms.count]
        return VoiceFigure(a: pick.0, b: pick.1, phase: next() * 2 * .pi, depth: (next() * 2 - 1) * maxDepth)
    }

    /// The person's figure, if Mindtalk remembers their voice — chosen when the voice
    /// was first saved, and kept for good.
    @MainActor static func remembered(_ name: String) -> VoiceFigure? {
        #if DEBUG
        // Screenshots: the demo meeting's people are "remembered" without real voices.
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if CommandLine.arguments.contains("--demo-meeting"), ["anna", "erik"].contains(key) { return from(seed: key) }
        #endif
        guard VoiceMemory.shared.enabled else { return nil }
        return VoiceMemory.shared.figure(of: name)
    }
}

// MARK: - The figure drawn as a line

/// The voice's figure as one continuous line in space: the very curve the cloud
/// falls into (the same points, the same perspective), drawn sharp at any size. The
/// line is thicker and brighter where the curve comes nearer, thinner and fainter
/// where it goes behind, so the loop reads as a shape in depth; on a dark surface it
/// glows faintly in the voice's colour. It turns slowly, each one in its own time
/// (not with the others in a column) — still with Reduce Motion and in a picture.
struct VoiceFigureView: View {
    enum Size {
        /// Beside a name in a chip or a transcript (18 pt): still, no glow.
        case compact
        /// A row of "I rummet" (56 pt).
        case room
        /// Beside the name the moment the round has it (96 pt).
        case large

        var points: CGFloat {
            switch self {
            case .compact: return 18
            case .room: return 56
            case .large: return 96
            }
        }
        /// Points sampled along the loop: enough that the line is smooth at the size.
        var samples: Int { self == .compact ? 120 : self == .room ? 200 : 280 }
        /// The glow's blur on a dark surface (none in a chip).
        var glow: CGFloat { self == .compact ? 0 : self == .room ? 6 : 10 }
    }

    let figure: VoiceFigure
    let color: Color
    var size: Size = .room
    /// Drawn at another width than the size's (the reveal's figure shrinking into its
    /// row); the line scales with it.
    var diameter: CGFloat?
    /// Where in its turn the figure starts (radians): a column's figures each at
    /// their own angle. nil: from the figure itself.
    var phase: Double?
    /// Not turning (off screen, or a still picture).
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// One turn in fourteen seconds.
    static let turn = 2 * Double.pi / 14
    /// The eye's distance, as in the cloud (Constellation).
    static let eye = 2.6

    var body: some View {
        let still = size == .compact || paused || reduceMotion || Self.rendering
        let width = diameter ?? size.points
        let start = phase ?? Self.phase(of: figure)
        Group {
            if still {
                Canvas { ctx, size in draw(&ctx, size: size, angle: start) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 14)
                    Canvas { ctx, size in draw(&ctx, size: size, angle: start + t * Self.turn) }
                }
            }
        }
        .frame(width: width, height: width)
        .accessibilityHidden(true)
    }

    /// A still picture (`--render-…`): nothing turns.
    private static var rendering: Bool {
        #if DEBUG
        return Demo.rendering
        #else
        return false
        #endif
    }

    /// A figure's own starting angle: two figures seldom stand alike.
    static func phase(of figure: VoiceFigure) -> Double {
        (figure.phase * 1.7 + figure.depth * 3.1 + Double(figure.rhythm) * 0.37).truncatingRemainder(dividingBy: 2 * .pi)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, angle: Double) {
        let n = self.size.samples
        let half = min(size.width, size.height) / 2
        // The line's weight grows with the size, slower than the size itself: 0.8…1.6 pt
        // at 44 pt, 1.3…2.6 at 96 — large, it stays a line, not a band.
        let weight = 0.55 + half / 44
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        // As large as the frame allows at every angle: the figure's widest reach, seen
        // from all sides, just inside the edge (the glow needs a little room).
        let r = half * (self.size == .compact ? 0.94 : 0.86) / Self.reach(of: figure)
        let cr = cos(angle), sr = sin(angle)
        var pts = [CGPoint](repeating: .zero, count: n)
        var zs = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let p = figure.point(Double(i) / Double(n))
            let x = p.x * cr + p.z * sr, z = -p.x * sr + p.z * cr, f = Self.eye / (Self.eye + z)
            pts[i] = CGPoint(x: c.x + x * r * f, y: c.y + p.y * r * f)
            zs[i] = z
        }

        // On a light surface (a chip in Settings) ink, no glow; on a dark one the
        // voice's colour, lit from within.
        let light = scheme == .light
        let line = light && self.size == .compact ? DS.Colors.ink : color
        if !light, self.size.glow > 0 {
            var whole = Path()
            whole.move(to: pts[0])
            for i in 1..<n { whole.addLine(to: pts[i]) }
            whole.closeSubpath()
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: self.size.glow))
                layer.stroke(whole, with: .color(color.opacity(0.35)),
                             style: StrokeStyle(lineWidth: weight * 2.4, lineCap: .round, lineJoin: .round))
            }
        }

        // The loop in short pieces, the farthest drawn first, each with the weight
        // and the light of its depth: nearer is thicker and brighter.
        let piece = 4
        let count = n / piece
        var order = Array(0..<count)
        order.sort { zs[$0 * piece] > zs[$1 * piece] }
        for s in order {
            var path = Path()
            path.move(to: pts[s * piece])
            for k in 1...piece { path.addLine(to: pts[(s * piece + k) % n]) }
            // -0.5 (nearest) … 0.5 (farthest) in z, as the cloud sees it.
            let near = max(0, min(1, 0.5 - zs[(s * piece + piece / 2) % n]))
            let width = weight * (0.8 + 0.8 * near)
            let alpha = 0.45 + 0.55 * near
            ctx.stroke(path, with: .color(line.opacity(alpha)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    /// How far from the centre a figure reaches, seen from any side (in the unit the
    /// curve is drawn in): the same figure fills its frame the same at every angle.
    private static var reaches: [VoiceFigure: Double] = [:]
    private static let reachLock = NSLock()
    static func reach(of figure: VoiceFigure) -> Double {
        reachLock.lock(); defer { reachLock.unlock() }
        if let r = reaches[figure] { return r }
        var most = 0.0
        for a in 0..<36 {
            let angle = Double(a) / 36 * 2 * .pi, cr = cos(angle), sr = sin(angle)
            for i in 0..<120 {
                let p = figure.point(Double(i) / 120)
                let x = p.x * cr + p.z * sr, z = -p.x * sr + p.z * cr, f = eye / (eye + z)
                most = max(most, abs(x * f), abs(p.y * f))
            }
        }
        reaches[figure] = most
        return most
    }
}

/// The figure drawn small and still, as a thin line — beside a name.
struct VoiceFigureMark: View {
    let figure: VoiceFigure
    let color: Color
    var lineWidth: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            ctx.stroke(Self.path(figure, in: size), with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    /// Seen a little from the side, as in the introduction round.
    static func path(_ figure: VoiceFigure, in size: CGSize) -> Path {
        let r = min(size.width, size.height) / 2 * 0.92
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let turn = 0.6, cr = cos(turn), sr = sin(turn)
        var path = Path()
        for i in 0...180 {
            let p = figure.point(Double(i) / 180)
            let x = p.x * cr + p.z * sr, z = -p.x * sr + p.z * cr, f = 2.6 / (2.6 + z)
            let q = CGPoint(x: c.x + x * r * f, y: c.y + p.y * r * f)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        return path
    }
}

/// A speaker's mark, with their figure beside it when Mindtalk remembers their
/// voice — otherwise just the mark.
struct VoiceBadge: View {
    let speaker: Int?
    let cast: Cast
    var size: CGFloat = 18
    @ObservedObject private var memory = VoiceMemory.shared

    var body: some View {
        let name = speaker.flatMap { cast.isNamed($0) ? cast.name(of: $0) : nil }
        // One mark: the voice's figure when Mindtalk knows the voice, otherwise the
        // initial — in the speaker's colour either way.
        if let name, let figure = VoiceFigure.remembered(name) {
            VoiceFigureView(figure: figure, color: SpeakerMark.color(of: speaker, in: cast), size: .compact, diameter: size)
                .help("Mindtalk känner igen \(name) på rösten")
        } else {
            SpeakerMark(speaker: speaker, cast: cast, size: size)
        }
    }
}

// MARK: - The cloud

/// Nine hundred points of light: a slowly turning sphere while Mindtalk listens,
/// falling into a voice's figure — in its colour — once it knows who is speaking,
/// and back into the sphere before the next voice's figure forms.
struct Constellation: View {
    /// The voice to show; nil for the listening sphere.
    let figure: VoiceFigure?
    let color: Color
    /// How loud the room is (0…1): the cloud breathes with it.
    let level: Double
    /// Comparing voiceprints: the sphere turns a little faster.
    var searching = false
    /// Off screen: no frames drawn.
    var paused = false
    /// The moment the round has a name: the figure's line drawn clearly through the
    /// points (eased in and out, so it never snaps).
    var defined = false
    /// On a light surface (the Hem card): the points are the colour itself, drawn
    /// plainly — light added to light would vanish.
    var onLight = false
    /// How far the cloud may have fallen into the figure (0…1): in the round the
    /// figure forms in step with the ring as the person talks. nil: all the way.
    var form: Double?
    /// The colour as given, for the listening sphere on a light surface (the sphere
    /// is white otherwise; only a voice's figure takes a colour).
    private let plain: SIMD3<Double>
    @State private var morph: Morph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let count = 900

    init(figure: VoiceFigure?, color: Color, level: Double, searching: Bool = false, paused: Bool = false, onLight: Bool = false,
         defined: Bool = false, form: Double? = nil) {
        self.figure = figure
        self.color = color
        self.level = level
        self.searching = searching
        self.paused = paused
        self.onLight = onLight
        self.defined = defined
        self.form = form
        self.plain = Self.rgb(color, vivid: false)
        // In its colour from the first frame, also in a still picture (no onAppear there).
        let first = Morph()
        first.set(figure, rgb: Self.rgb(color, vivid: !onLight), now: Date.timeIntervalSinceReferenceDate, instant: true)
        first.define(defined, now: Date.timeIntervalSinceReferenceDate, instant: true)
        first.limit(form, now: Date.timeIntervalSinceReferenceDate, instant: true)
        _morph = State(initialValue: first)
    }

    var body: some View {
        // Sixty frames a second is plenty for drifting light, also on a 120 Hz screen.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || paused)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in draw(&ctx, size: size, now: now) }
        }
        .onAppear { morph.set(figure, rgb: Self.rgb(color, vivid: !onLight), now: Date.timeIntervalSinceReferenceDate, instant: reduceMotion) }
        .onChange(of: figure) { _, f in morph.set(f, rgb: Self.rgb(color, vivid: !onLight), now: Date.timeIntervalSinceReferenceDate, instant: reduceMotion) }
        .onChange(of: Self.rgb(color)) { _, c in morph.recolour(c) }
        .onChange(of: defined) { _, d in morph.define(d, now: Date.timeIntervalSinceReferenceDate, instant: reduceMotion) }
        .onChange(of: form) { _, f in morph.limit(f, now: Date.timeIntervalSinceReferenceDate, instant: reduceMotion) }
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Double) {
        let state = morph.state(now: now, instant: reduceMotion)
        let clear = morph.clarity(now: now)
        let angle = morph.turn(now: now, speed: reduceMotion ? 0 : (searching ? 0.6 : 0.25))
        let cx = size.width / 2, cy = size.height * 0.42, R = min(size.width, size.height) * 0.28
        let k = state.k
        let rgb = onLight && state.figure == nil ? plain : state.rgb
        let tint = Color(red: rgb.x, green: rgb.y, blue: rgb.z)

        // The voice's colour, faintly, behind the cloud — not the plain ink sphere on
        // a light tile, where it would only show as a grey disc.
        if !onLight || state.figure != nil {
            let glow = R * 2.4
            ctx.fill(Path(ellipseIn: CGRect(x: cx - glow, y: cy - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(colors: [tint.opacity(0.07 * k + 0.02), .clear]),
                                           center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: glow))
        }

        let a = 0.15 + 0.85 * min(1, level)
        let cr = cos(angle), sr = sin(angle)
        let t = reduceMotion ? 0 : now.truncatingRemainder(dividingBy: 10_000)
        var xs = [CGFloat](repeating: 0, count: Self.count), ys = xs
        var zs = [Double](repeating: 0, count: Self.count), es = zs
        for i in 0..<Self.count {
            let p = Particles.shared[i]
            let ki = max(0, min(1, k * 1.5 - p.u * 0.5)), e = ki * ki * (3 - 2 * ki)
            let breath = reduceMotion ? 1 : 1 + 0.12 * a * sin(p.phase + t * 3)
            var target = state.figure?.point(p.u) ?? p.home
            // Gliding from one figure to the next of the same rhythm (the turn's final
            // print): each point on its way between the two.
            if let from = state.from { target = from.point(p.u) + (target - from.point(p.u)) * state.mix }
            let q = p.home * breath + (target - p.home * breath) * e
            let x2 = q.x * cr + q.z * sr, z2 = -q.x * sr + q.z * cr, f = 2.6 / (2.6 + z2)
            xs[i] = cx + x2 * R * f; ys[i] = cy + q.y * R * f; zs[i] = z2; es[i] = e
        }

        ctx.blendMode = onLight ? .normal : .plusLighter
        // Where the cloud has become the figure, its points join into a line.
        if k > 0.3 {
            var line = Path()
            for i in 0..<Self.count {
                let j = (i + 1) % Self.count
                if es[i] > 0.85, es[j] > 0.85 {
                    line.move(to: CGPoint(x: xs[i], y: ys[i]))
                    line.addLine(to: CGPoint(x: xs[j], y: ys[j]))
                }
            }
            ctx.stroke(line, with: .color(tint.opacity((0.28 + 0.5 * clear) * k)), lineWidth: 0.7 + 0.6 * clear)
        }
        // The points, nearer ones brighter and larger, whiter until they've arrived.
        // Drawn in a few batches (by brightness and colour) rather than one by one.
        let shades = 5, hues = 4
        var batches = [Path](repeating: Path(), count: shades * hues)
        for i in 0..<Self.count {
            let z = zs[i], e = es[i]
            let s = (1.5 - z * 0.6) * (1 + e * 0.3)
            let shade = min(shades - 1, Int((1 - z) / 2 * Double(shades)))
            let hue = min(hues - 1, Int(e * Double(hues)))
            batches[hue * shades + shade].addEllipse(in: CGRect(x: xs[i] - s, y: ys[i] - s, width: s * 2, height: s * 2))
        }
        for hue in 0..<hues {
            let m = (Double(hue) + 0.5) / Double(hues)
            let c = onLight ? rgb : SIMD3<Double>(1, 1, 1) + (rgb - SIMD3<Double>(1, 1, 1)) * m
            for shade in 0..<shades {
                let alpha = 0.3 + 0.45 * (Double(shade) + 0.5) / Double(shades)
                ctx.fill(batches[hue * shades + shade], with: .color(Color(red: c.x, green: c.y, blue: c.z).opacity(alpha)))
            }
        }
    }

    /// A speaker's colour, made vivid for a dark room; as it is (`vivid: false`) on a light one.
    static func rgb(_ color: Color, vivid: Bool = true) -> SIMD3<Double> {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        if !vivid { return SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let vivid = NSColor(hue: h, saturation: max(s, 0.55), brightness: 0.95, alpha: 1).usingColorSpace(.sRGB) ?? c
        return SIMD3(Double(vivid.redComponent), Double(vivid.greenComponent), Double(vivid.blueComponent))
    }

    /// The points' resting places: evenly over a sphere (a golden spiral), each
    /// with its own breathing rhythm.
    struct Particles {
        let home: SIMD3<Double>
        let u: Double
        let phase: Double

        static let shared: [Particles] = {
            var state: UInt64 = 0x9E3779B97F4A7C15
            return (0..<Constellation.count).map { i in
                let y = 1 - 2 * (Double(i) + 0.5) / Double(Constellation.count), r = (1 - y * y).squareRoot(), p = Double(i) * 2.39996
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Particles(home: SIMD3(cos(p) * r, y, sin(p) * r), u: Double(i) / Double(Constellation.count),
                                 phase: Double(state >> 33) / Double(1 << 31) * 2 * .pi)
            }
        }()
    }

    /// Where the cloud is between figures. A class, so the drawing can read it every
    /// frame without making SwiftUI redraw the view.
    final class Morph {
        private struct Shown { var figure: VoiceFigure; var rgb: SIMD3<Double> }
        private var current: Shown?
        private var leaving: Shown?
        private var leavingFrom = 0.0
        private var changedAt = 0.0
        private var angle = 0.0
        private var lastTurn: Double?
        private let dissolve = 0.8, form = 1.6
        /// The figure before, when the new one has the same rhythm: the points glide
        /// over to the new one (0.7 s) instead of falling apart and back.
        private var glide: (from: VoiceFigure, since: Double)?
        private let glideTime = 0.7

        func set(_ figure: VoiceFigure?, rgb: SIMD3<Double>, now: Double, instant: Bool) {
            if figure == current?.figure { current?.rgb = rgb; return }
            if let figure, let shown = current, shown.figure.rhythm == figure.rhythm, leaving == nil || now - changedAt > dissolve {
                // The same loop, turned a little: glide (from wherever a glide already
                // under way has reached).
                let was = glidePoint(now: now, instant: instant)
                glide = instant ? nil : (was, now)
                current = Shown(figure: figure, rgb: rgb)
                return
            }
            let before = state(now: now, instant: instant)
            leaving = before.figure.map { Shown(figure: $0, rgb: before.rgb) }
            leavingFrom = before.k
            current = figure.map { Shown(figure: $0, rgb: rgb) }
            changedAt = instant ? -1_000 : now
            glide = nil
        }

        /// The figure the points stand on now, in a glide: the one they came from,
        /// turned as far as they have come. (A new glide starts from here.)
        private func glidePoint(now: Double, instant: Bool) -> VoiceFigure {
            guard let shown = current else { return VoiceFigure.from(seed: "?") }
            guard let glide, !instant else { return shown.figure }
            let t = Self.smooth(min(1, (now - glide.since) / glideTime))
            var mid = shown.figure
            mid.phase = glide.from.phase + (shown.figure.phase - glide.from.phase) * t
            mid.depth = glide.from.depth + (shown.figure.depth - glide.from.depth) * t
            return mid
        }

        private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

        private var ceiling: Double?
        private var ceilingFrom = 0.0
        private var ceilingAt = -1_000.0

        /// How far the cloud may fall in (0…1), eased over 0.4 s each time it moves; nil
        /// lets it all the way.
        func limit(_ to: Double?, now: Double, instant: Bool) {
            ceilingFrom = ceilingNow(now: now)
            ceiling = to
            ceilingAt = instant ? -1_000 : now
        }

        private func ceilingNow(now: Double) -> Double {
            let t = min(1, max(0, (now - ceilingAt) / 0.4))
            return ceilingFrom + ((ceiling ?? 1) - ceilingFrom) * t
        }

        func recolour(_ rgb: SIMD3<Double>) { current?.rgb = rgb }

        private var defined = false
        private var definedAt = -1_000.0

        /// The figure's line drawn clearly (the round has a name) — or back to faint.
        func define(_ on: Bool, now: Double, instant: Bool) {
            guard on != defined else { return }
            defined = on
            definedAt = instant ? -1_000 : now
        }

        /// How clearly the line is drawn now (0…1): in over 0.35 s, out over 0.5 s.
        func clarity(now: Double) -> Double {
            let dt = now - definedAt
            return defined ? min(1, dt / 0.35) : max(0, 1 - dt / 0.5)
        }

        /// What to draw now: a figure and how far the cloud has fallen into it (0…1) —
        /// and, in a glide, the figure the points come from and how far they have come.
        func state(now: Double, instant: Bool) -> (figure: VoiceFigure?, rgb: SIMD3<Double>, k: Double, from: VoiceFigure?, mix: Double) {
            let white = SIMD3<Double>(1, 1, 1)
            let cap = instant ? (ceiling ?? 1) : ceilingNow(now: now)
            if instant { return (current?.figure, current?.rgb ?? white, current == nil ? 0 : cap, nil, 1) }
            let dt = now - changedAt
            let out = leaving == nil || leavingFrom <= 0 ? 0 : dissolve
            if let leaving, dt < out {
                return (leaving.figure, leaving.rgb, leavingFrom * (1 - dt / out), nil, 1)
            }
            guard let current else { return (nil, white, 0, nil, 1) }
            let k = min(cap, max(0, min(1, (dt - out) / form)))
            if let glide {
                let t = Self.smooth(min(1, (now - glide.since) / glideTime))
                if t >= 1 { self.glide = nil } else { return (current.figure, current.rgb, k, glide.from, t) }
            }
            return (current.figure, current.rgb, k, nil, 1)
        }

        /// The cloud's slow turn, at whatever speed it has now.
        func turn(now: Double, speed: Double) -> Double {
            if let last = lastTurn { angle += min(0.1, max(0, now - last)) * speed }
            lastTurn = now
            return angle
        }
    }
}
