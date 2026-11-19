// The buddy's decisions, routes and flight paths, as pure logic (no AppKit, no
// layers), so it can be tested on its own with thousands of random runs.
// Coordinates are the buddy panel's: origin bottom-left, points; a mascot's
// position is its anchor (feet, or hands while hanging from the ceiling).
// `Moves` is a pack's action table: the Shimeji-ee defaults, overridden and
// extended by the pack's own actions.xml. A move is allowed only when the pack
// has every frame it needs, so a 6-frame pack never slides up a wall as a
// still picture. `Brain.decide` returns a short plan of steps; Buddy.swift
// plays them with Core Animation and asks again when they end. Flights
// (falls, jumps, throws) are simulated here once, with bounces off the screen
// edges and landings on the floor or a window top, and played back as one
// keyframe path.
import CoreGraphics
import Foundation

// MARK: Actions

struct Frame: Equatable {
    /// Image path inside the pack, e.g. "shime1.png" or "dance/shime3.png".
    let image: String
    let seconds: Double
    /// Anchor in a 128-pt frame, from the image's top-left.
    var anchor = CGPoint(x: 64, y: 128)
    /// Shimeji velocity, pixels per 40 ms tick in a 128-pt frame (y down).
    var velocity = CGPoint.zero
}

struct Action: Equatable {
    let name: String
    let frames: [Frame]

    var images: Set<String> { Set(frames.map(\.image)) }
    var duration: Double { frames.reduce(0) { $0 + $1.seconds } }

    /// Average speed along its velocity, in points a second at `size`.
    func speed(size: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        var pixels = 0.0
        for f in frames {
            let v = Double(hypot(f.velocity.x, f.velocity.y))
            pixels += v * f.seconds / 0.04
        }
        return CGFloat(pixels / duration) * size / 128
    }

    /// The whole gait at `factor` of its pace: legs and ground speed together,
    /// so the ground each frame covers stays as drawn.
    func paced(_ factor: Double) -> Action {
        guard factor > 0, factor.isFinite else { return self }
        return Action(name: name, frames: frames.map {
            Frame(image: $0.image, seconds: $0.seconds / factor, anchor: $0.anchor,
                  velocity: CGPoint(x: $0.velocity.x * factor, y: $0.velocity.y * factor))
        })
    }
}

/// A move's position keyframes, foot-locked to its frames.
struct Gait: Equatable {
    /// Where the anchor is at each key; a frame that stands still repeats a point.
    var points: [CGPoint]
    /// 0...1, one per point, never decreasing.
    var keyTimes: [Double]
    /// How long each of the action's frames shows, as a share of its own
    /// seconds: the contents animation runs `action.duration * timeScale` a loop.
    var timeScale: Double
    var duration: Double
}

/// A pack's action table.
struct Moves {
    private(set) var actions: [String: Action]
    /// The pack's own extra actions (dance, wave, spells...), played now and then.
    private(set) var extras: [String] = []
    let images: Set<String>
    /// How far the climbing frames' visible pixels reach from the anchor
    /// toward the wall, as a share of the frame's width (0.5 = the frame edge).
    var wallReach: CGFloat = 0.5

