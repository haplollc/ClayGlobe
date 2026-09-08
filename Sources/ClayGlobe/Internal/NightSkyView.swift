import SwiftUI

/// The night behind the planet: deep indigo shading to near-black, a faint
/// nebula wash for depth, a soft halo where the ball sits, and a field of
/// gently twinkling stars. Everything draws in one Canvas so it animates
/// cheaply; star positions are seeded so they never jump between frames.
struct NightSkyView: View {
    private struct Twinkle {
        let x: CGFloat, y: CGFloat
        let baseR: CGFloat
        let phase: Double
        let speed: Double
        let bright: Double
        let warm: Bool          // a few stars lean warm/gold instead of white
    }

    private let twinkles: [Twinkle]

    init(count: Int = 220) {
        var rng = SeededRNG(seed: 0xB11B0_5EED)
        twinkles = (0..<count).map { _ in
            let big = rng.next01() > 0.92
            return Twinkle(
                x: CGFloat(rng.next01()),
                y: CGFloat(rng.next01()),
                baseR: CGFloat(big ? 1.3 + rng.next01() * 1.0 : 0.4 + rng.next01() * 0.9),
                phase: rng.next01() * 6.2831853,
                speed: 0.5 + rng.next01() * 2.2,
                bright: 0.35 + rng.next01() * 0.65,
                warm: rng.next01() > 0.85)
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let rect = CGRect(origin: .zero, size: size)

                // Indigo night, darker toward the foot of the screen.
                ctx.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.09, green: 0.10, blue: 0.28),
                        Color(red: 0.06, green: 0.06, blue: 0.19),
                        Color(red: 0.03, green: 0.03, blue: 0.10),
                    ]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

                // Two faint nebula washes, a warm plum up top and a cool teal
                // low down, so the dark has some depth to it.
                ctx.fill(Path(rect), with: .radialGradient(
                    Gradient(colors: [Color(red: 0.42, green: 0.22, blue: 0.48).opacity(0.16), .clear]),
                    center: CGPoint(x: size.width * 0.18, y: size.height * 0.12),
                    startRadius: 0, endRadius: size.width * 0.9))
                ctx.fill(Path(rect), with: .radialGradient(
                    Gradient(colors: [Color(red: 0.12, green: 0.34, blue: 0.52).opacity(0.14), .clear]),
                    center: CGPoint(x: size.width * 0.85, y: size.height * 0.82),
                    startRadius: 0, endRadius: size.width * 0.8))

                // A soft halo behind the planet, like a backlight on the set.
                let haloCenter = CGPoint(x: size.width * 0.5, y: size.height * 0.46)
                ctx.fill(Path(rect), with: .radialGradient(
                    Gradient(colors: [
                        Color(red: 0.22, green: 0.23, blue: 0.54).opacity(0.6),
                        Color(red: 0.16, green: 0.16, blue: 0.42).opacity(0.22),
                        .clear,
                    ]),
                    center: haloCenter, startRadius: 0, endRadius: size.width * 0.62))

                for s in twinkles {
                    let tw = 0.5 + 0.5 * sin(t * s.speed + s.phase)
                    let alpha = s.bright * (0.3 + 0.7 * tw)
                    let r = s.baseR * (0.7 + 0.55 * CGFloat(tw))
                    let p = CGPoint(x: s.x * size.width, y: s.y * size.height)
                    let color: Color = s.warm
                        ? Color(red: 1.0, green: 0.9, blue: 0.72)
                        : .white
                    if s.baseR > 1.3 {
                        // Soft glow halo for the bright ones.
                        let g = r * 3
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - g, y: p.y - g, width: g * 2, height: g * 2)),
                                 with: .color(color.opacity(alpha * 0.12)))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(color.opacity(alpha)))
                }
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.10))
        .drawingGroup()
    }
}

/// Occasional shooting stars streaking across the upper sky, drawn over the
/// backdrop. One crosses every `period` seconds on a per-pass trajectory,
/// with a bright head and a fading tail, easing in and out so it never pops.
struct CometView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let period = 7.5, duration = 1.5
                let cycle = (t / period).rounded(.down)
                let localT = t - cycle * period
                guard localT < duration else { return }

                var rng = SeededRNG(seed: UInt64(bitPattern: Int64(cycle)) &* 0x9E3779B97F4A7C15 &+ 7)
                let fromLeft = rng.next01() > 0.5
                let dir: CGFloat = fromLeft ? 1 : -1
                let startX: CGFloat = fromLeft ? -0.1 : 1.1
                // Stay high: the planet fills the middle, so a comet reads as a
                // background object only while it's in the open sky up top.
                let startY = CGFloat(0.03 + rng.next01() * 0.09)
                let slope = CGFloat(0.05 + rng.next01() * 0.12)
                let progress = CGFloat(localT / duration)
                let span: CGFloat = 1.2
                let hx = startX + dir * span * progress
                let hy = startY + slope * span * progress
                let head = CGPoint(x: hx * size.width, y: hy * size.height)
                let fade = sin(Double(progress) * .pi)             // ease in / out

                let warm = Color(red: 1.0, green: 0.94, blue: 0.78)
                let tailLen: CGFloat = 0.28
                let tail = CGPoint(x: (hx - dir * tailLen) * size.width,
                                   y: (hy - slope * tailLen) * size.height)
                var trail = Path(); trail.move(to: tail); trail.addLine(to: head)
                ctx.stroke(trail, with: .linearGradient(
                    Gradient(colors: [warm.opacity(0), warm.opacity(0.9 * fade)]),
                    startPoint: tail, endPoint: head),
                    style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                let hr: CGFloat = 3.0
                ctx.fill(Path(ellipseIn: CGRect(x: head.x - hr * 3.5, y: head.y - hr * 3.5,
                                                width: hr * 7, height: hr * 7)),
                         with: .color(warm.opacity(0.20 * fade)))
                ctx.fill(Path(ellipseIn: CGRect(x: head.x - hr, y: head.y - hr,
                                                width: hr * 2, height: hr * 2)),
                         with: .color(.white.opacity(0.98 * fade)))
            }
            .allowsHitTesting(false)
        }
    }
}

/// Tiny deterministic PRNG (splitmix-ish) so the star layout is stable across
/// launches and frames without pulling in a dependency.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextU() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next01() -> Double { Double(nextU() >> 11) * (1.0 / 9007199254740992.0) }
}
