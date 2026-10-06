import AppKit
import SwiftUI

// MARK: - A voice's own mark
//
// Every voice Mindtalk knows gets a ring whose shape comes from its voiceprint
// (VoiceMemory: 192 numbers per voice) — no two alike, and the same every time, so
// the mark is the person's. It shows in the introduction round, beside known
// voices' names in a meeting, and in Settings. A voice that isn't remembered (or
// with voice recognition off) gets a shape from its number instead — nothing about
// the voice itself is used then.

enum VoiceShape {
    static let points = 32

    /// The ring from a voiceprint: its 192 numbers in 32 groups, each group's weight
    /// a radius, smoothed — organic, never spiky.
    static func from(print: [Float]) -> [Double] {
        guard print.count >= points else { return from(seed: "?") }
        let size = print.count / points
        let raw = (0..<points).map { i in
            Double(print[(i * size)..<((i + 1) * size)].reduce(0) { $0 + abs($1) })
        }
        return normalised(smoothed(raw))
    }

    /// A ring from anything else (the speaker's number): the same seed, the same shape.
    static func from(seed: String) -> [Double] {
        var state = seed.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        let raw = (0..<points).map { _ -> Double in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
        return normalised(smoothed(smoothed(raw)))
    }

    private static func smoothed(_ v: [Double]) -> [Double] {
        v.indices.map { i in (v[(i + v.count - 1) % v.count] + 2 * v[i] + v[(i + 1) % v.count]) / 4 }
    }

    private static func normalised(_ v: [Double]) -> [Double] {
        guard let lo = v.min(), let hi = v.max(), hi > lo else { return v.map { _ in 0.8 } }
        return v.map { 0.58 + 0.42 * ($0 - lo) / (hi - lo) }
    }

    /// The person's shape, if Mindtalk remembers their voice.
    @MainActor static func remembered(_ name: String) -> [Double]? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        #if DEBUG
        // Screenshots: the demo meeting's people are "remembered" without real voices.
        if CommandLine.arguments.contains("--demo-meeting"), ["anna", "erik"].contains(key) { return from(seed: key) }
        #endif
        guard VoiceMemory.shared.enabled, !key.isEmpty,
              let person = VoiceMemory.shared.people.first(where: { $0.name.lowercased() == key }),
              let first = person.prints.first else { return nil }
        // The average of their prints: steadier than any one recording.
        var mean = [Float](repeating: 0, count: first.count)
        for p in person.prints where p.count == first.count { for i in p.indices { mean[i] += p[i] } }
        return from(print: mean)
    }
}

/// The ring itself. `level` (0…1) makes it breathe with the voice; `turning` lets it
/// rotate slowly, as in the introduction.
struct VoiceSigil: View {
    let shape: [Double]
    let color: Color
    var level: Double = 0
    var lineWidth: CGFloat = 2
    var glow = true
    var time: Double = 0

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 * 0.86
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let path = Self.path(shape, center: c, radius: r, level: level, time: time)
            if glow {
                var soft = ctx
                soft.addFilter(.blur(radius: lineWidth * 2.5))
                soft.stroke(path, with: .color(color.opacity(0.75)), lineWidth: lineWidth * 2.2)
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    /// A smooth closed curve through the shape's points (Catmull–Rom).
    static func path(_ shape: [Double], center c: CGPoint, radius r: CGFloat, level: Double, time: Double) -> Path {
        let n = shape.count
        guard n >= 3 else { return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        let pts: [CGPoint] = (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi + time * 0.18
            // Speaking: each point swells by its own rhythm.
            let wobble = 1 + level * 0.16 * sin(time * 6 + Double(i) * 1.7)
            let rr = r * CGFloat(shape[i] * wobble)
            return CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a))
        }
        var path = Path()
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }
}

/// A speaker's mark with their voice's ring around it, when Mindtalk remembers them —
/// otherwise just the mark. Takes the same room as the mark alone, so rows don't jump.
struct VoiceBadge: View {
    let speaker: Int?
    let cast: Cast
    var size: CGFloat = 18
    @ObservedObject private var memory = VoiceMemory.shared

    var body: some View {
        let name = speaker.flatMap { cast.isNamed($0) ? cast.name(of: $0) : nil }
        if let name, let shape = VoiceShape.remembered(name) {
            let ring = size * 1.5
            ZStack {
                VoiceSigil(shape: VoiceShape.hugging(shape),
                           color: SpeakerMark.fill(cast.order.firstIndex(of: speaker ?? -1) ?? 0),
                           lineWidth: max(1.1, size / 13), glow: false)
                    .frame(width: ring, height: ring)
                SpeakerMark(speaker: speaker, cast: cast, size: size * 0.82)
            }
            .frame(width: ring, height: ring)
            .padding(-(ring - size) / 2)
            .help("Mindtalk känner igen \(name)s röst")
        } else {
            SpeakerMark(speaker: speaker, cast: cast, size: size)
        }
    }
}

extension VoiceShape {
    /// The same ring, kept close to a round mark inside it, so it never cuts into it.
    static func hugging(_ shape: [Double]) -> [Double] {
        shape.map { 0.8 + ($0 - 0.58) / 0.42 * 0.2 }
    }
}