    init(images: Set<String>, custom: [Action] = [], wallReach: CGFloat = 0.5) {
        self.images = images
        self.wallReach = min(max(wallReach, 0), 0.5)
        var table = Dictionary(Self.defaults.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for var a in custom where !a.frames.isEmpty {
            if table[a.name] == nil, !Self.plumbing.contains(a.name) { extras.append(a.name) }
            // Some packs cycle their legs far faster than Shimeji's own pace
            // (2 ticks a frame instead of 6): stretch the frames and slow the
            // ground speed with them, so each step covers the ground the art
            // shows (velocity is per tick).
            if let least = Self.leastFrame[a.name], let shortest = a.frames.map(\.seconds).min(), shortest > 0, shortest < least {
                a = a.paced(shortest / least)
            }
            table[a.name] = a
        }
        actions = table
        extras = extras.filter { has($0) }.sorted()
    }

    /// The pack has every frame this action shows.
    func has(_ name: String) -> Bool {
        guard let a = actions[name] else { return false }
        return a.images.isSubset(of: images)
    }

    /// The action, or Stand when the pack lacks its frames.
    func action(_ name: String) -> Action {
        if has(name), let a = actions[name] { return a }
        return actions["Stand"]!
    }

    var canClimb: Bool { has("ClimbWall") && has("GrabWall") && has("ClimbCeiling") && has("GrabCeiling") }
    /// Climbs with its walk turned sideways (wall) or upside down (ceiling):
    /// for packs without real climbing art.
    private(set) var climbsByWalking = false

    /// The pack's walk and stand stand in for climbing and hanging; the
    /// player turns them onto the wall or ceiling. Feet touch the surface,
    /// so the anchor sits right on it (no wall reach).
    /// The same gaits with their legs at `factor` of the pace (each frame
    /// shows longer) and the ground speed slowed with them.
    func stepping(at factor: CGFloat) -> Moves {
        var copy = self
        for name in ["Walk", "Run", "Dash", "Creep"] {
            guard let a = actions[name], factor > 0, factor.isFinite else { continue }
            copy.actions[name] = a.paced(Double(factor))
        }
        return copy
    }

    func climbingByWalking() -> Moves {
        var copy = self
        let walk = action("Walk"), stand = action("Stand")
        copy.actions["ClimbWall"] = Action(name: "ClimbWall", frames: walk.frames)
        copy.actions["ClimbCeiling"] = Action(name: "ClimbCeiling", frames: walk.frames)
        copy.actions["GrabWall"] = Action(name: "GrabWall", frames: stand.frames)
        copy.actions["GrabCeiling"] = Action(name: "GrabCeiling", frames: stand.frames)
        copy.wallReach = 0
        copy.climbsByWalking = true
        return copy
    }

    /// Anchors measured from the art instead of trusted from the pack: a
    /// frame standing on something (anchor at the frame's bottom) anchors at
    /// its lowest visible pixel, one hanging from the ceiling (anchor in the
    /// top half) at its highest. `rows` gives each image's visible top and
    /// bottom in a 128-pt frame. Ledge sits (anchor 112) keep theirs, so
    /// legs still hang over the edge.
    func aligned(_ rows: [String: (top: CGFloat, bottom: CGFloat)]) -> Moves {
        var copy = self
        copy.actions = actions.mapValues { a in
            Action(name: a.name, frames: a.frames.map { f in
                guard let row = rows[f.image] else { return f }
                var f = f
                if f.anchor.y >= 124 { f.anchor.y = row.bottom } else if f.anchor.y <= 64 { f.anchor.y = row.top }
                return f
            })
        }
        return copy
    }

    private static func f(_ n: Int, _ ticks: Double, anchor: CGFloat = 128, ay: CGFloat? = nil, vx: CGFloat = 0, vy: CGFloat = 0) -> Frame {
        Frame(image: "shime\(n).png", seconds: ticks * 0.04, anchor: CGPoint(x: 64, y: ay ?? anchor), velocity: CGPoint(x: vx, y: vy))
    }

    /// Shimeji-ee's default actions.xml (frame numbers, ticks, anchors, velocities).
    static let defaults: [Action] = [
        Action(name: "Stand", frames: [f(1, 250)]),
        Action(name: "Walk", frames: [1, 2, 1, 3].map { f($0, 6, vx: -2) }),
        Action(name: "Run", frames: [1, 2, 1, 3].map { f($0, 2, vx: -4) }),
        Action(name: "Dash", frames: [1, 2, 1, 3].map { f($0, 2, vx: -8) }),
        Action(name: "Sit", frames: [f(11, 250)]),
        Action(name: "SitAndLookUp", frames: [f(26, 250)]),
        Action(name: "SitAndSpinHead", frames: [26, 15, 27, 16, 28, 17, 29, 11].map { f($0, 5) }),
        Action(name: "SitAndDangleLegs", frames: [f(31, 5, anchor: 112), f(32, 15, anchor: 112), f(31, 5, anchor: 112), f(33, 15, anchor: 112)]),
        Action(name: "Sprawl", frames: [f(21, 250)]),
        Action(name: "Creep", frames: [f(20, 28), f(20, 4, vx: -2), f(21, 4, vx: -2), f(21, 4, vx: -1), f(21, 24)]),
        Action(name: "GrabCeiling", frames: [f(23, 250, anchor: 48)]),
        Action(name: "ClimbCeiling", frames: [f(25, 16, anchor: 48), f(25, 4, anchor: 48, vx: -1), f(23, 4, anchor: 48, vx: -1),
                                              f(24, 4, anchor: 48, vx: -1), f(24, 16, anchor: 48), f(24, 4, anchor: 48, vx: -2),
                                              f(23, 4, anchor: 48, vx: -2), f(25, 4, anchor: 48, vx: -2)]),
        Action(name: "GrabWall", frames: [f(13, 250)]),
        Action(name: "ClimbWall", frames: [f(14, 16), f(14, 4, vy: -1), f(12, 4, vy: -1), f(13, 4, vy: -1), f(13, 16),
                                           f(13, 4, vy: -2), f(12, 4, vy: -2), f(14, 4, vy: -2)]),
        Action(name: "Jumping", frames: [f(22, 250)]),
        Action(name: "Falling", frames: [f(4, 250)]),
        Action(name: "Bouncing", frames: [f(18, 4), f(19, 4)]),
        Action(name: "Tripping", frames: [f(19, 8, vx: -8), f(18, 4, vx: -4), f(20, 4, vx: -2), f(20, 10), f(19, 4, anchor: 104)]),
    ]

    /// The shortest a frame of these gaits may show, in seconds.
    static let leastFrame: [String: Double] = ["Walk": 0.2, "Run": 0.08, "Dash": 0.08, "Creep": 0.12, "ClimbWall": 0.12, "ClimbCeiling": 0.12]

    /// Names in actions.xml that are wiring rather than something to show.
    static let plumbing: Set<String> = [
        "Look", "Offset", "Fall", "Dragged", "Thrown", "Pinched", "Resisting", "StandUp", "SitDown", "LieDown",
        "SitWhileDanglingLegs", "HoldOntoWall", "FallFromWall", "HoldOntoCeiling", "FallFromCeiling",
        "WalkAlongWorkAreaFloor", "RunAlongWorkAreaFloor", "CrawlAlongWorkAreaFloor", "ClimbAlongWall",
        "ClimbAlongCeiling", "ClimbHalfwayAlongWall", "ChaseMouse", "SitAndFaceMouse", "SitAndLookAtMouse",
        "SitAndSpinHeadAction", "SitWithLegsUp", "SitWithLegsDown", "Splat", "Divide1", "Divided", "SplitIntoTwo",
        "PullUp", "PullUpShimeji", "PullUpShimeji1", "PullUpShimeji2", "FallWithIe", "WalkWithIe", "RunWithIe", "ThrowIe",
    ]
}

// MARK: World and state

enum Surface: Equatable {
    case floor
    case wall(left: Bool)
    case ceiling
    /// The top edge of a window, by window number.
    case window(Int)
    case air
}

struct Platform: Equatable {
    let id: Int
    var minX: CGFloat
    var maxX: CGFloat
    var y: CGFloat
}

struct World {
    var minX: CGFloat
    var maxX: CGFloat
    /// The Dock band's walking line.
    var floor: CGFloat
    /// The top edge of the screen (the menu bar hangs from it).
    var ceiling: CGFloat
    /// The front window's top edge, if there is one to stand on.
    var windows: [Platform] = []
    /// Where to hang beside the notch, if this screen has one.
    var notchX: CGFloat?
    /// The notch's span and depth: anything hanging inside it is hidden.
    var notch: ClosedRange<CGFloat>?
    var notchDepth: CGFloat = 0
    /// The Dock's icons: walked across, never stopped on (clicks there go to the Dock).
    var dock: ClosedRange<CGFloat>?
    var size: CGFloat

    /// Where a mascot's anchor may be along the floor or a ceiling.
    var lane: ClosedRange<CGFloat> { (minX + size * 0.5)...max(minX + size * 0.5, maxX - size * 0.5) }

    func clampX(_ x: CGFloat) -> CGFloat { min(max(x, lane.lowerBound), lane.upperBound) }

    func platform(_ id: Int) -> Platform? { windows.first { $0.id == id } }

