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

/// A drop of sweat thrown from Mochi's side: it rises, then falls to the floor in an arc.
/// In Mochi's units (R), from his resting centre; the time is real time.
struct MoodDrop {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var born: Double
    var size: CGFloat
}

/// One of Mochi's stressed hops, from side to side.
struct MoodHop {
    var from: CGFloat = 0
    var to: CGFloat = 0
    var start: Double = 0
    var duration: Double = 0.2
    var height: CGFloat = 0
    var rest: Double = 0
    var landed = true
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

    /// Gravity of the sweat drops, in R per second².
    private static let dropGravity: CGFloat = 5.5

    /// Takes back last frame's hop offset before anything else moves Mochi.
    func undoMoodOffsets() {
        if moodShiftApplied != 0 { ox -= moodShiftApplied; moodShiftApplied = 0 }
        if moodLiftApplied != 0 { oy -= moodLiftApplied; moodLiftApplied = 0 }
    }

    /// Eases the mood levels towards `moodTarget` and plays their animations.
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

        updateStress(now: now)

        // Full memory: puffed up.
        if moodFull > 0.02 {
            tgSx *= 1 + 0.07 * moodFull
            tgSy *= 1 - 0.035 * moodFull
        }

        // Sweat: drops thrown from his sides, in bursts while the processor is at full load,
        // now and then when the Mac is only warm.
        if now > nextMoodDrop {
            if moodBusy > 0.4 {
                throwDrop(now: now)
                if Double.random(in: 0...1) < 0.35 { throwDrop(now: now) }
                nextMoodDrop = now + Double.random(in: 0.14...0.32)
            } else if moodHot > 0.6 {
                throwDrop(now: now)
                nextMoodDrop = now + Double.random(in: 0.6...1.1)
            } else {
                nextMoodDrop = now + 0.3
            }
        }
        moodDrops.removeAll { drop in
            let a = CGFloat(now - drop.born)
            return a > 1.6 || drop.y + drop.vy * a + Self.dropGravity * a * a / 2 > 1.05
        }

