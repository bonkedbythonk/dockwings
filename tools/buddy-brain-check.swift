// Randomised check of BuddyBrain.swift: plays plans out abstractly across
// random worlds, two pack shapes (all 46 frames, and the 6 of a one-sprite
// "sw-" pack) and random signals, and fails on any broken invariant.
// Run (top-level code needs the name main.swift):
//   mkdir -p /tmp/bbc && cp tools/buddy-brain-check.swift /tmp/bbc/main.swift &&
//   swiftc -O -o /tmp/bbc/run Sources/DockWings/BuddyBrain.swift /tmp/bbc/main.swift && /tmp/bbc/run
import CoreGraphics
import Foundation

var failures = 0
func fail(_ msg: String) {
    failures += 1
    if failures <= 20 { print("FAIL:", msg) }
}

let full = Moves(images: Set((1...46).map { "shime\($0).png" }))
let tiny = Moves(images: Set([1, 2, 3, 4, 11, 22].map { "shime\($0).png" }))
let extra = Moves(images: Set((1...46).map { "shime\($0).png" } + ["dance/shime1.png", "dance/shime2.png"]),
                  custom: [Action(name: "Dance", frames: [Frame(image: "dance/shime1.png", seconds: 0.2), Frame(image: "dance/shime2.png", seconds: 0.2)]),
                           Action(name: "Broken", frames: [Frame(image: "missing/shime1.png", seconds: 0.2)])])
assert(extra.extras == ["Dance"], "extras: \(extra.extras)")
assert(!tiny.canClimb && full.canClimb)

var dice = Dice(seed: 42)
let climbing: Set<String> = ["ClimbWall", "GrabWall", "ClimbCeiling", "GrabCeiling"]
var stepCount = 0, flights = 0, climbs = 0, windowLandings = 0, hangs = 0, extrasPlayed = 0
var seen: [String: Int] = [:]