    /// Pixels a second squared at this size (Shimeji: 2 px per tick per tick at 128).
    var gravity: CGFloat { 1250 * size / 128 }
}

enum ClaudeMood: Equatable { case none, working, waiting, done }

/// What the rest of the Mac is doing, as the brain sees it.
struct Signals: Equatable {
    var musicPlaying = false
    var claude = ClaudeMood.none
    var claudeX: CGFloat?
    var idleSeconds: Double = 0
    var typing = false
    var lowBattery = false
    var hot = false
    /// A fresh download or screenshot, at this x.
    var attentionX: CGFloat?
    /// Following the pointer: its x.
    var followX: CGFloat?
    /// Other mascots standing on the floor, by x.
    var others: [CGFloat] = []
}

struct MascotState: Equatable {
    var position: CGPoint
    var surface: Surface
    var facingRight = false
    var asleep = false
}

enum Step: Equatable {
    /// Plays an action in place.
    case play(String, seconds: Double)
    /// Moves in a straight line along the current surface.
    case move(String, to: CGPoint, seconds: Double)
    /// A flight path (fall, jump, throw), sampled every `dt`, ending on `landing`.
    case flight(String, path: [CGPoint], dt: Double, landing: Surface)
    case face(right: Bool)
    case surface(Surface)
    case sleep(Bool)
}

// MARK: Random numbers

/// SplitMix64: seedable, so tests can replay a run.
struct Dice: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

// MARK: Physics

enum Physics {
    /// Simulates a body from `start` with `velocity` (points a second) under
    /// gravity: bounces off the screen's sides and the ceiling, lands on the
    /// floor or a window top it comes down onto. Returns the sampled path.
    static func fly(from start: CGPoint, velocity: CGVector, world: World, dt: Double = 1.0 / 30) -> (path: [CGPoint], landing: Surface) {
        var p = start, v = velocity
        if !p.x.isFinite || !p.y.isFinite { p = CGPoint(x: world.clampX(world.minX), y: world.floor) }
        if !v.dx.isFinite || !v.dy.isFinite { v = .zero }
        // A throw can be fast; cap it so a flick never leaves the screen in one step.
        let cap = world.size * 40
        v.dx = min(max(v.dx, -cap), cap)
        v.dy = min(max(v.dy, -cap), cap)
        p.x = world.clampX(p.x)
        p.y = min(max(p.y, world.floor), world.ceiling)
        var path = [p]
        let step = 1.0 / 120
        var t = 0.0, sinceSample = 0.0
        let g = world.gravity
        while t < 8 {
            t += step
            sinceSample += step
            let prevY = p.y
            v.dy -= g * step
            p.x += v.dx * step
            p.y += v.dy * step
            if p.x < world.lane.lowerBound { p.x = world.lane.lowerBound; v.dx = -v.dx * 0.5 }
            if p.x > world.lane.upperBound { p.x = world.lane.upperBound; v.dx = -v.dx * 0.5 }
            if p.y > world.ceiling { p.y = world.ceiling; v.dy = -abs(v.dy) * 0.3 }
            if v.dy < 0 {
                for w in world.windows where p.x >= w.minX && p.x <= w.maxX && prevY >= w.y && p.y <= w.y {
                    path.append(CGPoint(x: p.x, y: w.y))
                    return (path, .window(w.id))
                }
                if p.y <= world.floor {
                    path.append(CGPoint(x: p.x, y: world.floor))
                    return (path, .floor)
                }
            }
            if sinceSample >= dt {
                sinceSample = 0
                path.append(p)
            }
        }
        path.append(CGPoint(x: p.x, y: world.floor))
        return (path, .floor)
    }

    /// The launch velocity for an arc from `a` to `b` peaking `lift` above the higher end.
    static func launch(from a: CGPoint, to b: CGPoint, lift: CGFloat, gravity g: CGFloat) -> CGVector {
        let apex = max(a.y, b.y) + max(lift, 1)
        let up = sqrt(2 * g * (apex - a.y))
        let t = up / g + sqrt(2 * (apex - b.y) / g)
        guard t.isFinite, t > 0 else { return .zero }
        return CGVector(dx: (b.x - a.x) / t, dy: up)
    }
}

// MARK: Decisions

enum Brain {
    static let sleepAfter: Double = 120

    /// The next few steps for a mascot standing, sitting or lying somewhere;
    /// never empty, so the player always has something to do.
    static func decide(_ s: MascotState, world w: World, signals: Signals, moves m: Moves, dice d: inout Dice) -> [Step] {
        var plan = plan(s, world: w, signals: signals, moves: m, dice: &d)
        if plan.isEmpty { plan = [.play("Stand", seconds: 1)] }
        return spaced(offDock(plan, from: s, world: w, moves: m), from: s, others: signals.others, world: w, moves: m)
    }

    /// A free spot on the floor near `x`: a body-width from every other
    /// buddy and off the Dock's icons; `x` itself when it is free.
    static func freeSpot(near x: CGFloat, others: [CGFloat], world w: World) -> CGFloat {
        let gap = w.size * 0.9, margin = w.size * 0.6
        func free(_ c: CGFloat) -> Bool {
            if others.contains(where: { abs($0 - c) < gap }) { return false }
            if let d = w.dock, c > d.lowerBound - margin, c < d.upperBound + margin { return false }
            return w.lane.contains(c)
        }
        if free(x) { return x }
        for k in 1...40 {
            for c in [x + CGFloat(k) * w.size * 0.5, x - CGFloat(k) * w.size * 0.5] where free(c) { return c }
        }
        return x
    }

