// The buddies: Shimeji characters living around the Dock. One screen-sized,
// click-through panel at the wings' level holds every character that is out
// (`buddyPacks`, picked on the library shelf); each is a layer pair (holder
// at the anchor point, sprite inside it), its frames discrete `contents`
// keyframes and its moves position animations, so nothing ticks between
// decisions. What to do next comes from BuddyBrain.swift (pure, tested in
// tools/buddy-brain-check.swift); this file plays the steps and feeds the
// brain what the Mac is doing: music (and Tide's beat, straight to a layer),
// Claude working / waiting / done, typing, idle (sleep after 2 minutes),
// battery, heat, a new download or screenshot, the front window (a platform
// to climb onto, polled once a second, three times while someone stands on
// it), the notch (hang beside it during alerts or on a visit).
// Near the Dock they run from the pointer and let clicks through; holding
// Option there (or meeting one anywhere else) you can pick one up and throw
// it (flies with momentum, bounces off the screen sides), click it
// (character library), double-click (jump), hover (pet), right-click (sit,
// sleep, dance, follow the pointer, put away).
// Things happening get a short pose from the nearest buddy: a new song,
// play / pause, volume, Claude needing you / done / denied, notch alerts,
// headphones, the charger, a download or screenshot, a copy, an app opening,
// WaniKani reviews done, a todo ticked off, a file dragged (one follows it).
// Dock bar: when the Dock end of the right wing has stayed empty a while, up
// to three guests step out of the Dock's separator line there and sit
// (`doorGuests`, pack paths, else others from the shelf; never ones out); when
// a widget needs the room they walk back into the line. They only sit: no
// brain, no reactions, not clickable.
// Test aids: `BuddyTest all` (or a part: `window`, `climb`, `claude`...) runs
// every behaviour in turn and writes
// ~/Library/Logs/DockWings/buddy.log (`BuddyLog 1` logs without the script).
import AppKit
import Combine
import QuartzCore

// MARK: Packs

struct ShimejiPack {
    let name: String
    let frames: [String: CGImage]
    /// Width over height of a frame.
    let aspect: CGFloat
    let moves: Moves

    /// Accepts the pack folder itself, its `img` folder, or `img/<Name>`.
    static func load(_ path: String) -> ShimejiPack? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var candidates = [root, root.appendingPathComponent("img")]
        for dir in candidates {
            let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            candidates += subs.sorted { $0.path < $1.path }
        }
        guard let dir = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("shime1.png").path) })
        else { return nil }
        func image(_ key: String) -> CGImage? {
            guard !key.contains(".."), key.lowercased().hasSuffix(".png") else { return nil }
            let url = dir.appendingPathComponent(key)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        var frames: [String: CGImage] = [:]
        for n in 1...128 {
            if let img = image("shime\(n).png") { frames["shime\(n).png"] = img }
        }
        let custom = ["actions.xml", "conf/actions.xml", "../conf/actions.xml", "../../conf/actions.xml"]
            .map { dir.appendingPathComponent($0).standardizedFileURL }
            .first { fm.fileExists(atPath: $0.path) }
            .map(ShimejiActions.parse) ?? []
        for key in Set(custom.flatMap { $0.frames.map(\.image) }) where frames[key] == nil { frames[key] = image(key) }
        guard let first = frames["shime1.png"], first.height > 0 else { return nil }
        let catalogName = MainActor.assumeIsolated { BuddyCatalog.shared.byID[root.lastPathComponent]?.name }
        let climbing = [12, 13, 14].compactMap { frames["shime\($0).png"] }
        let reach = wallReach(climbing)
        var moves = Moves(images: Set(frames.keys), custom: custom, wallReach: reach).aligned(frames.compactMapValues(visibleRows))
        // Real climbing art reaches the frame's side (the wall); leaping or
        // floating poses don't, and look like flying beside the wall.
        if climbing.count < 3 || reach < 0.25 { moves = moves.climbingByWalking() }
        // Per-pack leg pace (`buddyWalk`: folder name to factor, 0.6 = slower).
        if let factor = UserDefaults.standard.dictionary(forKey: "buddyWalk")?[root.lastPathComponent] as? Double {
            moves = moves.stepping(at: CGFloat(factor))
        }
        return ShimejiPack(name: catalogName ?? root.lastPathComponent, frames: frames,
                           aspect: CGFloat(first.width) / CGFloat(first.height), moves: moves)
    }

    private static func alpha(_ image: CGImage, size n: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return pixels
    }

    /// The first and just past the last visible row, in a 128-pt frame
    /// (bitmap rows run top-down).
    private static func visibleRows(_ image: CGImage) -> (top: CGFloat, bottom: CGFloat)? {
        let n = 128
        guard let pixels = alpha(image, size: n) else { return nil }
        let rows = (0..<n).filter { row in (0..<n).contains { pixels[(row * n + $0) * 4 + 3] > 40 } }
        guard let top = rows.first, let bottom = rows.last else { return nil }
        return (CGFloat(top), CGFloat(bottom + 1))
    }

    /// From the anchor (the frame's centre) to the leftmost visible pixel of
    /// the climbing frames, as a share of the width; images face left, so
    /// that is the wall side.
    private static func wallReach(_ images: [CGImage]) -> CGFloat {
        guard !images.isEmpty else { return 0.5 }
        var reach: CGFloat = 0
        for image in images {
            let w = 64, h = 64
            guard let pixels = alpha(image, size: w) else { continue }
            var leftmost = w
            for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 40 { leftmost = min(leftmost, x); break } }
            if leftmost < w { reach = max(reach, 0.5 - CGFloat(leftmost) / CGFloat(w)) }
        }
        return reach > 0 ? reach : 0.5
    }
}