        // Low battery: heavy eyes, the odd yawn; nearly empty: asleep with his z's.
        let ownEye = eyeOverride == nil || eyeOverride == .tired || eyeOverride == .closed || eyeOverride == .wide
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
        } else if moodBusy > 0.4, ownEye {
            // Stressed: wide eyes.
            eyeOverride = .wide
            eyeOverrideUntil = now + 0.3
        }
    }

    /// The processor at full load: Mochi panics, hopping from side to side at random, quick and
    /// short, leaning into each hop, squashing when he lands, eyes darting where he jumps.
    private func updateStress(now: Double) {
        let level = moodBusy
        guard level > 0.02 || abs(hop.to) > 0.005 || !hop.landed else { return }
        let p = hop.duration > 0 ? min(1, (now - hop.start) / hop.duration) : 1
        if p >= 1 {
            if !hop.landed {
                hop.landed = true
                // The landing squash.
                anim("sy", keys: [TweenKey(target: 0.86, duration: 60, ease: Ease.out),
                                  TweenKey(target: 1.0, duration: 140, ease: Ease.out)])
                anim("sx", keys: [TweenKey(target: 1.1, duration: 60, ease: Ease.out),
                                  TweenKey(target: 1.0, duration: 140, ease: Ease.out)])
            }
            if now > hop.start + hop.duration + hop.rest {
                // Next hop: somewhere else on the floor, never twice the same.
                var next: CGFloat = 0
                if level > 0.3 {
                    repeat { next = CGFloat.random(in: -0.34...0.34) } while abs(next - hop.to) < 0.14
                }
                hop = MoodHop(from: hop.to, to: next, start: now,
                              duration: Double.random(in: 0.15...0.3),
                              height: level > 0.3 ? CGFloat.random(in: 0.08...0.22) : 0.05,
                              rest: Double.random(in: 0.02...0.38), landed: false)
            }
        }
        let q = CGFloat(min(1, hop.duration > 0 ? (now - hop.start) / hop.duration : 1))
        let eased = q < 0.5 ? 2 * q * q : 1 - pow(-2 * q + 2, 2) / 2
        let x = hop.from + (hop.to - hop.from) * eased
        let lift = sin(.pi * q) * hop.height * (hop.landed ? 0 : 1)
        let dir: CGFloat = hop.to >= hop.from ? 1 : -1
        let amount = min(1, level * 1.4)
        if !locks.contains("ox") {
            moodShiftApplied = x * amount
            ox += moodShiftApplied
        }
        if !locks.contains("oy") {
            moodLiftApplied = -lift * amount
            oy += moodLiftApplied
        }
        if !hop.landed {
            tgTilt += dir * 0.12 * sin(.pi * q) * amount
            tgYaw = dir * 0.7
            tgPitch -= 0.1
        }
    }

    private func throwDrop(now: Double) {
        let side: CGFloat = Bool.random() ? 1 : -1
        let drop = MoodDrop(
            x: side * 1.0 + ox, y: -0.3 + oy,
            vx: side * CGFloat.random(in: 0.45...0.75),
            vy: -CGFloat.random(in: 1.4...2.0),
            born: now,
            size: CGFloat.random(in: 0.11...0.15))
        moodDrops.append(drop)
        if moodDrops.count > 24 { moodDrops.removeFirst() }
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

    /// What goes over Mochi in world space: sweat drops, heat waves, and the Focus headphones.
    func drawMoodExtras(context: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, cx: CGFloat, cy: CGFloat) {
        guard !isMini, morph < 0.3 else { return }
        let real = CACurrentMediaTime()
        let now = CGFloat(real - t0)

        // Sweat: each drop follows its arc from where it left Mochi's side.
        if !moodDrops.isEmpty {
            let baseX = cx - ox * R, baseY = cy - oy * R
            for drop in moodDrops {
                let a = CGFloat(real - drop.born)
                guard a >= 0 else { continue }
                let x = drop.x + drop.vx * a
                let y = drop.y + drop.vy * a + Self.dropGravity * a * a / 2
                let vy = drop.vy + Self.dropGravity * a
                var c = context
                c.opacity = Double(min(1, a / 0.06) * min(1, max(0, (1.05 - y) / 0.25)))
                c.translateBy(x: baseX + x * R, y: baseY + y * R)
                c.rotate(by: .radians(atan2(vy, drop.vx) - .pi / 2))
                let s = R * drop.size
                var tear = Path()
                tear.move(to: CGPoint(x: 0, y: -s * 1.15))
                tear.addQuadCurve(to: CGPoint(x: 0, y: s * 0.7), control: CGPoint(x: s * 0.85, y: s * 0.2))
                tear.addQuadCurve(to: CGPoint(x: 0, y: -s * 1.15), control: CGPoint(x: -s * 0.85, y: s * 0.2))
                c.fill(tear, with: .color(Color(red: 0.486, green: 0.78, blue: 1)))
                c.fill(Path(ellipseIn: CGRect(x: -s * 0.32, y: -s * 0.05, width: s * 0.22, height: s * 0.3)),
                       with: .color(.white.opacity(0.7)))
            }
        }

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

        // Focus headphones: a padded band hugging the head, a cup on each side.
        guard headphones > 0.01 else { return }
        var c = context
        c.opacity = Double(min(1, headphones * 1.4))
        c.translateBy(x: cx, y: cy - (1 - headphones) * R * 0.8)
        if tilt != 0 { c.rotate(by: .radians(tilt)) }
        c.scaleBy(x: sx, y: sy)
        let shift = sin(yaw) * rx * 0.1
        let dark = Color(red: 0.133, green: 0.145, blue: 0.172)        // #22252C
        var band = Path()
        band.move(to: CGPoint(x: -rx * 0.97 + shift, y: -ry * 0.18))
        band.addCurve(to: CGPoint(x: rx * 0.97 + shift, y: -ry * 0.18),
                      control1: CGPoint(x: -rx * 0.98 + shift, y: -ry * 1.52),
                      control2: CGPoint(x: rx * 0.98 + shift, y: -ry * 1.52))
        c.stroke(band, with: .color(dark), style: StrokeStyle(lineWidth: R * 0.15, lineCap: .round))
        c.stroke(band, with: .color(Color(red: 0.227, green: 0.243, blue: 0.282)),
                 style: StrokeStyle(lineWidth: R * 0.06, lineCap: .round))
        for side in [-1.0, 1.0] as [CGFloat] {
            let w = R * 0.44, h = R * 0.74
            let ccx = side * rx * 0.97 + shift, ccy = ry * 0.04
            var yoke = Path()
            yoke.move(to: CGPoint(x: side * rx * 0.97 + shift, y: -ry * 0.2))
            yoke.addLine(to: CGPoint(x: ccx, y: ccy - h * 0.3))
            c.stroke(yoke, with: .color(dark), style: StrokeStyle(lineWidth: R * 0.1, lineCap: .round))
            let shell = CGRect(x: ccx - w / 2, y: ccy - h / 2, width: w, height: h)
            c.fill(Path(roundedRect: shell, cornerRadius: w / 2), with: .linearGradient(
                Gradient(colors: [Color(red: 0.227, green: 0.243, blue: 0.278), Color(red: 0.11, green: 0.118, blue: 0.137)]),
                startPoint: CGPoint(x: ccx, y: shell.minY), endPoint: CGPoint(x: ccx, y: shell.maxY)))
            let face = CGRect(x: ccx - w * 0.3, y: ccy - h * 0.33, width: w * 0.6, height: h * 0.66)
            c.fill(Path(roundedRect: face, cornerRadius: w * 0.3), with: .linearGradient(
                Gradient(colors: [Color(red: 0.769, green: 0.71, blue: 0.992), Color(red: 0.545, green: 0.361, blue: 0.965)]),
                startPoint: CGPoint(x: ccx, y: face.minY), endPoint: CGPoint(x: ccx, y: face.maxY)))
            c.fill(Path(roundedRect: CGRect(x: ccx - w * 0.2, y: ccy - h * 0.27, width: w * 0.14, height: h * 0.24),
                        cornerRadius: w * 0.07), with: .color(.white.opacity(0.35)))
        }
    }
}