    /// Never stop on top of another buddy: a walk ending there ends at the
    /// nearest free spot, and staying put (over a second) where another one
    /// is starts with stepping aside.
    static func spaced(_ plan: [Step], from s: MascotState, others: [CGFloat], world w: World, moves m: Moves) -> [Step] {
        guard !others.isEmpty else { return plan }
        var out: [Step] = []
        var here = s.position
        var onFloor = s.surface == .floor
        let crowded = { (x: CGFloat) in others.contains { abs($0 - x) < w.size * 0.9 } }
        // How long it stays put from step i on (short poses in a row, like a
        // sway to music, add up).
        func still(from i: Int) -> Double {
            var t = 0.0
            for step in plan[i...] {
                switch step {
                case .play(_, let seconds): t += seconds
                case .move, .flight: return t
                default: continue
                }
            }
            return t
        }
        for (i, step) in plan.enumerated() {
            switch step {
            case .move(let name, let to, let seconds) where onFloor && to.y == w.floor && !["ClimbWall", "ClimbCeiling"].contains(name):
                // Only where the walk ends matters; check the next stop.
                let stops = plan[(i + 1)...].first { if case .play(_, let t) = $0 { return t > 1 }; if case .move = $0 { return false }; return false } != nil
                var x = to.x
                if stops, crowded(x) { x = freeSpot(near: x, others: others, world: w) }
                let k = abs(to.x - here.x) > 0.5 ? abs(x - here.x) / abs(to.x - here.x) : 1
                out += [.face(right: x > here.x), .move(name, to: CGPoint(x: x, y: to.y), seconds: seconds * Double(k))]
                here = CGPoint(x: x, y: to.y)
            case .play where onFloor && crowded(here.x) && still(from: i) > 1:
                let x = freeSpot(near: here.x, others: others, world: w)
                if abs(x - here.x) > 0.5 {
                    let speed = max(m.action("Walk").speed(size: w.size), w.size * 0.2)
                    out += [.face(right: x > here.x), .move("Walk", to: CGPoint(x: x, y: w.floor), seconds: Double(abs(x - here.x) / speed))]
                    here = CGPoint(x: x, y: w.floor)
                }
                out.append(step)
            case .flight(_, let path, _, let landing):
                out.append(step)
                here = path.last ?? here
                onFloor = landing == .floor
            case .surface(let surface):
                out.append(step)
                onFloor = surface == .floor
            case .move(_, let to, _):
                out.append(step)
                here = to
            default:
                out.append(step)
            }
        }
        return out
    }

    /// Never stop over the Dock's icons: a walk that would end there ends
    /// beside them, and staying put there (over a second) starts with stepping off.
    static func offDock(_ plan: [Step], from s: MascotState, world w: World, moves m: Moves) -> [Step] {
        guard let dock = w.dock else { return plan }
        let margin = w.size * 0.6
        func outside(_ x: CGFloat, toward from: CGFloat) -> CGFloat {
            let lo = dock.lowerBound - margin, hi = dock.upperBound + margin
            guard x > lo, x < hi else { return x }
            // The nearer side, preferring the side it comes from.
            let left = from <= dock.lowerBound ? true : from >= dock.upperBound ? false : x - lo < hi - x
            let edge = left ? lo : hi
            return min(max(edge, w.lane.lowerBound), w.lane.upperBound)
        }
        var out: [Step] = []
        var here = s.position
        var onFloor = s.surface == .floor
        for step in plan {
            switch step {
            case .move(let name, let to, let seconds) where onFloor && to.y == w.floor && !["ClimbWall", "ClimbCeiling"].contains(name):
                let x = outside(to.x, toward: here.x)
                let k = abs(to.x - here.x) > 0.5 ? abs(x - here.x) / abs(to.x - here.x) : 1
                out += [.face(right: x > here.x), .move(name, to: CGPoint(x: x, y: to.y), seconds: seconds * Double(k))]
                here = CGPoint(x: x, y: to.y)
            // A landing's short bounce may happen there; anything longer may not.
            case .play(_, let seconds) where seconds > 1 && onFloor && here.x > dock.lowerBound - margin && here.x < dock.upperBound + margin:
                let x = outside(here.x, toward: here.x)
                let speed = max(m.action("Walk").speed(size: w.size), w.size * 0.2)
                out += [.face(right: x > here.x), .move("Walk", to: CGPoint(x: x, y: w.floor), seconds: Double(abs(x - here.x) / speed)), step]
                here = CGPoint(x: x, y: w.floor)
            case .flight(_, let path, _, let landing):
                out.append(step)
                here = path.last ?? here
                onFloor = landing == .floor
            case .surface(let surface):
                out.append(step)
                onFloor = surface == .floor
            case .move(_, let to, _):
                out.append(step)
                here = to
            default:
                out.append(step)
            }
        }
        return out
    }