/// Reads a Shimeji-ee actions.xml: each action's first animation, as frames.
/// Packs with Japanese element names (the oldest ones) keep the default table.
enum ShimejiActions {
    static func parse(_ url: URL) -> [Action] {
        guard let parser = XMLParser(contentsOf: url) else { return [] }
        let reader = Reader()
        parser.delegate = reader
        parser.parse()
        return reader.actions
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var actions: [Action] = []
        var name: String?
        var animations = 0
        var frames: [Frame] = []

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch element {
            case "Action":
                name = a["Name"]
                animations = 0
                frames = []
            case "Animation":
                animations += 1
            case "Pose" where name != nil && animations == 1:
                guard var image = a["Image"] else { return }
                while image.hasPrefix("/") { image.removeFirst() }
                guard !image.contains(".."), image.lowercased().hasSuffix(".png") else { return }
                let ticks = Double(a["Duration"] ?? "") ?? 4
                frames.append(Frame(image: image, seconds: max(ticks, 1) * 0.04,
                                    anchor: point(a["ImageAnchor"]) ?? CGPoint(x: 64, y: 128),
                                    velocity: point(a["Velocity"]) ?? .zero))
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            guard element == "Action", let name else { return }
            if !frames.isEmpty { actions.append(Action(name: name, frames: frames)) }
            self.name = nil
        }

        private func point(_ s: String?) -> CGPoint? {
            let parts = (s ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, parts.allSatisfy(\.isFinite) else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
    }
}

/// Which packs are out on the Dock (paths), kept in `buddyPacks`; the older
/// single `buddyPack` setting moves in on first read.
enum BuddyRoster {
    static var paths: [String] {
        get {
            let d = UserDefaults.standard
            if let list = d.stringArray(forKey: "buddyPacks") { return list }
            if let one = d.string(forKey: "buddyPack"), !one.isEmpty { return [one] }
            return []
        }
        set { UserDefaults.standard.set(newValue, forKey: "buddyPacks") }
    }

    static func toggle(_ path: String) {
        var list = paths
        if let i = list.firstIndex(of: path) { list.remove(at: i) } else { list.append(path) }
        paths = list
        if !list.isEmpty { UserDefaults.standard.set(true, forKey: "buddy") }
    }
}

// MARK: Log

/// Buddy log for tests: ~/Library/Logs/DockWings/buddy.log.
enum BuddyLog {
    static let on = UserDefaults.standard.string(forKey: "BuddyTest") != nil || UserDefaults.standard.bool(forKey: "BuddyLog")
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DockWings/buddy.log")
    private static var handle: FileHandle? = {
        guard on else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    private static let start = Date()

    static func write(_ line: @autoclosure () -> String) {
        guard on, let handle else { return }
        handle.write(Data(String(format: "%7.2f ", Date().timeIntervalSince(start)).appending(line() + "\n").utf8))
    }
}

// MARK: One character

@MainActor
private final class Mascot {
    let path: String
    let pack: ShimejiPack
    /// At the anchor point; the beat moves it a little.
    let holder = CALayer()
    let sprite = CALayer()
    var state: MascotState
    var plan: [Step] = []
    /// What is playing now (for interrupting and dancing).
    var doing: Step?
    var work: DispatchWorkItem?
    var dice: Dice
    var followUntil: Date?
    /// Hanging beside the notch for an alert, until the alert goes.
    var cameo = false
    var hoverSince: Date?
    var lastPet = Date.distantPast
    var action = "Stand"
    /// The running frame loop: when its cycle began (layer time) and how
    /// long one cycle takes; 0 when none runs.
    var cycleStart: CFTimeInterval = 0
    var cycleLength: Double = 0
    /// Given a start spot yet (the panel has no size when mascots are made).
    var placed = false
    /// The window top it stands on, as last seen.
    var standingOn: Platform?
    /// Not before then does it run from the pointer again.
    var fleeAfter = Date.distantPast
    /// Last reaction to something happening (a few seconds apart at most).
    var reactedAt = Date.distantPast
    /// Came out of the separator line: walks to a seat and sits, nothing more.
    var guest = false

    var name: String { pack.name }
    var moves: Moves { pack.moves }

    init(path: String, pack: ShimejiPack, at position: CGPoint) {
        self.path = path
        self.pack = pack
        state = MascotState(position: position, surface: .floor)
        dice = Dice(seed: UInt64(truncatingIfNeeded: path.hashValue) ^ UInt64(Date().timeIntervalSince1970 * 1000))
        holder.addSublayer(sprite)
        sprite.contentsGravity = .resizeAspect
        sprite.minificationFilter = .trilinear
    }

    /// How far into its cycle the running frame loop is at `now`, 0..<1.
    func phase(at now: CFTimeInterval) -> Double {
        guard cycleLength > 0, sprite.animation(forKey: "frames") != nil else { return 0 }
        let f = ((now - cycleStart) / cycleLength).truncatingRemainder(dividingBy: 1)
        return f.isFinite ? (f < 0 ? f + 1 : f) : 0
    }

    /// Where it is now, mid-animation included.
    var position: CGPoint {
        let p = holder.presentation()?.position ?? holder.position
        return p.x.isFinite && p.y.isFinite ? p : state.position
    }

    /// The sprite's box in the panel, mid-animation included.
    var box: CGRect {
        let p = position, b = sprite.bounds, a = sprite.anchorPoint, o = sprite.position
        return CGRect(x: p.x + o.x - b.width * a.x, y: p.y + o.y - b.height * a.y, width: b.width, height: b.height)
    }

    /// May a new plan replace what it is doing? Not mid-climb, mid-air or asleep.
    /// In a moment with the other buddy: nothing cuts in until then.
    var busyUntil = Date.distantPast

    var interruptible: Bool {
        guard !state.asleep, Date() >= busyUntil else { return false }
        switch state.surface {
        case .floor, .window: break
        default: return false
        }
        if case .flight = doing { return false }
        return true
    }
}

// MARK: The buddies

@MainActor
final class Buddy {
    private let panel: NSPanel
    private let view = BuddyView()
    private var mascots: [Mascot] = []
    private var size: CGFloat = 56
    private var settings = ""
    private var screen: NSScreen?
    /// The Dock band's walking line in panel coordinates; nil without a fixed Dock.
    private var floor: CGFloat?
    private var feeds: [AnyCancellable] = []
    private var signals = Signals()
    private var world: World?
    private var pulse: Timer?
    private var windowWatch: Timer?
    private var watch: Timer?
    private weak var drawerWindow: NSWindow?
    private var attentionUntil = Date.distantPast
    private var batteries: Batteries?
    /// Test script: fixed signals instead of the real ones.
    private var forced: Signals?
    private var testWindow: NSWindow?
    private var lastCameo = Date.distantPast
    private var lastPoke = Date.distantPast
    /// A file (or screenshot thumbnail) is being dragged; set by AppDelegate.
    /// The nearest buddy jumps up and hangs from it until it is dropped.
    var fileDrag = false {
        didSet { if fileDrag != oldValue { fileDrag ? catchDrag() : dropDrag() } }
    }
    private var ride: Timer?
    /// Where the middle of the dragged item's bottom edge is: right of and
    /// below the pointer.
    var dragHang = CGPoint(x: 0, y: 32)
    private let born = Date()
    private weak var lastOver: Mascot?

    // Dragging
    private var held: Mascot?
    private var press: NSPoint?
    private var grab = CGPoint.zero
    private var samples: [(p: CGPoint, t: TimeInterval)] = []
    private var pendingClick: DispatchWorkItem?

    /// Screen x of a widget's centre, if it is showing.
    var widgetX: ((String) -> CGFloat?)?
    /// The Dock's icons, in screen x: buddies cross them without stopping,
    /// and clicks there go to the Dock.
    var dockIcons: ClosedRange<CGFloat>?
    /// The grown notch panel (music player, WaniKani review), screen rect,
    /// while it is open: a buddy sits on its bottom edge.
    var notchPanelRect: (() -> NSRect?)?
    /// Until then a buddy is on its way to the notch panel's edge: the
    /// buddies' window stays above the notch so it shows.
    private var seatingUntil = Date.distantPast
    /// Dock bar: where the widgets are (screen x), so nobody sits on them.
    var widgetSpans: (() -> [ClosedRange<CGFloat>])?
    /// Dock bar: the empty stretch at the Dock end of the right wing (screen
    /// x), nil when there is none.
    var guestRoom: (() -> ClosedRange<CGFloat>?)?
    private var guests: [Mascot] = []
    private var guestPacks: [String: ShimejiPack] = [:]
    /// Holds the guests; its mask hides them left of the line.
    private let stage = CALayer()
    private let curtain = CALayer()
    /// Since when the room has been free (guests wait for it to stay so).
    private var roomSince: Date?
    /// The Dock's separator line (panel x) the guests came out of.
    private var lineX: CGFloat = 0
    private var guestsOut = false

    init(music: Music, claude: ClaudeStatus, latest: Latest, batteries: Batteries,
         clipboard: Clipboard, todos: Todos, wanikani: WaniKani) {
        self.batteries = batteries
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: 23)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.alphaValue = 0
        view.wantsLayer = true
        panel.contentView = view
        view.down = { [unowned self] p, count in self.pressed(p, count: count) }
        view.drag = { [unowned self] in self.carry($0) }
        view.up = { [unowned self] in self.released() }
        view.rightClick = { [unowned self] p in self.menu(at: p) }

        feeds.append(music.$isPlaying.removeDuplicates().sink { [unowned self] playing in
            self.signals.musicPlaying = playing
            if playing { self.nudge() }
        })
        reactions(music: music, claude: claude, latest: latest, batteries: batteries, clipboard: clipboard, todos: todos, wanikani: wanikani)
        music.live.others.append { [weak self] levels in self?.beat(levels) }
        feeds.append(claude.$sessions.map { sessions -> ClaudeMood in
            let states = sessions.values.map(\.state)
            return states.contains(.waiting) ? .waiting : states.contains(.working) ? .working : .none
        }.removeDuplicates().sink { [unowned self] mood in
            if self.signals.claude == .working, mood == .none, claude.sessions.values.contains(where: { $0.state == .done }) {
                self.react(.hop(2), near: self.widgetX?("claude"), "Claude done")
            }
            if mood == .waiting, self.signals.claude != .waiting { self.react(.hop(2), near: self.widgetX?("claude"), "Claude needs you") }
            self.signals.claude = mood
            self.nudge()
        })
        feeds.append(latest.$item.removeDuplicates().dropFirst().sink { [unowned self] item in
            guard item != nil else { return }
            self.attentionUntil = Date().addingTimeInterval(15)
            self.nudge()
        })
        // The playing track lives in the notch with the Dock bar: not an alert
        // to hang beside for a whole song.
        feeds.append(Notch.shared.$alert.map { $0?.id == "music" ? nil : $0?.id }.removeDuplicates().sink { [unowned self] id in self.notchAlert(id) })
        watchBanners()
        feeds.append(Drawers.shared.$open.removeDuplicates().debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [unowned self] _ in self.drawerOpened() })
        feeds.append(Notch.shared.$expanded.removeDuplicates().debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [unowned self] open in if open { self.notchSeat() } })
        // The notch widening or the pointer over it; read once the change has landed.
        feeds.append(Publishers.CombineLatest3(Notch.shared.$alert.map { $0?.id }, Notch.shared.$hovering, Notch.shared.$cardShown)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [unowned self] _ in self.notchGrew(Notch.shared.shapeWidth) })
        for publisher in [Presence.shared.$visible.map { _ in () }.eraseToAnyPublisher(),
                          Notch.shared.$fullScreen.map { _ in () }.eraseToAnyPublisher()] {
            feeds.append(publisher.receive(on: RunLoop.main).sink { [unowned self] in self.refresh() })
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { self.readSettings() }
        }
        readSettings()
    }

    // MARK: Placement and settings

    /// Keeps the buddies in front of the wings (same level, ordered earlier)
    /// but under the drawers, so a click on a buddy over a wing reaches it.
    func order(below drawer: NSWindow) {
        drawerWindow = drawer
        guard panel.isVisible, drawer.isVisible else { return }
        panel.order(.below, relativeTo: drawer.windowNumber)
    }

    /// Called on every layout: the Dock's screen, or nil when there is no fixed Dock.
    func place(on screen: NSScreen?) {
        self.screen = screen
        if let screen {
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
            if !panel.isVisible { panel.orderFrontRegardless() }
            // The very bottom of the screen.
            if floor != 0 { floor = 0 }
        } else {
            floor = nil
        }
        refresh()
    }

    private func readSettings() {
        let d = UserDefaults.standard
        let on = d.bool(forKey: "buddy"), paths = BuddyRoster.paths
        let s = d.object(forKey: "buddySize") as? Double ?? 56
        let key = "\(on)|\(paths)|\(s)"
        guard key != settings else { return }
        settings = key
        size = CGFloat(min(max(s, 24), 160))
        let wanted = on ? paths : []
        // Put away the ones no longer out; bring out new ones.
        for m in mascots where !wanted.contains(m.path) { remove(m) }
        for path in wanted where !mascots.contains(where: { $0.path == path }) {
            guard let pack = ShimejiPack.load(path) else { continue }
            let m = Mascot(path: path, pack: pack, at: CGPoint(x: CGFloat.random(in: 200...max(201, panel.frame.width - 200)), y: floor ?? 0))
            view.layer?.addSublayer(m.holder)
            mascots.append(m)
            BuddyLog.write("\(m.name) out (\(pack.frames.count) frames, climb \(pack.moves.canClimb), wall reach \(String(format: "%.2f", pack.moves.wallReach)), extras \(pack.moves.extras))")
            if panel.alphaValue > 0 { start(m) }
        }
        for m in mascots { resize(m) }
        refresh()
    }

    private func remove(_ m: Mascot) {
        m.work?.cancel()
        m.holder.removeFromSuperlayer()
        mascots.removeAll { $0 === m }
        BuddyLog.write("\(m.name) away")
    }

    private var live: Bool {
        !mascots.isEmpty && floor != nil && Presence.shared.visible && !Notch.shared.fullScreen
    }

    private func refresh() {
        if live, panel.alphaValue == 0 {
            panel.alphaValue = 1
            mascots.forEach(start)
            var beats = 0
            pulse = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [unowned self] _ in
                MainActor.assumeIsolated {
                    self.bump()
                    beats += 1
                    if beats % 4 == 0 { self.tick() }
                }
            }
            tick()
            if let test = UserDefaults.standard.string(forKey: "BuddyTest"), forced == nil { runTest(test) }
        } else if !live, panel.alphaValue > 0 {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            pulse?.invalidate()
            pulse = nil
            windowWatch?.invalidate()
            windowWatch = nil
            for m in mascots { stop(m) }
            clearGuests()
        }
    }

    private func resize(_ m: Mascot) {
        without {
            m.sprite.bounds = CGRect(x: 0, y: 0, width: size * m.pack.aspect, height: size)
            m.sprite.contentsScale = screen?.backingScaleFactor ?? 2
        }
    }

    private func start(_ m: Mascot) {
        guard let w = currentWorld() else { return }
        resize(m)
        if !m.placed {
            // Somewhere along the floor, not on the Dock's icons.
            m.placed = true
            var x = CGFloat.random(in: w.lane)
            if let z = w.blocked(x) { x = w.clampX(Bool.random() ? z.lowerBound : z.upperBound) }
            m.state.position.x = x
        }
        m.state.position = CGPoint(x: w.clampX(m.state.position.x), y: w.floor)
        m.state.surface = .floor
        m.state.asleep = false
        without { m.holder.position = m.state.position }
        run(m, [.play("Stand", seconds: 0.8)])
    }

    private func stop(_ m: Mascot) {
        m.work?.cancel()
        m.plan = []
        m.doing = nil
        m.cycleLength = 0
        m.holder.removeAllAnimations()
        m.sprite.removeAllAnimations()
    }

    // MARK: Guests

    /// Once a second: brings the guests out when the room has stayed free for
    /// 10 s, sends them back in as soon as a widget needs it.
    private func checkGuests() {
        let f = panel.frame
        let room = guestRoom?().map { ($0.lowerBound - f.minX)...($0.upperBound - f.minX) }
        let slot = size * 1.1
        let fits = room.map { $0.upperBound - $0.lowerBound >= 12 + slot } ?? false
        roomSince = fits ? (roomSince ?? Date()) : nil
        if guestsOut {
            // Leave when the room shrinks past a guest or the wing moves.
            guard let room, fits, abs(room.lowerBound - lineX) < 4,
                  guests.allSatisfy({ $0.state.position.x + slot / 2 <= room.upperBound }) else { sendGuestsBack(); return }
            return
        }
        guard let room, let since = roomSince, Date().timeIntervalSince(since) >= 10, let y = floor else { return }
        let count = min(3, Int((room.upperBound - room.lowerBound - 12) / slot))
        let out = Set(BuddyRoster.paths)
        // The chosen guests (`doorGuests`, pack paths) in order, else others from the shelf.
        let chosen = UserDefaults.standard.stringArray(forKey: "doorGuests")
        let picks = (chosen ?? BuddyLibrary.packs().map(\.path).shuffled()).filter { !out.contains($0) }.prefix(count)
        let packs = picks.compactMap { path -> (String, ShimejiPack)? in
            if let p = guestPacks[path] { return (path, p) }
            guard let p = ShimejiPack.load(path) else { return nil }
            guestPacks[path] = p
            return (path, p)
        }
        guard !packs.isEmpty else { return }
        guestsOut = true
        lineX = room.lowerBound
        // Guests are only drawn right of the line, so they step out of it.
        if stage.superlayer == nil { view.layer?.insertSublayer(stage, at: 0) }
        without {
            stage.frame = view.bounds
            curtain.frame = CGRect(x: lineX, y: 0, width: view.bounds.width - lineX, height: view.bounds.height)
            curtain.backgroundColor = NSColor.black.cgColor
            stage.mask = curtain
        }
        BuddyLog.write("guests come out: \(packs.map(\.1.name))")
        let behind = lineX - size * 0.7
        for (i, (path, pack)) in packs.enumerated() {
            let seat = lineX + 12 + slot * (CGFloat(i) + 0.5) + CGFloat.random(in: -6...6)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.9) { [weak self] in
                guard let self, self.guestsOut, self.live else { return }
                let m = Mascot(path: path, pack: pack, at: CGPoint(x: behind, y: y))
                m.guest = true
                m.placed = true
                self.stage.addSublayer(m.holder)
                self.guests.append(m)
                self.resize(m)
                without { m.holder.position = m.state.position }
                let speed = max(m.moves.action("Walk").speed(size: self.size), self.size * 0.2)
                self.run(m, [.face(right: true), .move("Walk", to: CGPoint(x: seat, y: y), seconds: Double((seat - behind) / speed)),
                             .play(m.moves.has("Sit") ? "Sit" : "Stand", seconds: 0.1)])
            }
        }
    }

    /// A guest reached its seat (stays sitting) or the line (goes in).
    private func guestArrived(_ m: Mascot) {
        guard !guestsOut else { return }
        m.holder.removeFromSuperlayer()
        guests.removeAll { $0 === m }
    }

    /// Back into the line, quickly: a widget is coming.
    private func sendGuestsBack() {
        guestsOut = false
        roomSince = nil
        BuddyLog.write("guests go back in")
        guard let y = floor else { return }
        let behind = lineX - size * 0.7
        for m in guests {
            let here = m.position
            stop(m)
            m.state.position = here
            without { m.holder.position = here }
            let gait = m.moves.has("Run") ? "Run" : "Walk"
            let speed = max(m.moves.action(gait).speed(size: size), size * 0.3)
            run(m, [.face(right: false), .move(gait, to: CGPoint(x: behind, y: y), seconds: Double(max(0, here.x - behind) / speed))])
        }
    }

    private func clearGuests() {
        guestsOut = false
        roomSince = nil
        for m in guests { stop(m); m.holder.removeFromSuperlayer() }
        guests = []
    }

    // MARK: The world

    private func currentWorld() -> World? {
        guard let floor, let screen else { return nil }
        let f = panel.frame
        var w = World(minX: 0, maxX: f.width, floor: floor, ceiling: f.height, size: size)
        if let (notch, notchScreen) = Notch.locate(), notchScreen == screen {
            w.notchX = notch.maxX - f.minX + size * 0.8
            w.notch = (notch.minX - f.minX)...(notch.maxX - f.minX)
            w.notchDepth = notch.height
        }
        w.dock = dockIcons.map { ($0.lowerBound - f.minX)...($0.upperBound - f.minX) }
        w.widgets = (widgetSpans?() ?? []).map { ($0.lowerBound - f.minX)...($0.upperBound - f.minX) }
        w.windows = frontWindow().map { [$0] } ?? []
        if let d = drawerPlatform() { w.windows.append(d) }
        if let n = notchPlatform() { w.windows.append(n) }
        // Windows someone stands on stay platforms even when another window
        // or app comes to the front.
        for m in mascots {
            guard case .window(let id) = m.state.surface, !w.windows.contains(where: { $0.id == id }),
                  let p = platform(of: id) else { continue }
            w.windows.append(p)
        }
        world = w
        return w
    }

    /// The front app's frontmost ordinary window on this screen, as a platform
    /// (its top edge), when there is room to stand on it.
    private func frontWindow() -> Platform? {
        // The test script's window, when it has one.
        if let test = testWindow { return platform(of: test.windowNumber) }
        guard let screen, let floor else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = panel.frame
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            // DockWings' own windows only count for the test window.
            let isTest = pid == own && number == testWindow?.windowNumber
            guard pid == front || isTest, pid != own || isTest else { continue }
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1, r.width >= 120, r.height >= 60 else { continue }
            // Core Graphics counts from the top of the main screen; AppKit from the bottom.
            let top = primaryHeight - r.minY
            let rect = NSRect(x: r.minX, y: top - r.height, width: r.width, height: r.height)
            guard screen.frame.intersects(rect), rect.size != screen.frame.size else { continue }
            let y = top - f.minY
            guard y > floor + size * 1.2, y < screen.visibleFrame.maxY - f.minY - size * 0.8 else { return nil }
            return Platform(id: number, minX: max(rect.minX - f.minX, 0), maxX: min(rect.maxX - f.minX, f.width), y: y)
        }
        return nil
    }

    /// A window's top edge by window number, while it is on screen.
    private func platform(of id: Int) -> Platform? {
        if id == Self.drawerID { return drawerPlatform() }
        if id == Self.notchID { return notchPlatform() }
        guard let screen,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let b = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = panel.frame
        let top = primaryHeight - r.minY
        guard r.width >= 120, screen.frame.intersects(NSRect(x: r.minX, y: top - r.height, width: r.width, height: r.height)) else { return nil }
        return Platform(id: id, minX: max(r.minX - f.minX, 0), maxX: min(r.maxX - f.minX, f.width), y: top - f.minY)
    }

    /// Once a second: what the Mac is doing.
    private func tick() {
        guard live else { return }
        // Above the notch while someone sits on (or heads for) its panel,
        // else at the wings' level, under the drawers.
        let onNotch = Date() < seatingUntil || mascots.contains { $0.state.surface == .window(Self.notchID) }
        let level = NSWindow.Level(rawValue: onNotch ? 26 : 23)
        if panel.level != level { panel.level = level; if !onNotch, let d = drawerWindow { order(below: d) } }
        // Now and then the two buddies do something together.
        if Double.random(in: 0..<1) < 0.04 { together() }
        var s = signals
        let any = CGEventType(rawValue: ~0)!
        s.idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        s.typing = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1.2
        if let mac = batteries?.items.first(where: { $0.id == "mac" }) { s.lowBattery = mac.percent <= 20 && !mac.charging }
        s.hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let f = panel.frame
        s.claudeX = widgetX?("claude").map { $0 - f.minX }
        s.batteryX = s.lowBattery ? widgetX?("batteries").map { $0 - f.minX } : nil
        s.attentionX = Date() < attentionUntil ? widgetX?("latest").map { $0 - f.minX } : nil
        signals = s
        checkGuests()
        // Sleepers wake as soon as the Mac is used.
        for m in mascots where m.state.asleep && effective(for: m).idleSeconds < 3 { wake(m) }
        // Now and then someone chases the pointer while it is low near the Dock.
        let mouse = NSEvent.mouseLocation
        if let floor, mouse.y - f.minY < floor + size * 2.5 {
            for m in mascots where m.followUntil == nil && m.interruptible && m.dice.chance(0.02) {
                m.followUntil = Date().addingTimeInterval(8)
                BuddyLog.write("\(m.name) chases the pointer")
            }
        }
        for m in mascots {
            if let until = m.followUntil, until < Date() { m.followUntil = nil }
        }
        // Someone on a window: watch it closely; else once a second is enough.
        let onWindow = mascots.contains { if case .window = $0.state.surface { return true }; return false }
        if onWindow, windowWatch == nil {
            BuddyLog.write("watching the window")
            windowWatch = Timer.scheduledTimer(withTimeInterval: 0.33, repeats: true) { [unowned self] _ in
                MainActor.assumeIsolated { self.checkWindow() }
            }
        } else if !onWindow, windowWatch != nil {
            windowWatch?.invalidate()
            windowWatch = nil
        }
        if !onWindow { _ = currentWorld() }
        // Followers keep walking unless the pointer got away from where
        // they are headed (half a body, or behind them); idle ones rethink.
        for m in mascots where m.followUntil != nil && m.interruptible {
            if case .move(_, let to, _)? = m.doing, let fx = effective(for: m).followX, let w = world {
                let x = w.clampX(fx), p = m.position.x
                if abs(x - to.x) <= size * 0.5, (to.x - p) * (x - p) >= 0 { continue }
            }
            replan(m)
        }
    }

    /// Someone walking into another buddy on the floor turns round and
    /// walks off the other way. Not while fleeing or following.
    private func bump() {
        guard mascots.count > 1, let w = world else { return }
        for m in mascots where m.interruptible && m.state.surface == .floor && m.followUntil == nil
            && Date().timeIntervalSince(m.fleeAfter) > 3 {
            guard case .move(let name, let to, _)? = m.doing, ["Walk", "Creep"].contains(name) else { continue }
            let p = m.position
            let dir: CGFloat = to.x > p.x ? 1 : -1
            guard mascots.contains(where: { o in
                o !== m && o.state.surface == .floor && (o.position.x - p.x) * dir > 0 && abs(o.position.x - p.x) < size * 1.1
            }) else { continue }
            let away = w.clampX(p.x - dir * size * CGFloat(m.dice.range(1.5...4)))
            let speed = max(m.moves.action("Walk").speed(size: size), size * 0.2)
            stop(m)
            m.state.position = p
            without { m.holder.position = p }
            run(m, Brain.offDock([.play("Stand", seconds: 0.4), .face(right: away > p.x),
                                  .move("Walk", to: CGPoint(x: away, y: w.floor), seconds: Double(abs(away - p.x) / speed))],
                                 from: m.state, world: w, moves: m.moves))
        }
    }

    /// The open widget drawer's top edge, as a platform to sit on.
    static let drawerID = -1
    private func drawerPlatform() -> Platform? {
        let d = Drawers.shared
        // The WaniKani drawer is at the top of the screen, out of reach.
        guard d.open != nil, d.open != "wanikani", d.frame.width >= 120, let win = drawerWindow, win.isVisible else { return nil }
        let f = panel.frame
        return Platform(id: Self.drawerID, minX: win.frame.minX + d.frame.minX - f.minX, maxX: win.frame.minX + d.frame.maxX - f.minX,
                        y: win.frame.maxY - d.frame.minY - f.minY)
    }

    /// The grown notch panel's bottom edge, as a ledge to sit on.
    static let notchID = -2
    private func notchPlatform() -> Platform? {
        guard let r = notchPanelRect?(), r.width >= 120 else { return nil }
        let f = panel.frame
        return Platform(id: Self.notchID, minX: r.minX - f.minX + size * 0.3, maxX: r.maxX - f.minX - size * 0.3, y: r.minY - f.minY)
    }

    /// The notch grew into the music player or WaniKani: a buddy climbs out
    /// of the notch (or from beside it), along under the menu bar, and drops
    /// onto the panel's bottom edge to sit with its legs dangling, near the
    /// right corner. It reacts from there and falls off when it closes.
    private func notchSeat() {
        guard live, let w = currentWorld(), let ledge = w.platform(Self.notchID), let n = w.notch,
              !mascots.contains(where: { $0.state.surface == .window(Self.notchID) }) else { return }
        let ready = mascots.filter { ($0.interruptible || $0.cameo) && $0.moves.has("ClimbCeiling") }
        guard let m = ready.first(where: \.cameo) ?? ready.randomElement() else { return }
        BuddyLog.write("\(m.name) climbs onto the notch panel")
        stop(m)
        seatingUntil = Date().addingTimeInterval(5)
        panel.level = NSWindow.Level(rawValue: 26)
        // Hanging beside the notch already: from there; else out of the notch itself.
        if !(m.cameo && m.state.surface == .ceiling) {
            m.state.surface = .ceiling
            m.state.position = CGPoint(x: n.upperBound - size * 0.5, y: w.ceiling - w.notchDepth + size)
            without { m.holder.position = m.state.position }
            flip(m)
        }
        m.cameo = false
        let out = CGPoint(x: w.clampX(ledge.maxX + size * 0.9), y: w.ceiling)
        let seat = CGPoint(x: ledge.maxX - size * 0.4, y: ledge.y)
        let sit = m.moves.has("SitAndDangleLegs") ? "SitAndDangleLegs" : "Sit"
        run(m, [.face(right: true), .move("ClimbCeiling", to: out, seconds: 0.7), .play("GrabCeiling", seconds: 0.5)]
            + Brain.jump(from: out, to: seat, lift: 0, world: w, moves: m.moves)
            + [.face(right: false), .play(sit, seconds: 600)])
    }

    /// A widget's drawer opened: the nearest buddy on the floor jumps onto it
    /// and sits on its edge with its legs dangling. Closing it drops them.
    private func drawerOpened() {
        guard live, Drawers.shared.open != nil, let w = currentWorld(), let top = w.platform(Self.drawerID),
              top.y - w.floor < size * 8,
              !mascots.contains(where: { $0.state.surface == .window(Self.drawerID) }) else { return }
        let floorOnes = mascots.filter { $0.interruptible && $0.state.surface == .floor && $0.moves.has("Jumping") }
        guard let m = floorOnes.min(by: { abs($0.position.x - (top.minX + top.maxX) / 2) < abs($1.position.x - (top.minX + top.maxX) / 2) })
        else { return }
        let p = m.position
        let left = p.x < (top.minX + top.maxX) / 2
        let edge = w.clampX(left ? top.minX + size * 0.3 : top.maxX - size * 0.3)
        let start = w.clampX(left ? top.minX - size * 0.4 : top.maxX + size * 0.4)
        let speed = max(m.moves.action("Run").speed(size: size), size * 1.5)
        BuddyLog.write("\(m.name) goes to sit on the \(Drawers.shared.open ?? "") drawer")
        stop(m)
        m.state.position = p
        without { m.holder.position = p }
        let sit = m.moves.has("SitAndDangleLegs") ? "SitAndDangleLegs" : "Sit"
        run(m, [.face(right: start > p.x), .move("Run", to: CGPoint(x: start, y: w.floor), seconds: Double(abs(start - p.x) / speed))]
            + Brain.jump(from: CGPoint(x: start, y: w.floor), to: CGPoint(x: edge, y: top.y), lift: size * 0.5, world: w, moves: m.moves)
            + [.face(right: !left), .play(sit, seconds: 600)])
    }

    /// The window someone stands on moved or went away.
    private func checkWindow() {
        guard let w = currentWorld() else { return }
        for m in mascots {
            guard case .window(let id) = m.state.surface else { m.standingOn = nil; continue }
            if BuddyLog.on, m.standingOn?.minX != w.platform(id)?.minX { BuddyLog.write("\(m.name) window \(id): \(String(describing: w.platform(id)))") }
            if let now = w.platform(id) {
                defer { m.standingOn = now }
                guard let before = m.standingOn, before.id == id else { continue }
                let dx = now.minX - before.minX, dy = now.y - before.y
                guard dx != 0 || dy != 0 else { continue }
                // Ride along.
                stop(m)
                m.state.position = CGPoint(x: m.position.x + dx, y: now.y)
                without { m.holder.position = m.state.position }
                BuddyLog.write("\(m.name) rides the window by \(Int(dx)), \(Int(dy))")
                run(m, [.play("Stand", seconds: 0.3)])
            } else if case .flight = m.doing {
                continue
            } else {
                BuddyLog.write("\(m.name) window gone, falls")
                let p = m.position
                stop(m)
                m.state.position = p
                without { m.holder.position = p }
                run(m, Brain.letGo(from: p, world: w))
            }
        }
    }

    private func effective(for m: Mascot) -> Signals {
        var s = forced ?? signals
        // Only the buddy nearest the Claude widget (or a new download) goes
        // to it; the rest carry on, instead of all crowding one spot.
        func nearest(_ x: CGFloat?) -> Bool {
            guard let x else { return false }
            return mascots.min(by: { abs($0.position.x - x) < abs($1.position.x - x) }) === m
        }
        if forced == nil {
            if !nearest(s.claudeX) { s.claudeX = nil; if s.claude == .working { s.claude = .none } }
            if !nearest(s.attentionX) { s.attentionX = nil }
            if !nearest(s.batteryX) { s.batteryX = nil }
        }
        if let until = m.followUntil, until > Date() {
            s.followX = NSEvent.mouseLocation.x - panel.frame.minX
        }
        s.others = others(than: m)
        return s
    }

    /// Signals changed: idle mascots rethink now instead of finishing a long sit.
    private func nudge() {
        for m in mascots where m.interruptible {
            if case .move = m.doing { continue }
            replan(m)
        }
    }

    // MARK: Playing steps

    private func without(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    /// Drops what it is doing (keeping where it is now) and decides again.
    private func replan(_ m: Mascot) {
        guard let w = currentWorld() else { return }
        let p = m.position
        stop(m)
        m.state.position = p
        without { m.holder.position = p }
        run(m, Brain.decide(m.state, world: w, signals: effective(for: m), moves: m.moves, dice: &m.dice))
    }

    private func wake(_ m: Mascot) {
        m.state.asleep = false
        BuddyLog.write("\(m.name) wakes up")
        let stretch = m.moves.has("Jumping") ? "Jumping" : "Stand"
        stop(m)
        run(m, [.play(stretch, seconds: 0.6), .play("Stand", seconds: 0.6)])
    }

    private func run(_ m: Mascot, _ steps: [Step]) {
        m.plan = Brain.coalesce(steps, from: m.state.position)
        next(m)
    }

    private func next(_ m: Mascot) {
        m.work?.cancel()
        guard live else { return }
        guard !m.plan.isEmpty else {
            m.doing = nil
            if m.guest { guestArrived(m); return }
            if let w = currentWorld() {
                run(m, Brain.decide(m.state, world: w, signals: effective(for: m), moves: m.moves, dice: &m.dice))
            }
            return
        }
        let step = m.plan.removeFirst()
        m.doing = step
        switch step {
        case .play(let name, let seconds):
            show(m, name)
            after(m, seconds)
        case .move(let name, let to, let seconds):
            // Position keys from the frames' own velocity, on the same clock
            // as the frame loop (carrying on from where the legs are when the
            // same gait is already playing).
            let action = m.moves.action(name)
            let now = m.sprite.convertTime(CACurrentMediaTime(), from: nil)
            let phase = m.action == action.name ? m.phase(at: now) : 0
            var duration = seconds
            if let gait = Brain.gaitKeys(action, from: m.state.position, to: to, size: size, seconds: seconds, phase: phase * action.duration) {
                show(m, name, timeScale: gait.timeScale, at: now)
                animate(m, path: gait.points, keyTimes: gait.keyTimes, duration: gait.duration, at: now)
                duration = gait.duration
                BuddyLog.write("\(m.name) \(action.name) \(Int(abs(to.x - m.state.position.x + to.y - m.state.position.y))) pt in \(String(format: "%.2f", seconds)) s, frames \(String(format: "%.3f", (action.frames.map(\.seconds).min() ?? 0) * gait.timeScale)) s (art \(String(format: "%.3f", action.frames.map(\.seconds).min() ?? 0)))")
            } else {
                show(m, name, at: now)
                animate(m, path: [m.state.position, to], duration: seconds)
            }
            m.state.position = to
            after(m, duration)
        case .flight(let name, let path, let dt, let landing):
            show(m, name)
            let duration = dt * Double(max(path.count - 1, 1))
            animate(m, path: path, duration: duration)
            m.state.position = path.last ?? m.state.position
            m.state.surface = landing
            after(m, duration)
        case .face(let right):
            m.state.facingRight = right
            flip(m)
            next(m)
        case .surface(let s):
            m.state.surface = s
            next(m)
        case .sleep(let on):
            m.state.asleep = on
            BuddyLog.write("\(m.name) \(on ? "falls asleep" : "wakes up")")
            next(m)
        }
    }

    private func after(_ m: Mascot, _ seconds: Double) {
        let item = DispatchWorkItem { [weak self, weak m] in
            guard let self, let m else { return }
            self.next(m)
        }
        m.work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0.01), execute: item)
    }

    /// Shows an action: its frames as discrete keyframes, anchored at its
    /// first pose, each frame lasting `timeScale` of its own time. The same
    /// action already looping carries on at its phase instead of restarting.
    private func show(_ m: Mascot, _ name: String, timeScale: Double = 1, at time: CFTimeInterval? = nil) {
        let action = m.moves.action(name)
        let now = time ?? m.sprite.convertTime(CACurrentMediaTime(), from: nil)
        let length = max(action.duration, 0.01) * (timeScale.isFinite && timeScale > 0 ? timeScale : 1)
        let phase = m.action == action.name ? m.phase(at: now) : 0
        if m.action == action.name, m.cycleLength > 0, abs(m.cycleLength - length) < 0.001, m.sprite.animation(forKey: "frames") != nil {
            flip(m)
            return
        }
        if m.action != action.name {
            BuddyLog.write("\(m.name) \(action.name) on \(m.state.surface) at \(Int(m.state.position.x)),\(Int(m.state.position.y))")
        }
        m.action = action.name
        let images = action.frames.map { m.pack.frames[$0.image] ?? m.pack.frames["shime1.png"]! }
        // Each frame's own anchor (measured from its art), so poses land on the line.
        let anchors = action.frames.map { f in
            NSValue(point: CGPoint(x: min(max(f.anchor.x / 128, 0), 1), y: min(max(1 - f.anchor.y / 128, 0), 1)))
        }
        without {
            m.sprite.removeAnimation(forKey: "frames")
            m.sprite.removeAnimation(forKey: "anchors")
            m.sprite.anchorPoint = anchors.first?.pointValue ?? CGPoint(x: 0.5, y: 0)
            m.sprite.position = .zero
            m.sprite.contents = images.first
        }
        flip(m)
        m.cycleLength = 0
        guard images.count > 1 else { return }
        var t = 0.0
        let total = max(action.duration, 0.01)
        // Started `phase` of a cycle ago, so a continuing gait keeps its step.
        m.cycleStart = now - phase * length
        m.cycleLength = length
        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.beginTime = now
        anim.timeOffset = phase * length
        anim.values = images
        // Discrete: one more key time than values.
        anim.keyTimes = action.frames.map { f -> NSNumber in defer { t += f.seconds }; return NSNumber(value: t / total) } + [1]
        anim.calculationMode = .discrete
        anim.duration = length
        anim.repeatCount = .infinity
        m.sprite.add(anim, forKey: "frames")
        if Set(anchors.map(\.pointValue.y)).count > 1 {
            let moves = CAKeyframeAnimation(keyPath: "anchorPoint")
            moves.values = anchors
            moves.keyTimes = anim.keyTimes
            moves.calculationMode = .discrete
            moves.duration = length
            moves.beginTime = now
            moves.timeOffset = phase * length
            moves.repeatCount = .infinity
            m.sprite.add(moves, forKey: "anchors")
        }
    }

    /// Images face left; facing right mirrors them. A pack that climbs by
    /// walking is turned onto the surface: feet to the wall, head up (left
    /// wall a quarter turn clockwise, right wall mirrored), or upside down
    /// under the ceiling, facing the way it goes.
    private func flip(_ m: Mascot) {
        let mirror = CATransform3DMakeScale(m.state.facingRight ? -1 : 1, 1, 1)
        var t = mirror
        if m.moves.climbsByWalking, ["ClimbWall", "GrabWall", "ClimbCeiling", "GrabCeiling"].contains(m.action) {
            switch m.state.surface {
            case .wall(let left):
                t = left ? CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
                         : CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), CATransform3DMakeRotation(.pi / 2, 0, 0, 1))
            case .ceiling:
                t = CATransform3DConcat(CATransform3DMakeScale(m.state.facingRight ? 1 : -1, 1, 1), CATransform3DMakeRotation(.pi, 0, 0, 1))
            default: break
            }
        }
        without { m.sprite.transform = t }
    }

    private func animate(_ m: Mascot, path: [CGPoint], keyTimes: [Double]? = nil, duration: Double, at time: CFTimeInterval? = nil) {
        let finite = path.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        let points = finite ? path : path.filter { $0.x.isFinite && $0.y.isFinite }
        guard let last = points.last else { return }
        let anim = fullRate(CAKeyframeAnimation(keyPath: "position"))
        anim.values = points.map { NSValue(point: $0) }
        if finite, let keyTimes, keyTimes.count == points.count { anim.keyTimes = keyTimes.map { NSNumber(value: $0) } }
        if let time { anim.beginTime = m.holder.convertTime(m.sprite.convertTime(time, to: nil), from: nil) }
        anim.duration = max(duration, 0.01)
        anim.calculationMode = .linear
        without { m.holder.position = last }
        m.holder.add(anim, forKey: "move")
    }

    /// Tide's levels while music plays: buddies standing or sitting bop to them,
    /// straight on the layer.
    private func beat(_ levels: [Double]) {
        guard live, (forced ?? signals).musicPlaying else { return }
        let level = levels.isEmpty ? 0 : levels.reduce(0, +) / Double(levels.count)
        let lift = CGFloat(level.isFinite ? min(max(level, 0), 1) : 0) * size * 0.14
        for m in mascots {
            // Everyone standing or dancing bops; not sitting or lying (they would
            // float above what they sit on), walking, climbing or flying.
            var still = false
            if case .play? = m.doing, m.state.surface == .floor || { if case .window = m.state.surface { return true }; return false }() { still = true }
            let seated = m.action.hasPrefix("Sit") || m.action == "Sprawl"
            let y = still && !seated && !m.state.asleep ? lift : 0
            if m.holder.transform.m42 != y { without { m.holder.transform = CATransform3DMakeTranslation(0, y, 0) } }
        }
    }

    // MARK: Reactions

    private enum Reaction { case hop(Int), lookUp, dance, sit, flop }

    /// Things happening: one buddy (the nearest to where it happens, if that
    /// has a place) reacts right away with a short pose. First values at
    /// launch are not events.
    private func reactions(music: Music, claude: ClaudeStatus, latest: Latest, batteries: Batteries,
                           clipboard: Clipboard, todos: Todos, wanikani: WaniKani) {
        // The music widget, or the notch while the track plays there.
        let musicX = { [unowned self] in self.widgetX?("music") ?? (Notch.shared.music != nil ? Notch.locate()?.rect.midX : nil) }
        feeds.append(music.$trackKey.removeDuplicates().dropFirst().filter { !$0.isEmpty }.sink { [unowned self] _ in
            self.react(.lookUp, near: musicX(), "new song")
        })
        feeds.append(music.$isPlaying.removeDuplicates().dropFirst().sink { [unowned self] playing in
            self.react(playing ? .dance : .sit, near: musicX(), playing ? "music playing" : "music paused")
        })
        feeds.append(claude.$sessions.map { Set($0.filter { $0.value.activity == "Denied" }.keys) }.removeDuplicates().dropFirst()
            .scan((Set<String>(), Set<String>())) { ($0.1, $1) }.sink { [unowned self] old, new in
                if !new.subtracting(old).isEmpty { self.react(.flop, near: self.widgetX?("claude"), "Claude denied") }
            })
        feeds.append(Notch.shared.$alert.map { a in a.map { "\($0.id)|\($0.title)" } ?? "" }.removeDuplicates().dropFirst().sink { [unowned self] key in
            guard !key.isEmpty else { return }
            if key.hasPrefix("hud|") {
                if key.hasSuffix("Volume") { self.react(.hop(1), near: musicX(), "volume") }
            } else if let id = key.split(separator: "|").first.map(String.init), Config.bar,
                      let widget = Notch.widget(for: id), let x = self.widgetX?(widget) {
                // Dock bar: the alert's widget hops; the buddy nearest it hops along.
                self.react(.hop(1), near: x, "\(widget) alert")
            } else if !key.hasPrefix("drop|"), !key.hasPrefix("music|") {
                self.react(.lookUp, near: Notch.locate()?.rect.midX, "notch alert")
            }
        })
        NotificationCenter.default.addObserver(forName: .audioConnected, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { self.react(.hop(2), near: nil, "headphones") }
        }
        feeds.append(batteries.$items.map { $0.first { $0.id == "mac" }?.charging }.removeDuplicates().dropFirst().sink { [unowned self] charging in
            guard let charging else { return }
            self.react(charging ? .hop(1) : .flop, near: self.widgetX?("batteries"), charging ? "charger in" : "charger out")
        })
        feeds.append(latest.$item.removeDuplicates().dropFirst().sink { [unowned self] item in
            guard let item else { return }
            self.react(.lookUp, near: self.widgetX?("latest"), item.isScreenshot ? "screenshot" : "download")
        })
        feeds.append(clipboard.$entries.map(\.count).removeDuplicates().scan((0, 0)) { ($0.1, $1) }.dropFirst().sink { [unowned self] old, new in
            if new > old { self.react(.lookUp, near: NSEvent.mouseLocation.x, "copy") }
        })
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { self.react(.hop(1), near: self.dockIcons.map { ($0.lowerBound + $0.upperBound) / 2 }, "app opened") }
        }
        feeds.append(wanikani.$reviewing.removeDuplicates().dropFirst().sink { [unowned self] on in
            if !on { self.cheer() }
        })
        // Every review answer: a hop when right, a flop when wrong, from the
        // buddy nearest the review (taking turns).
        feeds.append(WKReview.shared.$verdict.removeDuplicates().compactMap { $0 }.sink { [unowned self] v in
            // The review in the notch (Dock bar), on a drawer, or by the widget.
            let near = Notch.shared.reviewing ? Notch.locate()?.rect.midX
                : self.drawerPlatform().map { ($0.minX + $0.maxX) / 2 + self.panel.frame.minX } ?? self.widgetX?("wanikani")
            switch v {
            case .right, .close: self.react(.hop(1), near: near, "a right answer")
            case .wrong: self.react(.flop, near: near, "a wrong answer")
            case .again: self.react(.lookUp, near: near, "an answer to retry")
            }
        })
        feeds.append(todos.$items.map(\.count).removeDuplicates().scan((0, 0)) { ($0.1, $1) }.dropFirst().sink { [unowned self] old, new in
            if new < old { self.react(.hop(1), near: self.widgetX?("todo"), "todo done") }
        })
    }

    private func react(_ r: Reaction, near screenX: CGFloat?, _ why: String) {
        // Models still loading at launch (clipboard, reminders) are not events.
        guard live, forced == nil, Date().timeIntervalSince(born) > 5, let w = currentWorld() else { return }
        let x = screenX.map { $0 - panel.frame.minX }
        let ready = mascots.filter { $0.interruptible && Date().timeIntervalSince($0.reactedAt) > 4 }
        let pick = x.flatMap { x in ready.min { abs($0.position.x - x) < abs($1.position.x - x) } } ?? ready.randomElement()
        guard let m = pick else { return }
        m.reactedAt = Date()
        BuddyLog.write("\(m.name) reacts to \(why)")
        let p = m.position
        stop(m)
        m.state.position = p
        without { m.holder.position = p }
        var steps: [Step] = x.map { [.face(right: $0 > p.x)] } ?? []
        switch r {
        case .hop(let n):
            steps += Brain.hops(at: p, count: n, world: w, moves: m.moves) + [.play("Stand", seconds: 0.8)]
        case .lookUp:
            steps += [.play(m.moves.has("SitAndLookUp") ? "SitAndLookUp" : "Stand", seconds: 2.5)]
        case .dance:
            let dance = m.moves.extras.first { $0.lowercased().contains("dance") } ?? (m.moves.has("SitAndSpinHead") ? "SitAndSpinHead" : "Stand")
            steps += [.play(dance, seconds: 6)]
        case .sit:
            steps += [.play("Sit", seconds: 6)]
        case .flop:
            if m.moves.has("Tripping") { steps.append(.play("Tripping", seconds: m.moves.action("Tripping").duration)) }
            steps += [.play(m.moves.has("Sprawl") ? "Sprawl" : "Sit", seconds: 2.5), .play("Stand", seconds: 0.6)]
        }
        // On a drawer or the notch panel: back to sitting on its edge afterwards.
        if m.state.surface == .window(Self.drawerID) || m.state.surface == .window(Self.notchID) {
            steps.append(.play(m.moves.has("SitAndDangleLegs") ? "SitAndDangleLegs" : "Sit", seconds: 600))
        }
        run(m, Brain.spaced(Brain.offDock(steps, from: m.state, world: w, moves: m.moves), from: m.state,
                            others: others(than: m), world: w, moves: m.moves))
    }

    /// Where the other buddies on the floor are.
    private func others(than m: Mascot) -> [CGFloat] {
        mascots.filter { $0 !== m && $0.state.surface == .floor }.map(\.position.x)
    }

    // MARK: Moments

    private var lastTogether = Date()
    private enum Together: CaseIterable { case meet, chase, follow, dance }

    /// A moment for two: they meet and wink, one chases the other, one
    /// follows the other around, or (with music on) they dance side by
    /// side. At most every 90 seconds, only when both are free on the floor
    /// and nothing needs anyone's attention.
    private func together(_ forcedKind: Together? = nil) {
        guard mascots.count >= 2, let w = currentWorld() else { return }
        let a = mascots[0], b = mascots[1]
        let free = [a, b].allSatisfy { $0.interruptible && $0.state.surface == .floor && !$0.state.asleep && $0.followUntil == nil
            && !$0.cameo && Date().timeIntervalSince($0.reactedAt) > 8 }
        guard free || forcedKind != nil else { return }
        if forcedKind == nil {
            guard Date().timeIntervalSince(lastTogether) > 90, signals.claude != .waiting, signals.followX == nil,
                  signals.idleSeconds < 120 else { return }
        }
        lastTogether = Date()
        let kind = forcedKind ?? (signals.musicPlaying && Bool.random() ? .dance : [Together.meet, .chase, .follow].randomElement()!)
        for m in [a, b] {
            let p = m.position
            stop(m)
            m.state.position = p
            without { m.holder.position = p }
            m.reactedAt = Date()
        }
        func walk(_ m: Mascot, to x: CGFloat, _ gait: String) -> (steps: [Step], seconds: Double) {
            let g = m.moves.has(gait) ? gait : "Walk"
            let speed = max(m.moves.action(g).speed(size: size), size * 0.3)
            let t = Double(abs(x - m.position.x) / speed)
            guard t > 0.05 else { return ([], 0) }
            return ([.face(right: x > m.position.x), .move(g, to: CGPoint(x: x, y: w.floor), seconds: t)], t)
        }
        func wait(_ t: Double) -> [Step] { t > 0.05 ? [.play("Stand", seconds: t)] : [] }
        func greet(_ m: Mascot) -> [Step] {
            m.moves.extras.contains("Wink") ? [.play("Wink", seconds: max(m.moves.action("Wink").duration, 1))] : Brain.hops(at: m.position, count: 1, world: w, moves: m.moves)
        }
        // Two free spots side by side near x (off icons and widgets), left
        // one first: searched outward from x until both fit.
        func pair(near x: CGFloat) -> (CGFloat, CGFloat) {
            let gap = size * 1.1
            func free(_ c: CGFloat) -> Bool { w.lane.contains(c) && w.blocked(c) == nil }
            for k in 0...80 {
                for c in [x - gap / 2 + CGFloat(k) * size * 0.25, x - gap / 2 - CGFloat(k) * size * 0.25] where free(c) && free(c + gap) {
                    return (c, c + gap)
                }
            }
            let l = Brain.freeSpot(near: x, others: [], world: w)
            return (l, w.clampX(l + gap))
        }
        func play(_ m: Mascot, _ steps: [Step]) {
            let plan = Brain.offDock(steps, from: m.state, world: w, moves: m.moves) + [.play("Stand", seconds: 0.5)]
            // Busy for as long as the moment lasts (signal changes would
            // otherwise make it rethink halfway).
            let seconds = plan.reduce(0.0) { t, step in
                switch step {
                case .play(_, let s), .move(_, _, let s): return t + s
                case .flight(_, _, let s, _): return t + s
                default: return t
                }
            }
            m.busyUntil = Date().addingTimeInterval(seconds)
            run(m, plan)
        }
        let (first, second) = a.position.x < b.position.x ? (a, b) : (b, a)
        switch kind {
        case .meet, .dance:
            let (l, r) = pair(near: (first.position.x + second.position.x) / 2)
            // Far apart: they run to each other instead of a 20-second stroll.
            func gait(_ m: Mascot, _ x: CGFloat) -> String { abs(x - m.position.x) > size * 4 ? "Run" : "Walk" }
            let wl = walk(first, to: l, gait(first, l)), wr = walk(second, to: r, gait(second, r))
            let arrive = max(wl.seconds, wr.seconds)
            if kind == .meet {
                BuddyLog.write("\(first.name) and \(second.name) meet")
                play(first, wl.steps + wait(arrive - wl.seconds) + [.face(right: true)] + greet(first) + [.play("Sit", seconds: 8)])
                play(second, wr.steps + wait(arrive - wr.seconds) + [.face(right: false)] + greet(second) + [.play("Sit", seconds: 8)])
            } else {
                BuddyLog.write("\(first.name) and \(second.name) dance together")
                func moves(_ m: Mascot, _ p: CGFloat, facing right: Bool) -> [Step] {
                    let at = CGPoint(x: p, y: w.floor)
                    var s: [Step] = [.face(right: right)]
                    for i in 0..<3 {
                        s += Brain.hops(at: at, count: 1, world: w, moves: m.moves)
                        s += [.face(right: i % 2 == 0 ? !right : right), .play("Stand", seconds: 0.45)]
                    }
                    return s + (m.moves.has("SitAndSpinHead") ? [.play("SitAndSpinHead", seconds: 4.8)] : [])
                }
                play(first, wl.steps + wait(arrive - wl.seconds) + moves(first, l, facing: true))
                play(second, wr.steps + wait(arrive - wr.seconds) + moves(second, r, facing: false))
            }
        case .chase:
            // One runs off a few body-widths, the other runs after it and
            // catches up; the caught one hops, the chaser sits, pleased.
            let (chaser, runner) = Bool.random() ? (first, second) : (second, first)
            let away: CGFloat = runner.position.x >= chaser.position.x ? 1 : -1
            var goal = Brain.freeSpot(near: w.clampX(runner.position.x + away * size * CGFloat.random(in: 3...5)), others: [], world: w)
            if (goal - chaser.position.x) * away < size * 1.5 { goal = Brain.freeSpot(near: w.clampX(chaser.position.x - away * size * 4), others: [], world: w) }
            let dir: CGFloat = goal >= chaser.position.x ? 1 : -1
            let behind = Brain.freeSpot(near: goal - dir * size * 1.1, others: [goal], world: w)
            BuddyLog.write("\(chaser.name) chases \(runner.name)")
            let run1 = walk(runner, to: goal, "Run"), run2 = walk(chaser, to: behind, "Run")
            let caught = max(run1.seconds, run2.seconds + 0.4)
            play(runner, run1.steps + wait(caught - run1.seconds) + [.face(right: behind > goal)]
                 + Brain.hops(at: CGPoint(x: goal, y: w.floor), count: 2, world: w, moves: runner.moves) + [.play("Sit", seconds: 5)])
            play(chaser, wait(0.4) + run2.steps + [.face(right: goal > behind), .play("Sit", seconds: 6)])
        case .follow:
            // The leader strolls somewhere; the other tags along a step behind.
            let (leader, tagger) = Bool.random() ? (first, second) : (second, first)
            let goal = Brain.freeSpot(near: w.clampX(CGFloat.random(in: w.lane)), others: [], world: w)
            let dir: CGFloat = goal >= leader.position.x ? 1 : -1
            let behind = Brain.freeSpot(near: goal - dir * size * 1.1, others: [goal], world: w)
            BuddyLog.write("\(tagger.name) follows \(leader.name)")
            let lw = walk(leader, to: goal, "Walk"), tw = walk(tagger, to: behind, "Walk")
            play(leader, lw.steps + wait(max(0, tw.seconds + 0.8 - lw.seconds)) + [.face(right: behind > goal), .play("Stand", seconds: 1)] + greet(leader))
            play(tagger, wait(0.8) + tw.steps + [.face(right: goal > behind), .play("Stand", seconds: 1)] + greet(tagger))
        }
    }

    private func cheer() {
        guard let w = currentWorld() else { return }
        for m in mascots where m.interruptible {
            BuddyLog.write("\(m.name) cheers")
            let p = m.position
            stop(m)
            m.state.position = p
            without { m.holder.position = p }
            run(m, Brain.hops(at: p, count: 2, world: w, moves: m.moves) + [.play("Stand", seconds: 0.6)])
        }
    }

    /// During a notch alert the first buddy that can hang from the ceiling
    /// pops up beside the notch, at most every 2 minutes, and drops back
    /// down when it ends. The test script ignores real alerts.
    private func notchAlert(_ id: String?) {
        if let id, id != "hud", id != "drop" {
            if forced != nil, id != "test-alert" { return }
            // Banners always get one (unless someone hangs there already);
            // DockWings' own alerts at most every 2 minutes.
            guard live, !Notch.shared.locked, !mascots.contains(where: \.cameo),
                  Date().timeIntervalSince(lastCameo) > 120 || id == "test-alert" || id == "banner",
                  let w = currentWorld() else { return }
            lastCameo = Date()
            guard w.notchX != nil, let m = mascots.first(where: { $0.moves.has("GrabCeiling") && $0.interruptible }) else {
                // No one can hang: hop for attention instead.
                for m in mascots where m.interruptible {
                    let p = m.position
                    stop(m)
                    m.state.position = p
                    without { m.holder.position = p }
                    run(m, Brain.hops(at: p, count: 1, world: w, moves: m.moves))
                }
                return
            }
            BuddyLog.write("\(m.name) hangs by the notch for alert \(id)")
            stop(m)
            m.cameo = true
            m.state.surface = .ceiling
            m.state.facingRight = false
            // Out of the notch: from inside its band, sideways and down, clear
            // of the widened notch.
            var out = CGPoint(x: w.clampX(w.notchX ?? w.maxX / 2), y: w.ceiling)
            if let n = w.notch {
                out.x = w.clampX(max(out.x, (n.lowerBound + n.upperBound) / 2 + Notch.shared.shapeWidth / 2 + size * 0.6))
            }
            let inside = CGPoint(x: (w.notch?.upperBound ?? out.x) - size * 0.5, y: w.ceiling - w.notchDepth + size)
            m.state.position = w.notch == nil ? out : inside
            without { m.holder.position = m.state.position }
            flip(m)
            run(m, [.move("ClimbCeiling", to: out, seconds: 0.6), .play("GrabCeiling", seconds: 600)])
        } else if id == nil, let w = currentWorld() {
            for m in mascots where m.cameo {
                m.cameo = false
                // Picked up or moved on meanwhile: leave it be.
                guard m.state.surface == .ceiling else { continue }
                stop(m)
                run(m, Brain.letGo(from: m.state.position, world: w))
            }
        }
    }

    /// macOS notification banners: Notification Center opens a window for each
    /// one (Accessibility tells us, no polling); a buddy hangs by the notch
    /// while it shows.
    private var bannerWatch: AXObserver?

    private func watchBanners() {
        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return }
        var observer: AXObserver?
        guard AXObserverCreate(nc.processIdentifier, { _, element, name, refcon in
            guard let refcon else { return }
            let buddy = Unmanaged<Buddy>.fromOpaque(refcon).takeUnretainedValue()
            let created = (name as String) == kAXWindowCreatedNotification
            var sub: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &sub)
            MainActor.assumeIsolated {
                if created, sub as? String == "AXSystemDialog" {
                    BuddyLog.write("notification banner")
                    buddy.notchAlert("banner")
                } else if !created, buddy.mascots.contains(where: \.cameo), Notch.shared.alert == nil {
                    buddy.notchAlert(nil)
                }
            }
        }, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(nc.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, me)
        AXObserverAddNotification(observer, app, kAXUIElementDestroyedNotification as CFString, me)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        bannerWatch = observer
    }

    /// The notch widened or the pointer is over it: whoever hangs in its
    /// new span scurries out to its edge, one hiding inside pops out, and they
    /// look back at it before dropping. The alert's own buddy keeps hanging.
    private func notchGrew(_ width: CGFloat) {
        guard live, let w = currentWorld(), let n = w.notch else { return }
        let mid = (n.lowerBound + n.upperBound) / 2
        let span = max(width, n.upperBound - n.lowerBound) / 2
        for m in mascots where m.state.surface == .ceiling {
            let p = m.position
            guard abs(p.x - mid) < span + size * 0.5 else { continue }
            let right = p.x > mid
            let edge = CGPoint(x: w.clampX(mid + (right ? 1 : -1) * (span + size * 0.6)), y: w.ceiling)
            let cameo = m.cameo
            BuddyLog.write("\(m.name) gets out of the widened notch")
            stop(m)
            m.state.position = p
            without { m.holder.position = p }
            var steps: [Step] = [.face(right: right)]
            if p.y > w.ceiling {
                // Hiding inside: out of the side, quickly.
                steps.append(.move("ClimbCeiling", to: CGPoint(x: right ? n.upperBound - size * 0.5 : n.lowerBound + size * 0.5,
                                                               y: w.ceiling - w.notchDepth + size), seconds: 0.2))
            }
            steps += [.move("ClimbCeiling", to: edge, seconds: 0.45), .face(right: !right)]
            steps += cameo ? [.play("GrabCeiling", seconds: 600)]
                : [.play("GrabCeiling", seconds: m.dice.range(1.5...3))] + Brain.letGo(from: edge, world: w)
            run(m, steps)
        }
    }

    // MARK: Pointer

    /// The pointer is low, where the Dock and the wings are, and Option isn't
    /// held: buddies get out of its way and let clicks through.
    private func yielding(_ p: NSPoint) -> Bool {
        guard let floor, p.y < floor + size * 1.8 else { return false }
        return !NSEvent.modifierFlags.contains(.option)
    }

    private func mascot(at p: NSPoint) -> Mascot? {
        // Near the Dock and the wings clicks go to what is underneath,
        // unless Option is held (to grab a buddy).
        if yielding(p) { return nil }
        return mascots.reversed().first { m in
            let b = m.box
            return b.insetBy(dx: b.width * 0.2, dy: b.height * 0.1).contains(p)
        }
    }

    /// Fed every pointer move: the panel takes clicks only over a character.
    func track(_ mouse: NSPoint) {
        guard panel.alphaValue > 0 else {
            panel.ignoresMouseEvents = true
            watch?.invalidate()
            watch = nil
            return
        }
        let p = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        // Out of the pointer's way near the Dock.
        if held == nil, yielding(p), let w = world {
            for m in mascots where m.interruptible && m.state.surface == .floor && Date() > m.fleeAfter && m.followUntil == nil
                && abs(m.position.x - p.x) < size * 1.3 {
                m.fleeAfter = Date().addingTimeInterval(1.2)
                BuddyLog.write("\(m.name) runs from the pointer at \(Int(p.x))")
                let q = m.position
                stop(m)
                m.state.position = q
                without { m.holder.position = q }
                run(m, Brain.spaced(Brain.flee(m.state, from: p.x, world: w, moves: m.moves), from: m.state,
                                    others: others(than: m), world: w, moves: m.moves))
            }
        }
        // The pointer at the notch: anyone hiding in it or hanging by it scurries out.
        if let w = world, let n = w.notch, p.y > w.ceiling - w.notchDepth - size * 0.5,
           p.x > n.lowerBound - size * 0.5, p.x < n.upperBound + size * 0.5, Date().timeIntervalSince(lastPoke) > 3 {
            lastPoke = Date()
            notchGrew(Notch.shared.shapeWidth)
        }
        // While one rides a file drag the drop must reach the app below:
        // the panel takes no clicks then.
        let over = ride != nil || fileDrag ? nil : held ?? mascot(at: p)
        if over !== lastOver {
            lastOver = over
            BuddyLog.write("pointer over \(over?.name ?? "nothing") at \(Int(p.x)),\(Int(p.y))")
        }
        if panel.ignoresMouseEvents == (over != nil) { panel.ignoresMouseEvents = over == nil }
        // Hovering a while pets it.
        for m in mascots {
            if m === over, held == nil {
                if m.hoverSince == nil { m.hoverSince = Date() }
                if let since = m.hoverSince, Date().timeIntervalSince(since) > 0.8, Date().timeIntervalSince(m.lastPet) > 6, m.interruptible {
                    pet(m)
                }
            } else {
                m.hoverSince = nil
            }
        }
        // While the panel has the pointer the global monitor goes quiet, so
        // check a few times a second for hovering and fleeing, even while the
        // pointer rests near the bottom of the screen.
        let low = floor.map { p.y < $0 + size * 2.5 } ?? false
        if over != nil || low, watch == nil {
            watch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [unowned self] _ in
                MainActor.assumeIsolated { self.track(NSEvent.mouseLocation) }
            }
        } else if over == nil, !low {
            watch?.invalidate()
            watch = nil
        }
    }

    private func pet(_ m: Mascot) {
        m.lastPet = Date()
        BuddyLog.write("\(m.name) is petted")
        let p = m.position
        stop(m)
        m.state.position = p
        without { m.holder.position = p }
        let happy = m.moves.extras.first { $0.lowercased().contains("pet") || $0.lowercased().contains("nuzzle") }
        if let happy {
            run(m, [.play(happy, seconds: max(m.moves.action(happy).duration, 1.5))])
        } else if let w = currentWorld() {
            run(m, [.play(m.moves.has("SitAndLookUp") ? "SitAndLookUp" : "Stand", seconds: 0.8)]
                + Brain.hops(at: p, count: 1, world: w, moves: m.moves))
        }
    }

    private func pressed(_ p: NSPoint, count: Int) {
        BuddyLog.write("mouse down \(count) at \(Int(p.x)),\(Int(p.y)) on \(mascot(at: p)?.name ?? "nothing")")
        guard live, let m = mascot(at: p) else { return }
        // Double-click: jump.
        if count >= 2 {
            pendingClick?.cancel()
            press = nil
            held = nil
            if m.interruptible, let w = currentWorld() {
                BuddyLog.write("\(m.name) double-clicked, jumps")
                let q = m.position
                stop(m)
                m.state.position = q
                without { m.holder.position = q }
                run(m, Brain.hops(at: q, count: 1, world: w, moves: m.moves))
            }
            return
        }
        held = m
        press = p
        samples = [(p, ProcessInfo.processInfo.systemUptime)]
        grab = CGPoint(x: m.position.x - p.x, y: m.position.y - p.y)
    }

    private func carry(_ p: NSPoint) {
        guard let m = held else { return }
        if let start = press {
            guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
            press = nil
            BuddyLog.write("\(m.name) picked up")
            stop(m)
            m.state.surface = .air
            m.state.asleep = false
            m.doing = .play("Pinched", seconds: 0)
        }
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((p, now))
        samples = samples.filter { now - $0.t < 0.12 }
        let v = velocity()
        // Swinging: moving left the body trails right of the hand (9/7/5), right 6/8/10.
        let frames: [(CGFloat, Int)] = [(-600, 9), (-250, 7), (-60, 5), (60, 1), (250, 6), (600, 8)]
        let n = frames.first { v.dx < $0.0 }?.1 ?? 10
        let hasSwing = (5...10).allSatisfy { m.pack.frames["shime\($0).png"] != nil }
        without {
            m.sprite.removeAnimation(forKey: "frames")
            m.sprite.contents = hasSwing ? m.pack.frames["shime\(n).png"] : (m.pack.frames["shime4.png"] ?? m.pack.frames["shime1.png"])
            m.sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
            m.state.facingRight = false
            m.sprite.transform = CATransform3DIdentity
            let q = CGPoint(x: p.x + grab.x, y: p.y + grab.y)
            if q.x.isFinite, q.y.isFinite { m.holder.position = q }
        }
        m.action = "Pinched"
    }

    private func velocity() -> CGVector {
        guard let a = samples.first, let b = samples.last, b.t - a.t > 0.005 else { return .zero }
        let v = CGVector(dx: (b.p.x - a.p.x) / CGFloat(b.t - a.t), dy: (b.p.y - a.p.y) / CGFloat(b.t - a.t))
        return v.dx.isFinite && v.dy.isFinite ? v : .zero
    }

    private func released() {
        guard let m = held else { return }
        held = nil
        if press != nil {
            // A click: the library opens above it, unless a second click comes.
            press = nil
            let x = m.position.x
            let item = DispatchWorkItem {
                let drawers = Drawers.shared
                if drawers.open == "buddy" { drawers.open = nil } else { drawers.anchorX = x; drawers.open = "buddy" }
            }
            pendingClick = item
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: item)
            return
        }
        throwAway(m, velocity: velocity())
    }

    /// A file drag started: the nearest buddy leaps from where it is to just
    /// under the pointer and swings from the dragged item.
    private func catchDrag() {
        guard live, forced == nil, held == nil, Date().timeIntervalSince(born) > 5 else { return }
        let f = panel.frame
        let at = { NSPoint(x: NSEvent.mouseLocation.x - f.minX, y: NSEvent.mouseLocation.y - f.minY) }
        let p = at()
        guard let m = mascots.filter(\.interruptible).min(by: { abs($0.position.x - p.x) < abs($1.position.x - p.x) }) else { return }
        BuddyLog.write("\(m.name) grabs the dragged file")
        held = m
        press = nil
        samples = [(p, ProcessInfo.processInfo.systemUptime)]
        // Packs with a hanging-by-the-hands pose hold the item's bottom edge
        // with it (the frame's anchor is the hands); others swing as if held.
        let hands = m.moves.has("GrabCeiling") && !m.moves.climbsByWalking
        grab = CGPoint(x: m.position.x - p.x, y: m.position.y + (hands ? size : 0) - p.y)
        stop(m)
        m.state.surface = .air
        m.state.asleep = false
        m.state.facingRight = false
        if hands {
            m.doing = .play("GrabCeiling", seconds: 0)
            show(m, "GrabCeiling")
        } else {
            m.doing = .play("Pinched", seconds: 0)
        }
        let hang = CGPoint(x: dragHang.x, y: -dragHang.y - (hands ? 0 : size))
        ride = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated {
                // Closes the gap to the pointer over about half a second.
                self.grab.x += (hang.x - self.grab.x) * 0.2
                self.grab.y += (hang.y - self.grab.y) * 0.2
                let p = at()
                guard hands else { return self.carry(p) }
                let now = ProcessInfo.processInfo.systemUptime
                self.samples.append((p, now))
                self.samples = self.samples.filter { now - $0.t < 0.12 }
                let q = CGPoint(x: p.x + self.grab.x, y: p.y + self.grab.y)
                if q.x.isFinite, q.y.isFinite { self.without { m.holder.position = q } }
            }
        }
    }

    private func dropDrag() {
        ride?.invalidate()
        ride = nil
        guard let m = held else { return }
        held = nil
        BuddyLog.write("\(m.name) lets go of the dropped file")
        // Held by the hands: the feet are a body lower.
        if m.action == "GrabCeiling" { without { m.holder.position.y -= size } }
        throwAway(m, velocity: velocity())
    }

    private func throwAway(_ m: Mascot, velocity v: CGVector) {
        guard let w = currentWorld() else { return }
        BuddyLog.write(String(format: "\(m.name) thrown at %.0f, %.0f pt/s", v.dx, v.dy))
        m.state.position = m.holder.position
        run(m, Brain.thrown(from: m.state.position, velocity: v, world: w))
    }

    // MARK: Menu

    private func menu(at p: NSPoint) {
        guard live, let m = mascot(at: p) else { return }
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) {
            let target = MenuTarget(action)
            let i = NSMenuItem(title: title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            i.target = target
            i.representedObject = target
            menu.addItem(i)
        }
        let following = m.followUntil != nil
        item("Sit") { [unowned self] in self.force(m, [.play("Sit", seconds: 12)]) }
        item("Sleep") { [unowned self] in
            self.force(m, [.sleep(true), .play(m.moves.has("Sprawl") ? "Sprawl" : "Sit", seconds: 3)])
        }
        if let dance = m.moves.extras.first(where: { $0.lowercased().contains("dance") }) ?? (m.moves.has("SitAndSpinHead") ? "SitAndSpinHead" : nil) {
            item("Dance") { [unowned self] in self.force(m, [.play(dance, seconds: 6)]) }
        }
        for extra in m.moves.extras.prefix(6) where !extra.lowercased().contains("dance") {
            item(extra) { [unowned self] in self.force(m, [.play(extra, seconds: max(m.moves.action(extra).duration, 1.5))]) }
        }
        menu.addItem(.separator())
        item(following ? "Stop following" : "Follow the pointer") { [unowned self] in
            m.followUntil = following ? nil : .distantFuture
            self.replan(m)
        }
        item("Characters…") {
            Drawers.shared.anchorX = m.position.x
            Drawers.shared.open = "buddy"
        }
        item("Put \(m.name) away") { BuddyRoster.toggle(m.path) }
        menu.popUp(positioning: nil, at: p, in: view)
    }

    private func force(_ m: Mascot, _ steps: [Step]) {
        guard m.interruptible || m.state.asleep else { return }
        let p = m.position
        stop(m)
        m.state.position = p
        m.state.asleep = false
        without { m.holder.position = p }
        run(m, steps)
    }

    // MARK: Test script

    /// Runs every behaviour on the first buddy (and a meeting with the
    /// second, if out), logging each step. Signals are faked; dragging and
    /// throwing go through the same code as the mouse, with made-up points.
    private func runTest(_ which: String) {
        guard let m = mascots.first, let w0 = currentWorld() else { return }
        BuddyLog.write("TEST start: \(mascots.map(\.name)), size \(size), floor \(w0.floor), ceiling \(w0.ceiling), notch \(String(describing: w0.notchX))")
        var script: [(String, Double, () -> Void)] = []
        func at(_ label: String, _ wait: Double, _ body: @escaping () -> Void) { script.append((label, wait, body)) }
        let mid = w0.maxX / 2
        func plan(_ steps: [Step]) {
            let p = m.position
            stop(m)
            m.state.position = p
            m.state.asleep = false
            without { m.holder.position = p }
            run(m, steps)
        }
        func go(_ x: CGFloat, _ gait: String) -> [Step] {
            let from = m.position.x
            let speed = max(m.moves.action(gait).speed(size: size), size * 0.2)
            return [.surface(.floor), .face(right: x > from), .move(gait, to: CGPoint(x: x, y: w0.floor), seconds: Double(abs(x - from) / speed))]
        }
        forced = Signals()
        at("walk", 6) { plan(go(mid, "Walk")) }
        at("run", 4) { plan(go(mid + 300, "Run")) }
        at("creep", 4) { plan(go(mid + 240, "Creep")) }
        at("trip", 3) { plan([.play("Tripping", seconds: m.moves.action("Tripping").duration), .play("Stand", seconds: 1)]) }
        at("hop", 2) { plan(Brain.hops(at: m.position, count: 1, world: w0, moves: m.moves)) }
        at("sit + spin head", 5) { plan([.play("Sit", seconds: 2), .play("SitAndSpinHead", seconds: 2.4)]) }
        for extra in m.moves.extras.prefix(3) { at("extra \(extra)", 3) { plan([.play(extra, seconds: 2.5)]) } }
        at("crawl past notch", 40) { var d = m.dice; plan(Brain.climb(from: m.position, toCeilingX: m.position.x < mid ? w0.maxX * 0.75 : w0.maxX * 0.25, thenHang: true, world: w0, moves: m.moves, dice: &d)) }
        at("notch visit", 60) { var d = m.dice; plan(Brain.notchVisit(from: m.position, world: w0, moves: m.moves, dice: &d)) }
        at("open test window", 2) { [unowned self] in self.openTestWindow() }
        at("visit window", 20) { [unowned self] in
            guard let w = self.currentWorld(), let p = w.windows.first else { BuddyLog.write("TEST no window found"); return }
            let top = CGPoint(x: (p.minX + p.maxX) / 2, y: p.y)
            if p.y - w.floor < self.size * 8 || !m.moves.canClimb {
                plan(Brain.jump(from: m.position, to: top, lift: self.size * 0.5, world: w, moves: m.moves))
            } else {
                var d = m.dice
                plan(Brain.climb(from: m.position, toCeilingX: top.x, thenHang: false, world: w, moves: m.moves, dice: &d))
            }
        }
        at("ride check", 10) {}
        at("window moves", 4) { [unowned self] in
            guard let t = self.testWindow else { return }
            t.setFrameOrigin(NSPoint(x: t.frame.minX + 120, y: t.frame.minY + 40))
        }
        at("window closes", 6) { [unowned self] in self.testWindow?.orderOut(nil); self.testWindow = nil }
        at("claude working", 8) { [unowned self] in self.forced = Signals(); self.forced?.claude = .working; self.forced?.claudeX = mid - 200; self.replan(m) }
        at("claude waiting", 8) { [unowned self] in self.forced?.claude = .waiting; self.replan(m) }
        at("claude done", 4) { [unowned self] in self.forced?.claude = .none; self.cheer() }
        at("music", 8) { [unowned self] in self.forced = Signals(); self.forced?.musicPlaying = true; self.replan(m) }
        at("beat", 2) { [unowned self] in
            if self.forced == nil { self.forced = Signals() }
            self.forced?.musicPlaying = true
            self.force(m, [.play(m.moves.has("SitAndSpinHead") ? "SitAndSpinHead" : "Stand", seconds: 2)])
            for i in 0..<20 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) { self.beat([i % 2 == 0 ? 0.9 : 0.1]) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { BuddyLog.write("TEST beat lift \(m.holder.transform.m42) doing \(String(describing: m.doing)) on \(m.state.surface) music \((self.forced ?? self.signals).musicPlaying) live \(self.live)") }
        }
        at("typing", 5) { [unowned self] in self.forced = Signals(); self.forced?.typing = true; self.replan(m) }
        at("low battery", 6) { [unowned self] in self.forced = Signals(); self.forced?.lowBattery = true; self.replan(m) }
        at("hot", 6) { [unowned self] in self.forced = Signals(); self.forced?.hot = true; self.replan(m) }
        at("new download", 6) { [unowned self] in self.forced = Signals(); self.forced?.attentionX = 200; self.replan(m) }
        at("idle -> sleep", 8) { [unowned self] in self.forced = Signals(); self.forced?.idleSeconds = 500; self.replan(m) }
        at("wake", 4) { [unowned self] in self.forced?.idleSeconds = 0; self.wake(m) }
        at("follow pointer", 5) { [unowned self] in m.followUntil = .distantFuture; self.replan(m) }
        at("stop follow", 1) { [unowned self] in m.followUntil = nil; self.replan(m) }
        at("pet", 3) { [unowned self] in self.pet(m) }
        at("double-click jump", 3) { [unowned self] in self.pressed(m.box.center, count: 2) }
        at("drag and throw", 7) { [unowned self] in
            let start = m.box.center
            self.pressed(start, count: 1)
            for i in 1...12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.016) {
                    self.carry(NSPoint(x: start.x + CGFloat(i) * 25, y: start.y + CGFloat(i) * 30))
                    if i == 12 { self.released() }
                }
            }
        }
        at("notch alert hang", 4) { [unowned self] in self.notchAlert("test-alert") }
        at("notch alert ends", 4) { [unowned self] in self.notchAlert(nil) }
        if mascots.count > 1 {
            at("together meet", 16) { [unowned self] in self.forced = Signals(); self.together(.meet) }
            at("together chase", 14) { [unowned self] in self.forced = Signals(); self.together(.chase) }
            at("together follow", 18) { [unowned self] in self.forced = Signals(); self.together(.follow) }
            at("together dance", 14) { [unowned self] in self.forced = Signals(); self.together(.dance) }
            at("meeting", 10) { [unowned self] in
                self.forced = Signals()
                plan(go(self.mascots[1].position.x + self.size * 1.2, "Walk"))
            }
        }
        at("free play", 30) { [unowned self] in self.forced = nil; self.replan(m) }
        if which != "all" { script = script.filter { $0.0.contains(which) || $0.0 == "free play" } }
        var delay = 1.0
        for (label, wait, body) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                BuddyLog.write("TEST \(label)")
                body()
            }
            delay += wait
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { BuddyLog.write("TEST done") }
    }

    /// A plain window made by DockWings, to climb on in the test.
    private func openTestWindow() {
        guard let screen else { return }
        let w = NSWindow(contentRect: NSRect(x: screen.frame.midX - 300, y: screen.frame.minY + 160, width: 600, height: 300),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Buddy test window"
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        testWindow = w
        BuddyLog.write("TEST window \(w.windowNumber) at \(w.frame)")
    }
}

private final class MenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ sender: Any?) { action() }
}

private final class BuddyView: NSView {
    var down: ((NSPoint, Int) -> Void)?
    var drag: ((NSPoint) -> Void)?
    var up: (() -> Void)?
    var rightClick: ((NSPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down?(convert(event.locationInWindow, from: nil), event.clickCount) }
    override func mouseDragged(with event: NSEvent) { drag?(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { up?() }
    override func rightMouseDown(with event: NSEvent) { rightClick?(convert(event.locationInWindow, from: nil)) }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