for run in 0..<3000 {
    let size = CGFloat(dice.range(32...128))
    let width = CGFloat(dice.range(800...3000)), height = CGFloat(dice.range(600...1600))
    var world = World(minX: 0, maxX: width, floor: 11, ceiling: height, size: size)
    if dice.chance(0.6) {
        let minX = CGFloat(dice.range(0...Double(width - 200)))
        world.windows = [Platform(id: 7, minX: minX, maxX: min(width, minX + CGFloat(dice.range(150...1200))), y: CGFloat(dice.range(80...Double(height - 80))))]
    }
    if dice.chance(0.7) { world.notchX = width / 2 + 160; world.notch = (width / 2 - 95)...(width / 2 + 95); world.notchDepth = 32 }
    if dice.chance(0.8) { let c = width / 2; let half = min(CGFloat(dice.range(100...400)), width * 0.3); world.dock = (c - half)...(c + half) }
    // Dock bar: widgets inside the Dock, sometimes right against the screen
    // edge, on screens wide enough to leave free glass beside them.
    if dice.chance(0.5), width >= 1400 {
        let edge = CGFloat(dice.range(0...60)), w1 = CGFloat(dice.range(120...300)), w2 = CGFloat(dice.range(120...300))
        world.widgets = [edge...(edge + w1), (width - edge - w2)...(width - edge)]
    }
    let moves = [full, tiny, extra][run % 3]
    var state = MascotState(position: CGPoint(x: world.clampX(CGFloat(dice.range(0...Double(width)))), y: world.floor), surface: .floor)
    for _ in 0..<60 {
        var sig = Signals()
        sig.musicPlaying = dice.chance(0.3)
        sig.claude = [.none, .working, .waiting, .done][Int(dice.next() % 4)]
        sig.claudeX = dice.chance(0.8) ? CGFloat(dice.range(-50...Double(width + 50))) : nil
        sig.idleSeconds = dice.chance(0.1) ? 200 : dice.range(0...10)
        sig.typing = dice.chance(0.2)
        sig.lowBattery = dice.chance(0.1)
        sig.batteryX = dice.chance(0.5) ? CGFloat(dice.range(0...Double(width))) : nil
        sig.hot = dice.chance(0.1)
        sig.attentionX = dice.chance(0.1) ? CGFloat(dice.range(0...Double(width))) : nil
        sig.followX = dice.chance(0.1) ? CGFloat(dice.range(-100...Double(width + 100))) : nil
        sig.others = dice.chance(0.3) ? [state.position.x + CGFloat(dice.range(-200...200))] : []
        // Sometimes the window goes away under it.
        if dice.chance(0.05) { world.windows = [] }

        let plan = Brain.decide(state, world: world, signals: sig, moves: moves, dice: &dice)
        if plan.isEmpty { fail("empty plan") }
        for step in plan {
            stepCount += 1
            switch step {
            case .play(let name, let seconds):
                seen[name, default: 0] += 1
                if seconds > 1, state.surface == .floor, world.lane.upperBound - world.lane.lowerBound > size * 30,
                   sig.others.contains(where: { abs($0 - state.position.x) < size * 0.89 }),
                   // (Unless no free spot is left at all between the icons and widgets.)
                   Brain.freeSpot(near: state.position.x, others: sig.others, world: world) != state.position.x {
                    fail("\(name) on top of another buddy at \(state.position.x), others \(sig.others)")
                }
                if seconds > 1, state.surface == .floor, let dock = world.dock, state.position.x > dock.lowerBound, state.position.x < dock.upperBound {
                    fail("\(name) while standing over the Dock icons at \(state.position.x)")
                }
                // (Unless the widgets leave no free spot: then only the icons count.)
                let widgetsCount = world.widgets.allSatisfy { w in world.noStop.contains { $0.lowerBound <= w.lowerBound && $0.upperBound >= w.upperBound } }
                if seconds > 1, state.surface == .floor, widgetsCount, world.widgets.contains(where: { state.position.x > $0.lowerBound && state.position.x < $0.upperBound }) {
                    fail("\(name) while sitting on a widget at \(state.position.x)")
                }
                if !(seconds.isFinite && seconds > 0) { fail("play \(name) seconds \(seconds)") }
                if moves.has(name) == false, name != "Stand", moves.actions[name] != nil, !["Bouncing", "Sit", "SitAndLookUp", "Sprawl", "Jumping", "SitAndSpinHead"].contains(name) {
                    fail("play \(name) the pack lacks")
                }
                if moves.extras.contains(name) { extrasPlayed += 1 }
                if name == "GrabCeiling" { hangs += 1 }
            case .move(let name, let to, let seconds):
                seen[name, default: 0] += 1
                if climbing.contains(name) {
                    climbs += 1
                    if !moves.canClimb { fail("climb on a pack without climb frames") }
                }
                if !(seconds.isFinite && seconds >= 0 && seconds < 600) { fail("move \(name) seconds \(seconds)") }
                if !(to.x.isFinite && to.y.isFinite) { fail("move to NaN") }
                if to.x < world.minX - 1 || to.x > world.maxX + 1 || to.y < world.floor - 1 || to.y > world.ceiling + 1 {
                    // Above the top only in or peeking out of the notch, at most a body up.
                    let hidden = world.notch.map { abs(to.x - ($0.lowerBound + $0.upperBound) / 2) <= ($0.upperBound - $0.lowerBound) / 2 + world.size && to.y <= world.ceiling + world.size + 0.5 } ?? false
                    if !hidden { fail("move \(name) off screen \(to)") }
                }
                if state.surface == .floor, name != "ClimbWall", name != "ClimbCeiling", abs(to.y - world.floor) > 0.5 { fail("floor move leaves floor \(to.y)") }
                state.position = to
            case .flight(let name, let path, let dt, let landing):
                flights += 1
                seen[name, default: 0] += 1
                if path.isEmpty || !(dt > 0) { fail("empty flight") }
                for p in path where !(p.x.isFinite && p.y.isFinite) || p.x < world.minX - 1 || p.x > world.maxX + 1 || p.y < world.floor - 1 || p.y > world.ceiling + 1 {
                    fail("flight point off screen \(p)"); break
                }
                if Double(path.count) * dt > 9 { fail("flight too long \(path.count)") }
                let end = path.last!
                switch landing {
                case .floor: if abs(end.y - world.floor) > 0.5 { fail("floor landing at \(end.y)") }
                case .window(let id):
                    windowLandings += 1
                    if let p = world.platform(id) { if abs(end.y - p.y) > 0.5 || end.x < p.minX || end.x > p.maxX { fail("window landing off \(end)") } }
                    else { fail("landed on missing window") }
                default: fail("flight landed on \(landing)")
                }
                state.position = end
                state.surface = landing
            case .face(let right): state.facingRight = right
            case .surface(let s): state.surface = s
            case .sleep(let on): state.asleep = on
            }
        }
        if state.surface == .air { fail("plan ended in the air") }
        if case .wall = state.surface { fail("plan ended on a wall") }
        if state.surface == .ceiling { fail("plan ended on the ceiling") }
    }
}