    private static func plan(_ s: MascotState, world w: World, signals: Signals, moves m: Moves, dice d: inout Dice) -> [Step] {
        let size = w.size
        let here = s.position
        // Anywhere but the floor or a window top, finish the climb by letting go.
        switch s.surface {
        case .wall, .ceiling, .air:
            return letGo(from: here, world: w)
        case .window(let id) where w.platform(id) == nil:
            return letGo(from: here, world: w)
        default: break
        }
        let ground = s.surface == .floor ? w.floor : (w.platform(id(of: s.surface)).map(\.y) ?? w.floor)
        let along: ClosedRange<CGFloat> = {
            guard case .window(let id) = s.surface, let p = w.platform(id) else { return w.lane }
            let lo = max(p.minX + size * 0.3, w.lane.lowerBound), hi = min(p.maxX - size * 0.3, w.lane.upperBound)
            return lo <= hi ? lo...hi : here.x...here.x
        }()
        func clamp(_ x: CGFloat) -> CGFloat { min(max(x, along.lowerBound), along.upperBound) }
        func go(_ x: CGFloat, _ gait: String = "Walk") -> [Step] {
            let x = clamp(x)
            let gait = m.has(gait) ? gait : "Walk"
            let speed = max(m.action(gait).speed(size: size), size * 0.2)
            let seconds = Double(abs(x - here.x) / speed)
            guard seconds > 0.05 else { return [] }
            return [.face(right: x > here.x), .move(gait, to: CGPoint(x: x, y: ground), seconds: seconds)]
        }
        func sit(_ name: String, _ r: ClosedRange<Double>, _ d: inout Dice) -> [Step] {
            [.play(m.has(name) ? name : "Sit", seconds: d.range(r))]
        }

        // Asleep: stays down until the Mac is used again, then stretches.
        if s.asleep {
            if signals.idleSeconds < 3 { return [.sleep(false), .play(m.has("Jumping") ? "Jumping" : "Stand", seconds: 0.6), .play("Stand", seconds: 0.6)] }
            return [.play(m.has("Sprawl") ? "Sprawl" : "Sit", seconds: 3)]
        }
        if signals.idleSeconds > sleepAfter, signals.followX == nil, signals.claude != .waiting {
            let yawn = m.extras.first { $0.lowercased().contains("sleep") || $0.lowercased().contains("yawn") }
            return [.play(yawn ?? (m.has("SitAndLookUp") ? "SitAndLookUp" : "Sit"), seconds: 2.5), .sleep(true),
                    .play(m.has("Sprawl") ? "Sprawl" : "Sit", seconds: 3)]
        }
        // Following the pointer: run after it.
        if let fx = signals.followX {
            if abs(clamp(fx) - here.x) > size * 0.4 { return go(fx, abs(fx - here.x) > size * 3 ? "Run" : "Walk") }
            return [.face(right: fx > here.x), .play("Stand", seconds: 0.4)]
        }
        // Claude needs you: run over and jump for attention.
        if signals.claude == .waiting, s.surface == .floor {
            if let cx = signals.claudeX, abs(clamp(cx) - here.x) > size * 0.6 { return go(cx, "Run") }
            // A burst of hops now and then, else sit and look up: a long wait
            // shouldn't mean hopping nonstop.
            if d.chance(0.25) { return hops(at: here, count: 2, world: w, moves: m) + [.play(m.has("SitAndLookUp") ? "SitAndLookUp" : "Stand", seconds: 1.2)] }
            return sit("SitAndLookUp", 6...12, &d)
        }
        if signals.claude == .working, s.surface == .floor, let cx = signals.claudeX {
            if abs(clamp(cx) - here.x) > size * 1.5 { return go(cx + (d.chance(0.5) ? -1 : 1) * size * 0.8) }
            // Pace beside the widget, or sit and watch it.
            if d.chance(0.5) { return go(here.x + (d.chance(0.5) ? -1 : 1) * size * d.range(0.6...1.4)) }
            return [.face(right: cx > here.x)] + sit("SitAndLookUp", 3...6, &d)
        }
        // A new download or screenshot: go and look at it.
        if let ax = signals.attentionX, s.surface == .floor {
            if abs(clamp(ax) - here.x) > size * 0.8 { return go(ax, "Run") }
            return [.face(right: ax > here.x)] + sit("SitAndLookUp", 3...5, &d)
        }
        if signals.typing, d.chance(0.6) { return sit("SitAndLookUp", 2...4, &d) }
        if signals.musicPlaying, d.chance(0.7) {
            // Dance: the pack's own dance, spinning its head, hopping, or
            // swaying side to side (the beat bops it on top).
            let r = d.unit()
            if let dance = m.extras.first(where: { $0.lowercased().contains("dance") }), r < 0.4 {
                return [.play(dance, seconds: max(m.action(dance).duration, 3))]
            }
            if r < 0.6, m.has("SitAndSpinHead") { return [.play("SitAndSpinHead", seconds: 4.8)] }
            if r < 0.75, s.surface == .floor { return hops(at: here, count: 2, world: w, moves: m) }
            var sway: [Step] = []
            for i in 0..<Int(d.range(3...6)) { sway += [.face(right: i % 2 == 0), .play("Stand", seconds: 0.5)] }
            return sway
        }
        if signals.hot, d.chance(0.4) { return sit("Sprawl", 4...7, &d) }
        // Another buddy close by: face it and sit together.
        if s.surface == .floor, let other = signals.others.min(by: { abs($0 - here.x) < abs($1 - here.x) }),
           abs(other - here.x) < size * 2.2, abs(other - here.x) >= size * 0.9, d.chance(0.35) {
            return [.face(right: other > here.x)] + sit("Sit", 4...8, &d)
        }
        if signals.lowBattery, d.chance(0.5) { return sit(d.chance(0.5) ? "Sprawl" : "Sit", 5...10, &d) }

        let r = d.unit()
        // On a window: walk along it, dangle legs at an edge, or get down.
        if case .window(let id) = s.surface, let p = w.platform(id) {
            if r < 0.3 { return go(d.range(Double(along.lowerBound)...Double(along.upperBound))) }
            if r < 0.5, m.has("SitAndDangleLegs") {
                let edge = d.chance(0.5) ? along.lowerBound : along.upperBound
                return go(edge) + [.face(right: edge == along.upperBound)] + sit("SitAndDangleLegs", 10...20, &d)
            }
            if r < 0.65 { return sit("Sit", 8...16, &d) }
            if r < 0.85 {
                // Jump down to the floor beside the window.
                let x = d.chance(0.5) ? p.minX - size : p.maxX + size
                let target = CGPoint(x: w.clampX(x), y: w.floor)
                return jump(from: here, to: target, lift: size * 0.6, world: w, moves: m)
            }
            return [.play("Stand", seconds: d.range(1...3))]
        }
        // On the floor.
        let window = w.windows.first
        if let p = window, r < 0.02 {
            // Visit the front window: jump up when it is low enough, climb otherwise.
            let x = clamp(here.x < p.minX ? p.minX - size * 0.4 : here.x > p.maxX ? p.maxX + size * 0.4 : here.x)
            let top = CGPoint(x: min(max(x, p.minX + size * 0.5), p.maxX - size * 0.5), y: p.y)
            if p.y - w.floor < size * 8, m.has("Jumping") {
                return go(x) + jump(from: CGPoint(x: x, y: w.floor), to: top, lift: size * 0.5, world: w, moves: m)
            }
            if m.canClimb { return climb(from: here, toCeilingX: top.x, thenHang: false, world: w, moves: m, dice: &d) }
        }
        if r < 0.05, m.canClimb, w.notch != nil {
            return notchVisit(from: here, world: w, moves: m, dice: &d)
        }
        if r < 0.4 { return go(here.x + CGFloat(d.range(-400...400)) * size / 64) }
        if r < 0.44 {
            let steps = go(here.x + CGFloat(d.range(-600...600)) * size / 64, "Run")
            if m.has("Tripping"), d.chance(0.3), case .move(_, let to, _) = steps.last {
                return steps + [.play("Tripping", seconds: m.action("Tripping").duration), .play(m.has("Sprawl") ? "Sprawl" : "Sit", seconds: 1),
                                .play("Stand", seconds: 0.5), .face(right: to.x > here.x)]
            }
            return steps
        }
        if r < 0.46, m.has("Creep") { return go(here.x + CGFloat(d.range(-160...160)) * size / 64, "Creep") }
        if r < 0.48 { return hops(at: here, count: 1, world: w, moves: m) }
        if r < 0.51, let extra = m.extras.randomElement(using: &d) {
            return [.play(extra, seconds: max(m.action(extra).duration, 1.5))]
        }
        if r < 0.75 { return sit("Sit", 10...25, &d) }
        if r < 0.77 { return sit("SitAndSpinHead", 2.4...4.8, &d) }
        return [.play("Stand", seconds: d.range(4...10))]
    }

