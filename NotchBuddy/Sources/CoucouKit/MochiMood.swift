import QuartzCore
import SwiftUI

/// How the Mac feels, as Mochi shows it. Each level runs from 0 (not at all) to 1.
/// The Mac reads it (MachineVitals); the iPhone never sets it, so Mochi stays calm there.
struct MochiMood: Equatable, Sendable {
    /// The processor is at full load: Mochi sweats and breathes fast.
    var busy: CGFloat = 0
    /// The Mac is warm: Mochi flushes red, with heat waves above his head.
    var hot: CGFloat = 0
    /// Memory is short: Mochi puffs up, like after a big meal.
    var full: CGFloat = 0
    /// The battery is low: heavy eyelids, a yawn now and then.
    var tired: CGFloat = 0
    /// The battery is nearly empty: Mochi sleeps.
    var asleep = false

    static let calm = MochiMood()
}

// MARK: - Mochi's moods and the Focus headphones

extension BotEngine {
    /// States where the Mac's mood shows: Mochi is not asking for anything.
    private var moodShows: Bool {
        switch state {
        case .idle, .working, .thinking, .searching, .finished: return true
        default: return false
        }
    }

    /// Eases the mood levels towards `moodTarget` and plays their small animations.
    /// Called from `update` before the look and the body scale are smoothed.
    func updateMood(dt: Double, now: Double, t: CGFloat) {
        guard !isMini else { return }
        let shows = moodShows
        let calmState = state == .idle || state == .finished
        let target = moodTarget
        let k = CGFloat(1 - pow(0.25, dt))
        moodBusy  += ((shows ? target.busy : 0) - moodBusy) * k
        moodHot   += ((shows ? target.hot : 0) - moodHot) * k
        moodFull  += ((shows ? target.full : 0) - moodFull) * k
        moodTired += ((calmState ? target.tired : 0) - moodTired) * k
        let sleeping = calmState && target.asleep
        headphones += (headphonesTarget - headphones) * CGFloat(1 - pow(0.02, dt))

        // Busy: quick, short breaths and a drop of sweat every second or so.
        if moodBusy > 0.02, !locks.contains("sy"), !locks.contains("sx") {
            let pant = sin(t * 7.5) * 0.028 * moodBusy
            tgSy += pant
            tgSx -= pant * 0.6
        }
        // Full memory: puffed up.
        if moodFull > 0.02 {
            tgSx *= 1 + 0.07 * moodFull
            tgSy *= 1 - 0.035 * moodFull
        }
        if now > nextMoodSweat {
            if moodBusy > 0.5 || moodHot > 0.6 {
                emit(.sweat, count: 1)
                nextMoodSweat = now + (moodBusy > 0.5 ? 0.9 : 1.6) + Double.random(in: 0...0.5)
            } else {
                nextMoodSweat = now + 0.5
            }
        }

        // Low battery: heavy eyes, the odd yawn; nearly empty: asleep with his z's.
        let ownEye = eyeOverride == nil || eyeOverride == .tired || eyeOverride == .closed
        if sleeping {
            if ownEye { eyeOverride = .closed; eyeOverrideUntil = now + 0.4 }
            tgYaw = 0
            tgPitch = -0.14
            if now > nextMoodYawn {
                emit(.z, count: 1)
                nextMoodYawn = now + 1.6
            }
        } else if moodTired > 0.5 {
            if ownEye { eyeOverride = .tired; eyeOverrideUntil = now + 0.4 }
            tgPitch -= 0.06 * moodTired
            if now > nextMoodYawn {
                if nextMoodYawn > 0 { triggerEmote(.yawn, silent: true) }
                nextMoodYawn = now + 24 + Double.random(in: 0...12)
            }
        }
    }

    /// Red cheeks and a flushed body while the Mac is warm (inside the body's transform).
    func drawMoodTint(ctx: inout GraphicsContext, path: Path, rx: CGFloat, ry: CGFloat) {
        guard moodHot > 0.01, morph < 0.5, !isMini else { return }
        let a = Double(moodHot) * (1 - Double(morph) * 2)
        ctx.fill(path, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 1, green: 0.36, blue: 0.24).opacity(0.42 * a), location: 0),
                .init(color: Color(red: 1, green: 0.36, blue: 0.24).opacity(0), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: ry),
            endPoint: CGPoint(x: 0, y: -ry * 0.6)
        ))
    }

    /// What goes over Mochi in world space: heat waves, and the Focus headphones.
    func drawMoodExtras(context: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, cx: CGFloat, cy: CGFloat) {
        guard !isMini, morph < 0.3 else { return }
        let now = CGFloat(CACurrentMediaTime() - t0)

        // Heat waves: three wavy lines rising above the head.
        if moodHot > 0.5 {
            let a = Double((moodHot - 0.5) * 2)
            for i in 0..<3 {
                let x0 = cx + CGFloat(i - 1) * R * 0.42
                let phase = now * 3 + CGFloat(i) * 1.7
                let rise = (now * 0.6 + CGFloat(i) * 0.33).truncatingRemainder(dividingBy: 1)
                var wave = Path()
                let top = cy - ry * 1.18 - R * 0.55 * rise
                let len = R * 0.5
                for s in 0...12 {
                    let f = CGFloat(s) / 12
                    let p = CGPoint(x: x0 + sin(phase + f * 6) * R * 0.07, y: top - f * len)
                    if s == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
                }
                var c = context
                c.opacity = a * Double(sin(rise * .pi))
                c.stroke(wave, with: .color(Color(red: 1, green: 0.55, blue: 0.3)),
                         style: StrokeStyle(lineWidth: max(1, R * 0.07), lineCap: .round))
            }
        }

        // Focus headphones: a band over the head and a cup on each side.
        guard headphones > 0.01 else { return }
        var c = context
        c.opacity = Double(min(1, headphones * 1.4))
        c.translateBy(x: cx, y: cy - (1 - headphones) * R * 0.8)
        if tilt != 0 { c.rotate(by: .radians(tilt)) }
        c.scaleBy(x: sx, y: sy)
        let shift = sin(yaw) * rx * 0.12
        let dark = Color(red: 0.16, green: 0.17, blue: 0.21)
        let accent = Color(red: 0.655, green: 0.545, blue: 0.98)   // #A78BFA
        var band = Path()
        band.move(to: CGPoint(x: -rx * 0.97 + shift, y: -ry * 0.12))
        band.addQuadCurve(to: CGPoint(x: rx * 0.97 + shift, y: -ry * 0.12),
                          control: CGPoint(x: shift, y: -ry * 1.95))
        c.stroke(band, with: .color(dark), style: StrokeStyle(lineWidth: R * 0.14, lineCap: .round))
        c.stroke(band, with: .color(Color.white.opacity(0.18)), style: StrokeStyle(lineWidth: R * 0.04, lineCap: .round))
        for side in [-1.0, 1.0] as [CGFloat] {
            let w = R * 0.32, h = R * 0.62
            let x = side * rx * 0.99 + shift - w / 2
            let rect = CGRect(x: x, y: -ry * 0.12 - h * 0.28, width: w, height: h)
            let cup = Path(roundedRect: rect, cornerRadius: w * 0.45)
            c.fill(cup, with: .color(dark))
            let pad = Path(roundedRect: rect.insetBy(dx: w * 0.22, dy: h * 0.16), cornerRadius: w * 0.3)
            c.fill(pad, with: .color(accent.opacity(0.9)))
        }
    }
}