// Fleeing the pointer: stays on the floor, on screen, ends away from the pointer
// (unless cornered), and never stops on the Dock icons.
for _ in 0..<20000 {
    let width = CGFloat(dice.range(800...3000)), size = CGFloat(dice.range(32...128))
    var w = World(minX: 0, maxX: width, floor: 0, ceiling: 900, size: size)
    w.dock = (width * 0.3)...(width * 0.7)
    let s = MascotState(position: CGPoint(x: w.clampX(CGFloat(dice.range(0...Double(width)))), y: 0), surface: .floor)
    let px = s.position.x + CGFloat(dice.range(-1.2...1.2)) * size
    var end = s.position
    for step in Brain.flee(s, from: px, world: w, moves: full) {
        switch step {
        case .move(_, let to, let seconds):
            if !(seconds.isFinite && seconds >= 0) || to.y != 0 || to.x < 0 || to.x > width { fail("flee move \(to) \(seconds)") }
            end = to
        case .play(_, let seconds) where seconds > 1:
            if let d = w.dock, end.x > d.lowerBound, end.x < d.upperBound { fail("flee stops on the Dock at \(end.x)") }
        default: break
        }
    }
    if abs(end.x - px) < size * 1.5, !(end.x <= w.lane.lowerBound + 1 || end.x >= w.lane.upperBound - 1) { fail("flee ends near the pointer: \(end.x) vs \(px)") }
}

// Throws: wild velocities and positions must still land.
for _ in 0..<5000 {
    let world = World(minX: 0, maxX: 1512, floor: 11, ceiling: 940, windows: [Platform(id: 1, minX: 300, maxX: 1100, y: 600)], size: 64)
    let p = CGPoint(x: dice.range(-500...2000), y: dice.range(-500...2000))
    let v = CGVector(dx: dice.range(-1e5...1e5), dy: dice.range(-1e5...1e5))
    let steps = Brain.thrown(from: p, velocity: v, world: world)
    guard case .flight(_, let path, _, let landing) = steps[1] else { fail("throw plan shape"); continue }
    if path.contains(where: { !($0.x.isFinite && $0.y.isFinite) }) { fail("throw NaN") }
    if landing == .air { fail("throw landed in air") }
}
let nan = Brain.thrown(from: CGPoint(x: CGFloat.nan, y: .infinity), velocity: CGVector(dx: CGFloat.nan, dy: CGFloat.infinity),
                       world: World(minX: 0, maxX: 1000, floor: 11, ceiling: 800, size: 56))
if case .flight(_, let path, _, _) = nan[1], path.contains(where: { !$0.x.isFinite || !$0.y.isFinite }) { fail("NaN throw path") }

// Foot-locked moves: end exactly on the target, key times 0...1 and never
// decreasing, holds repeat a point, frames never faster than quickestFrame
// unless the move is too short for one cycle, nothing NaN.
let paced = Moves(images: full.images, custom: [Action(name: "Walk", frames: [1, 2, 1, 3].map {
    Frame(image: "shime\($0).png", seconds: 0.08, velocity: CGPoint(x: -2, y: 0)) })])