    private static func id(of surface: Surface) -> Int {
        if case .window(let id) = surface { return id }
        return -1
    }

    /// Runs out of the pointer's way along the floor: three widths away from
    /// it on its own side (past the Dock's icons if they are in the way), or
    /// past the pointer when cornered against the screen edge.
    static func flee(_ s: MascotState, from px: CGFloat, world w: World, moves m: Moves) -> [Step] {
        let margin = w.size * 0.6
        // Three widths that way; across the Dock's icons if that lands on them.
        func spot(_ dir: CGFloat) -> CGFloat {
            var x = w.clampX(px + dir * w.size * 3)
            if let d = w.dock, x > d.lowerBound - margin, x < d.upperBound + margin {
                x = w.clampX(dir > 0 ? d.upperBound + margin : d.lowerBound - margin)
            }
            return x
        }
        func good(_ x: CGFloat) -> Bool {
            let onDock = w.dock.map { x > $0.lowerBound - margin && x < $0.upperBound + margin } ?? false
            return abs(x - px) >= w.size * 2 && !onDock
        }
        let away: CGFloat = s.position.x >= px ? 1 : -1
        var x = spot(away)
        if !good(x), good(spot(-away)) { x = spot(-away) }
        let gait = m.has("Run") ? "Run" : "Walk"
        let speed = max(m.action(gait).speed(size: w.size), w.size * 0.5) * 1.6
        let plan: [Step] = [.face(right: x > s.position.x),
                            .move(gait, to: CGPoint(x: x, y: w.floor), seconds: Double(abs(x - s.position.x) / speed)),
                            .face(right: px > x), .play("Stand", seconds: 1.5)]
        return offDock(plan, from: s, world: w, moves: m)
    }

    /// Drops from wherever it is.
    static func letGo(from p: CGPoint, world w: World) -> [Step] {
        let f = Physics.fly(from: p, velocity: .zero, world: w)
        return [.surface(.air), .flight("Falling", path: f.path, dt: 1.0 / 30, landing: f.landing)] + landing(f.landing, world: w)
    }

    /// What follows touching down.
    static func landing(_ surface: Surface, world w: World) -> [Step] {
        [.surface(surface), .play("Bouncing", seconds: 0.32), .play("Stand", seconds: 0.4)]
    }

    static func jump(from a: CGPoint, to b: CGPoint, lift: CGFloat, world w: World, moves m: Moves) -> [Step] {
        let v = Physics.launch(from: a, to: b, lift: lift, gravity: w.gravity)
        let f = Physics.fly(from: a, velocity: v, world: w)
        return [.face(right: b.x > a.x), .surface(.air), .flight(m.has("Jumping") ? "Jumping" : "Falling", path: f.path, dt: 1.0 / 30, landing: f.landing)]
            + landing(f.landing, world: w)
    }

    /// Small hops in place.
    static func hops(at p: CGPoint, count: Int, world w: World, moves m: Moves) -> [Step] {
        var steps: [Step] = []
        for _ in 0..<count {
            let up = Physics.launch(from: p, to: p, lift: w.size * 0.45, gravity: w.gravity)
            let f = Physics.fly(from: p, velocity: up, world: w)
            steps += [.flight(m.has("Jumping") ? "Jumping" : "Stand", path: f.path, dt: 1.0 / 30, landing: f.landing), .surface(f.landing)]
        }
        return steps
    }

    /// Walks to the nearer screen side, climbs it, crawls along under the
    /// menu bar to `x`, then hangs there for a while or lets go.
    static func climb(from p: CGPoint, toCeilingX x: CGFloat, thenHang hang: Bool, world w: World, moves m: Moves, dice d: inout Dice) -> [Step] {
        let size = w.size
        let left = abs(p.x - w.lane.lowerBound) < abs(p.x - w.lane.upperBound)
        // Hands on the screen edge: the anchor sits as far in as the climbing
        // frames' visible pixels reach toward the wall.
        let reach = m.wallReach * size
        let wallX = left ? w.minX + reach : w.maxX - reach
        let walk = max(m.action("Walk").speed(size: size), size * 0.2)
        // Shimeji's own pace takes most of a minute up a screen; keep it brisk.
        let climb = max(m.action("ClimbWall").speed(size: size) * 1.5, (w.ceiling - w.floor) / 20)
        let target = w.clampX(x)
        // Stop on the floor fully on screen, step onto the wall, climb to the
        // top, step onto the ceiling, then crawl along it: no diagonal slides.
        // Climbing by walking turns the sprite onto the surface, so it keeps
        // half a body from the floor and the ceiling while on the wall, and
        // reaches the ceiling a half body in from the side.
        let floorX = left ? w.lane.lowerBound : w.lane.upperBound
        let half = size * 0.5
        let low = m.climbsByWalking ? w.floor + half : w.floor
        let top = m.climbsByWalking ? w.ceiling - half : w.ceiling - size * 0.6
        let ceilingX = m.climbsByWalking ? floorX : wallX
        let steps: [Step] = [
            .face(right: !left),
            .move("Walk", to: CGPoint(x: floorX, y: w.floor), seconds: Double(abs(floorX - p.x) / walk)),
            .surface(.wall(left: left)), .face(right: !left),
            .move("GrabWall", to: CGPoint(x: wallX, y: low), seconds: 0.15),
            .play("GrabWall", seconds: 0.4),
            .move("ClimbWall", to: CGPoint(x: wallX, y: top), seconds: Double((top - low) / climb)),
            .surface(.ceiling), .face(right: target > ceilingX),
            .move("GrabCeiling", to: CGPoint(x: ceilingX, y: w.ceiling), seconds: 0.15),
        ] + crawlCeiling(from: ceilingX, to: target, world: w, moves: m)
        var route = steps
        if hang { route.append(.play("GrabCeiling", seconds: d.range(5...10))) }
        var end = CGPoint(x: target, y: w.ceiling)
        if case .move(_, let to, _)? = steps.last { end = to }
        let f = Physics.fly(from: end, velocity: .zero, world: w)
        route += [.surface(.air), .flight("Falling", path: f.path, dt: 1.0 / 30, landing: f.landing)] + landing(f.landing, world: w)
        return route
    }

    /// Climbs up, crawls into the notch and hides there, peeks out of its
    /// sides a few times, then comes out and lets go. Hidden means above the
    /// screen's top edge, or inside the notch's band where there are no pixels.
    static func notchVisit(from p: CGPoint, world w: World, moves m: Moves, dice d: inout Dice) -> [Step] {
        guard let n = w.notch, n.upperBound - n.lowerBound > w.size else { return [] }
        let size = w.size, half = size * 0.5
        var route = climb(from: p, toCeilingX: p.x < n.lowerBound ? n.lowerBound - half : n.upperBound + half,
                          thenHang: false, world: w, moves: m, dice: &d)
        // Keep the climb, drop its fall.
        if let i = route.firstIndex(of: .surface(.air)) { route.removeSubrange(i...) }
        let mid = (n.lowerBound + n.upperBound) / 2
        // Inside the band: the sprite's lowest pixel is at the notch's bottom.
        let tucked = w.ceiling - w.notchDepth + size
        let crawl = "ClimbCeiling"
        let fromLeft = p.x < n.lowerBound
        route += [
            .face(right: fromLeft),
            .move(crawl, to: CGPoint(x: fromLeft ? n.lowerBound + half : n.upperBound - half, y: w.ceiling), seconds: 0.8),
            .move(crawl, to: CGPoint(x: mid, y: tucked), seconds: 0.6),
            .move(crawl, to: CGPoint(x: mid, y: w.ceiling + size), seconds: 0.3),
            .play("GrabCeiling", seconds: d.range(6...14)),
        ]
        for _ in 0..<Int(d.range(2...4)) {
            // Lean three quarters of a body out of a side, dipping below the
            // notch, or drop the head straight out of its bottom.
            let side = d.chance(0.7), left = d.chance(0.5)
            let inside = side ? CGPoint(x: left ? n.lowerBound + half : n.upperBound - half, y: tucked)
                : CGPoint(x: mid + CGFloat(d.range(-1...1)) * (n.upperBound - n.lowerBound - size) / 2, y: tucked)
            let out = side ? CGPoint(x: inside.x + (left ? -size * 0.75 : size * 0.75), y: tucked - size * 0.25)
                : CGPoint(x: inside.x, y: tucked - size * 0.55)
            route += [
                .move(crawl, to: inside, seconds: 0.4),
                .face(right: side ? !left : d.chance(0.5)),
                .move(crawl, to: out, seconds: 0.5),
                .play("GrabCeiling", seconds: d.range(2...4)),
                .move(crawl, to: inside, seconds: 0.4),
                .move(crawl, to: CGPoint(x: mid, y: w.ceiling + size), seconds: 0.3),
                .play("GrabCeiling", seconds: d.range(4...10)),
            ]
        }
        // Out a side, then crawl a random way along the top before dropping.
        let left = d.chance(0.5)
        let exit = w.clampX(left ? CGFloat(d.range(Double(w.lane.lowerBound)...Double(max(w.lane.lowerBound, n.lowerBound - size))))
                                 : CGFloat(d.range(Double(min(w.lane.upperBound, n.upperBound + size))...Double(w.lane.upperBound))))
        route += [
            .move(crawl, to: CGPoint(x: left ? n.lowerBound + half : n.upperBound - half, y: tucked), seconds: 0.4),
            .face(right: !left),
            .move(crawl, to: CGPoint(x: left ? n.lowerBound + half : n.upperBound - half, y: w.ceiling), seconds: 0.3),
            .move(crawl, to: CGPoint(x: exit, y: w.ceiling), seconds: Double(abs(exit - (left ? n.lowerBound : n.upperBound)) / max(m.action(crawl).speed(size: size), size * 0.75)) + 0.3),
            .play("GrabCeiling", seconds: d.range(1...3)),
        ]
        let f = Physics.fly(from: CGPoint(x: exit, y: w.ceiling), velocity: .zero, world: w)
        return route + [.surface(.air), .flight("Falling", path: f.path, dt: 1.0 / 30, landing: f.landing)] + landing(f.landing, world: w)
    }

    /// Crawls along the top edge; past the notch it steps down onto the
    /// notch's underside, crawls under it and steps back up.
    static func crawlCeiling(from x0: CGFloat, to x1: CGFloat, world w: World, moves m: Moves) -> [Step] {
        let size = w.size, half = size * 0.5
        let crawl = max(m.action("ClimbCeiling").speed(size: size), size * 0.75)
        func go(_ a: CGFloat, _ b: CGFloat, _ y: CGFloat) -> Step {
            .move("ClimbCeiling", to: CGPoint(x: b, y: y), seconds: Double(abs(b - a) / crawl))
        }
        guard let n = w.notch, w.notchDepth > 0 else { return [go(x0, x1, w.ceiling)] }
        let lo = n.lowerBound - half, hi = n.upperBound + half
        let right = x1 > x0
        // Clear of the notch the whole way: straight along the top.
        if max(x0, x1) <= lo || min(x0, x1) >= hi { return [go(x0, x1, w.ceiling)] }
        let under = w.ceiling - w.notchDepth
        let (near, far) = right ? (lo, hi) : (hi, lo)
        let stepIn = right ? n.lowerBound + half : n.upperBound - half
        let stepOut = right ? n.upperBound - half : n.lowerBound + half
        var steps: [Step] = []
        var x = x0
        if right ? x0 < near : x0 > near {
            steps.append(go(x, near, w.ceiling))
            steps.append(.move("GrabCeiling", to: CGPoint(x: stepIn, y: under), seconds: 0.4))
            x = stepIn
        }
        // Ends under the notch: stay on its underside.
        if right ? x1 <= stepOut : x1 >= stepOut { return steps + [go(x, x1, under)] }
        steps.append(go(x, stepOut, under))
        steps.append(.move("GrabCeiling", to: CGPoint(x: far, y: w.ceiling), seconds: 0.4))
        steps.append(go(far, x1, w.ceiling))
        return steps
    }