if abs(paced.action("Walk").speed(size: 128) - full.action("Walk").speed(size: 128) * 0.4) > 0.01 { fail("leastFrame keeps the ground speed") }
let stepped = full.stepping(at: 0.5)
if abs(stepped.action("Walk").speed(size: 128) - full.action("Walk").speed(size: 128) * 0.5) > 0.01 { fail("buddyWalk keeps the ground speed") }
var gaits = 0, holdsSeen = 0
for _ in 0..<20000 {
    let name = ["Walk", "Run", "Dash", "Creep", "ClimbWall", "ClimbCeiling", "Tripping"][Int(dice.next() % 7)]
    let a = full.action(name)
    let size = CGFloat(dice.range(16...200))
    let p = CGPoint(x: dice.range(0...3000), y: dice.range(0...1500))
    let q = dice.chance(0.5) ? CGPoint(x: dice.range(0...3000), y: p.y) : CGPoint(x: p.x, y: dice.range(0...1500))
    let speed = Double(a.speed(size: size)) * dice.range(0.3...15)
    let seconds = Double(hypot(q.x - p.x, q.y - p.y)) / max(speed, 1)
    guard let g = Brain.gaitKeys(a, from: p, to: q, size: size, seconds: seconds, phase: dice.range(-5...5)) else {
        if hypot(q.x - p.x, q.y - p.y) > 0.01, seconds > 0 { fail("no gait for \(name)") }
        continue
    }
    gaits += 1
    if g.points.count != g.keyTimes.count || g.points.count < 2 { fail("gait key count \(g.points.count) vs \(g.keyTimes.count)") }
    if g.points.last != q { fail("gait ends at \(g.points.last!) not \(q)") }
    if g.points.first.map({ hypot($0.x - p.x, $0.y - p.y) > 0.01 }) ?? true { fail("gait starts off p") }
    if g.keyTimes.first != 0 || g.keyTimes.last != 1 { fail("gait key times \(g.keyTimes.first!)...\(g.keyTimes.last!)") }
    if zip(g.keyTimes, g.keyTimes.dropFirst()).contains(where: { $0 > $1 }) { fail("gait key times decrease") }
    if g.points.contains(where: { !$0.x.isFinite || !$0.y.isFinite }) || !g.timeScale.isFinite || g.timeScale <= 0 { fail("gait NaN") }
    if g.duration < seconds || (g.duration > seconds && abs(g.duration - a.duration * max(Brain.quickestFrame / a.frames.map(\.seconds).min()!, Brain.steadyGaits.contains(name) ? 1 : 0)) > 1e-9) {
        fail("gait duration \(g.duration) vs \(seconds)")
    }
    let shortest = a.frames.map(\.seconds).min()!
    let least = max(Brain.quickestFrame / shortest, Brain.steadyGaits.contains(name) ? 1 : 0)
    if g.timeScale < least / (Brain.steadyGaits.contains(name) ? 1.15 : 1) - 1e-9 {
        fail("\(name) legs at \(1 / g.timeScale)x, frame \(shortest * g.timeScale) s")
    }
    // A frame without velocity holds: some consecutive points are equal.
    if a.frames.contains(where: { $0.velocity == .zero }), zip(g.points, g.points.dropFirst()).contains(where: { $0 == $1 }) { holdsSeen += 1 }
    // Never runs past the target or backwards.
    var last = 0.0
    for pt in g.points {
        let d = Double(hypot(pt.x - p.x, pt.y - p.y))
        if d < last - 1e-6 || d > Double(hypot(q.x - p.x, q.y - p.y)) + 1e-6 { fail("gait goes back or past"); break }
        last = d
    }
}
if holdsSeen == 0 { fail("no holds in Creep/Climb gaits") }
// An uncapped walk: per-frame stride within the rounding leftover of the art's.
if let g = Brain.gaitKeys(full.action("Walk"), from: .zero, to: CGPoint(x: 1000, y: 0), size: 128, seconds: 1000 / Double(full.action("Walk").speed(size: 128))) {
    if abs(g.timeScale - 1) > 0.05 { fail("walk time scale \(g.timeScale)") }
}
for bad in [CGFloat.nan, .infinity, 0] {
    if Brain.gaitKeys(full.action("Walk"), from: CGPoint(x: bad, y: 0), to: CGPoint(x: 10, y: 0), size: 56, seconds: 1) != nil, bad != 0 { fail("gait from NaN") }
    if Brain.gaitKeys(full.action("Walk"), from: .zero, to: CGPoint(x: 10, y: 0), size: bad, seconds: 1) != nil { fail("gait at size \(bad)") }
    if Brain.gaitKeys(full.action("Walk"), from: .zero, to: CGPoint(x: 10, y: 0), size: 56, seconds: Double(bad)) != nil { fail("gait in \(bad) s") }
}
if Brain.gaitKeys(full.action("Walk"), from: .zero, to: .zero, size: 56, seconds: 1) != nil { fail("gait for no distance") }
if Brain.gaitKeys(full.action("GrabWall"), from: .zero, to: CGPoint(x: 0, y: 30), size: 56, seconds: 0.15) != nil { fail("gait without velocity") }