    /// A throw: the path from where it was let go, with the release velocity.
    static func thrown(from p: CGPoint, velocity v: CGVector, world w: World) -> [Step] {
        let f = Physics.fly(from: p, velocity: v, world: w)
        return [.surface(.air), .flight("Falling", path: f.path, dt: 1.0 / 30, landing: f.landing)] + landing(f.landing, world: w)
    }

    /// The shortest a frame may show while a move is sped up; past this the
    /// stride stretches instead (fast climbs and crawls).
    static let quickestFrame = 0.05
    /// Gaits never cycle faster than the art's own timing (on the ground,
    /// up walls and along the top alike): a faster move stretches the stride.
    static let steadyGaits: Set<String> = ["Walk", "Run", "Dash", "Creep", "ClimbWall", "ClimbCeiling"]

    /// Position keys for moving from `p` to `q` in `seconds`, driven by each
    /// frame's velocity: frames with none hold still, the others cover the
    /// ground their velocity says. A whole number of cycles, the stride scaled
    /// by the leftover so the move ends exactly on `q`. A move planned faster
    /// than the art's pace runs the whole gait faster (legs too), down to
    /// `quickestFrame` a frame (ground gaits: never faster than drawn); a move
    /// too short for one cycle at that pace takes longer than `seconds`. `phase` is where in the cycle (seconds of the
    /// action's own timing) the legs already are. Nil when the action has no
    /// velocity or the input is unusable: play it as a straight tween.
    static func gaitKeys(_ a: Action, from p: CGPoint, to q: CGPoint, size: CGFloat, seconds: Double, phase: Double = 0) -> Gait? {
        let dist = Double(hypot(q.x - p.x, q.y - p.y))
        let cycle = a.duration
        let k = Double(size) / 128
        guard dist.isFinite, dist > 0.01, seconds.isFinite, seconds > 0, cycle.isFinite, cycle > 0, k.isFinite, k > 0 else { return nil }
        let frames = a.frames.filter { $0.seconds > 0 && $0.seconds.isFinite }
        let reach = frames.map { f -> Double in
            let v = Double(hypot(f.velocity.x, f.velocity.y))
            return v.isFinite ? v * f.seconds / 0.04 * k : 0
        }
        let stride = reach.reduce(0, +)
        guard stride > 0, let shortest = frames.map(\.seconds).min() else { return nil }
        // Whole cycles, as many as the ground asks for, but no more than fit
        // with every frame showing at least `quickestFrame` (ground gaits: at
        // least their own seconds).
        // A move too short for one cycle at that pace takes one cycle's time.
        let steady = steadyGaits.contains(a.name)
        let least = max(quickestFrame / shortest, steady ? 1 : 0)
        let duration = max(seconds, cycle * least)
        // Ground gaits may run up to 15% quick rather than slide.
        let fit = max(1, (duration / (cycle * least) * (steady ? 1.15 : 1)).rounded(.down))
        let cycles = min(max(1, (dist / stride).rounded()), fit, 5000)
        let scale = dist / (stride * cycles)
        let timeScale = duration / (cycles * cycle)
        // Walk the frame timeline from `phase` for `cycles` loops: knots of
        // (time, distance along the move).
        var i = 0, into = phase.isFinite ? phase.truncatingRemainder(dividingBy: cycle) : 0
        if into < 0 { into += cycle }
        while into >= frames[i].seconds, i < frames.count - 1 { into -= frames[i].seconds; i += 1 }
        into = min(into, frames[i].seconds)
        var knots = [(t: 0.0, d: 0.0)]
        var left = cycles * cycle, t = 0.0, d = 0.0
        while left > 1e-9 {
            let f = frames[i]
            let step = min(f.seconds - into, left)
            if step > 0 {
                t += step
                d += reach[i] * scale * step / f.seconds
                left -= step
                knots.append((t, d))
            }
            into = 0
            i = (i + 1) % frames.count
        }
        let total = cycles * cycle
        let dir = (x: Double(q.x - p.x) / dist, y: Double(q.y - p.y) / dist)
        var points: [CGPoint] = [], times: [Double] = []
        for (n, knot) in knots.enumerated() {
            let along = min(knot.d, dist)
            points.append(n == knots.count - 1 ? q : CGPoint(x: Double(p.x) + dir.x * along, y: Double(p.y) + dir.y * along))
            times.append(n == knots.count - 1 ? 1 : min(knot.t / total, 1))
        }
        return Gait(points: points, keyTimes: times, timeScale: timeScale, duration: duration)
    }

    /// Back-to-back moves of the same gait that carry on the same way (only
    /// turns that change nothing between them) become one move, so the legs
    /// cycle on unbroken instead of starting over at each join.
    static func coalesce(_ plan: [Step], from start: CGPoint) -> [Step] {
        var out: [Step] = []
        var here = start
        // The last move in `out` that may still grow, where it began, and
        // the facing it was played with (nil: unknown).
        var last: (index: Int, from: CGPoint, facing: Bool?)?
        var facing: Bool?
        func sameWay(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
            let u = (x: b.x - a.x, y: b.y - a.y), v = (x: c.x - b.x, y: c.y - b.y)
            let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
            guard lu > 0.01, lv > 0.01 else { return false }
            return abs(u.x * v.y - u.y * v.x) <= 0.01 * lu * lv && u.x * v.x + u.y * v.y > 0
        }
        for step in plan {
            switch step {
            case .move(let name, let to, let seconds):
                if let l = last, let f = l.facing, case .move(let prev, let mid, let before) = out[l.index], prev == name,
                   out[(l.index + 1)...].allSatisfy({ $0 == .face(right: f) }), sameWay(l.from, mid, to) {
                    // The turns in between change nothing: drop them.
                    out.removeSubrange((l.index + 1)...)
                    out[l.index] = .move(name, to: to, seconds: before + seconds)
                } else {
                    out.append(step)
                    last = (out.count - 1, here, facing)
                }
                here = to
            case .face(let right):
                out.append(step)
                facing = right
            case .flight(_, let path, _, _):
                out.append(step)
                here = path.last ?? here
                last = nil
            default:
                out.append(step)
                last = nil
            }
        }
        return out
    }
}