// Coalesce: same end, same total time, idempotent; joins split walks.
var merged = 0
func walkEnd(_ plan: [Step], from p: CGPoint) -> (CGPoint, Double) {
    var here = p, t = 0.0
    for s in plan {
        switch s {
        case .move(_, let to, let seconds): here = to; t += seconds
        case .play(_, let seconds): t += seconds
        case .flight(_, let path, let dt, _): here = path.last ?? here; t += dt * Double(path.count - 1)
        default: break
        }
    }
    return (here, t)
}
for run in 0..<20000 {
    let size = CGFloat(dice.range(32...128))
    var world = World(minX: 0, maxX: 2000, floor: 11, ceiling: 1000, size: size)
    if run % 2 == 0 { world.dock = 600...1400; world.notch = 905...1095; world.notchDepth = 32; world.notchX = 1160 }
    var sig = Signals()
    sig.others = dice.chance(0.5) ? [CGFloat(dice.range(0...2000))] : []
    sig.followX = dice.chance(0.2) ? CGFloat(dice.range(0...2000)) : nil
    let s = MascotState(position: CGPoint(x: world.clampX(CGFloat(dice.range(0...2000))), y: 11), surface: .floor)
    var plan = Brain.decide(s, world: world, signals: sig, moves: [full, tiny][run % 2], dice: &dice)
    if run % 5 == 0 { var d = dice; plan = Brain.notchVisit(from: s.position, world: world, moves: full, dice: &d) }
    if run % 7 == 0 { plan = [.face(right: true), .move("Walk", to: CGPoint(x: s.position.x + 50, y: 11), seconds: 1),
                              .face(right: true), .move("Walk", to: CGPoint(x: s.position.x + 90, y: 11), seconds: 0.8)] }
    let c = Brain.coalesce(plan, from: s.position)
    let (e0, t0) = walkEnd(plan, from: s.position), (e1, t1) = walkEnd(c, from: s.position)
    if hypot(e0.x - e1.x, e0.y - e1.y) > 0.001 || abs(t0 - t1) > 1e-6 { fail("coalesce changes the end \(e0) \(t0) vs \(e1) \(t1)") }
    if Brain.coalesce(c, from: s.position) != c { fail("coalesce not idempotent") }
    if run % 7 == 0, c.count != 2 { fail("split walk not joined: \(c)") }
    if c.count < plan.count { merged += 1 }
    // Facing before each move is the same as before.
    func facings(_ p: [Step]) -> [Bool?] {
        var f: Bool?, out: [Bool?] = []
        for s in p { if case .face(let r) = s { f = r }; if case .move = s { out.append(f) } }
        return out
    }
    if Set(facings(c)).count > Set(facings(plan)).count { fail("coalesce changes facing") }
}
if merged == 0 { fail("coalesce never merged") }
print("gaits \(gaits) (holds in \(holdsSeen)), coalesced plans \(merged)")

print("steps \(stepCount), flights \(flights), climbs \(climbs), hangs \(hangs), window landings \(windowLandings), extras \(extrasPlayed)")
print("actions used:", seen.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
print(failures == 0 ? "PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
