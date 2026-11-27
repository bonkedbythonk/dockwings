// The camera notch on the built-in display: what is happening right now.
// At rest it draws nothing (the shape sits just inside the hardware notch).
// An alert widens the notch sideways, one line tall: an icon left of the
// camera, a short value right of it. An alert that needs you drops it into a
// card by itself (click runs its action); hovering or a swipe down opens the
// card, a swipe up dismisses. Alerts: Claude (needs you, done), headphones,
// power, heat, downloads (Downloads.swift), the volume and brightness HUD
// (MediaKeys.swift) and the file tray while dragging. Music, shelf and the
// rest stay in the wings, except with the Dock bar (`Bar` key): there the
// playing track lives here, and in full screen music and a Claude chat that
// needs you stay too. Otherwise in full screen only the HUD shows. The shape
// springs out of the notch with outward-curved top corners; content fades
// in as it settles. The window is fixed, top-centred on the notch; only the
// shape inside morphs. AppDelegate places it (independent of the Dock).
import AppKit
import AVFoundation
import Combine
import SwiftUI

struct NotchAlert {
    enum Icon { case symbol(String, Color, Motion = .bounce), claude(ClaudeStatus.State), image(NSImage), airpods(String, Int?), none }
    /// How a symbol icon moves: a bounce when it appears, or keeps going
    /// while the alert is up; `swap` animates the change between symbols (HUD).
    enum Motion { case bounce, dropping, pulse, wiggle, swap }
    enum Trailing { case text(String, Color), symbol(String, Color), bars(LiveLevels), level(Double), ring(Double, Color), battery(Int, Color, charging: Bool), done, none }

    /// Same id replaces the alert in place (e.g. a cover arriving late).
    let id: String
    var icon: Icon
    var trailing: Trailing = .none
    var title: String
    var subtitle: String
    /// Seconds on screen; 0 stays until cleared.
    var duration: TimeInterval = 3
    /// Needs you: opens as the card for a few seconds, then stays compact.
    var opensCard = false
    /// No card: a click on the notch runs the action at once (the WaniKani
    /// tile, which opens its drawer).
    var tapOpens = false
    /// Shows at once, ahead of whatever is on screen (the volume HUD).
    var jumpsQueue = false
    /// A word beside the icon in the one-line state (the HUD: "Sound").
    var label: String?
    /// Allow / Deny on the card (a Claude permission prompt).
    var approve: ((Bool) -> Void)?
    var action: (() -> Void)?
    var posted = Date()
}

@MainActor
final class Notch: ObservableObject {
    static let shared = Notch()

    @Published private(set) var alert: NotchAlert? {
        didSet {
            let widget = Self.widget(for: alert?.id)
            if pointsAt != widget { pointsAt = widget }
        }
    }
    /// The Dock widget the current alert is about (it hops when this
    /// changes), nil for none. Changes only with the alert, so the wings
    /// don't redraw on hover.
    @Published private(set) var pointsAt: String?

    static func widget(for id: String?) -> String? {
        guard let id else { return nil }
        if id.hasPrefix("claude-") { return "claude" }
        if id.hasPrefix("wk-") { return "wanikani" }
        switch id {
        case "pods", "power", "thermal": return "batteries"
        case "kept": return "shelf"
        default: return nil
        }
    }
    /// The pointer is over the shape.
    @Published var hovering = false {
        didSet {
            // Leaving closes the card and the grown player, however they
            // were opened. A review in the grown WaniKani panel stays open
            // (typing answers shouldn't need the pointer up here); a click
            // elsewhere still closes it.
            if !hovering { clicked = false; cardShown = false; if !reviewing { expanded = false } }
            if !hovering, let id = finishWhenLeft { finishWhenLeft = nil; clear(id) }
        }
    }
    /// The card was clicked: it folds away and hovering doesn't reopen it
    /// until the pointer has left (what it opened may sit right below).
    @Published private var clicked = false

    func run(_ a: NotchAlert) {
        fold()
        a.action?()
    }

    /// Closes the card until the pointer leaves, so what a click opened
    /// right below (the music drawer) isn't covered by it.
    func fold() {
        cardShown = false
        clicked = true
    }
    @Published private(set) var cardShown = false
    /// The notch window can be seen (looping animations stop otherwise).
    @Published var visible = true
    /// Size of the hardware notch.
    @Published var size = CGSize(width: 185, height: 32)
    /// The shape's frame in the window (top-left origin).
    var frame = CGRect.zero

    static let windowSize = CGSize(width: 480, height: 640)

    /// Swipe down on the notch: music and WaniKani grow into the big
    /// player or panel; other alerts show their card.
    func swipeDown() {
        guard alert != nil else { return }
        if Self.grows(alert?.id) { expanded = true } else if !cardShown { cardShown = true }
    }

    /// Swipe up: closes the card, else sends the alert away. With two things
    /// that stay (a chat that needs you and the music), it switches to the
    /// other one, so the music can be used while the question waits.
    func swipeUp() {
        // The playing track stays: swiping up only closes its card or player.
        if expanded { expanded = false; cardShown = false; clicked = true }
        else if let a = alert, a.duration == 0, a.id != "drop", !reviewing,
                let i = queue.firstIndex(where: { $0.duration == 0 }) {
            var current = a
            current.opensCard = false
            let next = queue.remove(at: i)
            queue.append(current)
            show(next)
        }
        else if cardShown { cardShown = false }
        // Ongoing things (music, WaniKani, a chat that needs you: no timer)
        // aren't swiped away, only passing alerts.
        else if let a = alert, a.id != "drop", a.duration > 0 { forceClear(a.id) }
    }

    /// Hover or a swipe opens the alert's card; an alert that needs you opens
    /// it by itself. During a file drag the drop card is open from the start,
    /// reaching well below the screen edge (dragging up to the very top opens
    /// Mission Control).
    var showsCard: Bool { alert != nil && alert?.id != "hud" && alert?.tapOpens != true && (cardShown || (hovering && !clicked) || (dragging && alert?.id == "drop") || (expanded && Self.grows(alert?.id))) }

    /// Alerts whose card grows into a whole panel in the notch on a click:
    /// the music, and with the Dock bar WaniKani (reviews happen up here).
    static func grows(_ id: String?) -> Bool { id == "music" || (Config.bar && (id == "wk" || id?.hasPrefix("wk-") == true)) }
    /// A WaniKani review is going on in the grown panel.
    var reviewing: Bool { expanded && alert?.id.hasPrefix("wk-") == true && WKReview.shared.phase != .idle }
    /// How wide the black shape is drawn now (same sizes as NotchView), so
    /// buddies can keep clear of it.
    var shapeWidth: CGFloat {
        guard let a = alert else { return size.width }
        if showsCard { return alert?.id == "music" ? 440 : 350 }
        return size.width + 2 * (a.label != nil || ears ? 84 : 44) + 12
    }

    /// Settings switches (on unless turned off).
    static var alertsOn: Bool { UserDefaults.standard.object(forKey: "notchAlerts") as? Bool ?? true }
    static var hudOn: Bool { UserDefaults.standard.object(forKey: "notchHUD") as? Bool ?? true }

    /// A full-screen app is in front: only the volume and brightness HUD shows.
    /// Music and WaniKani step aside over a full-screen app (a video) and come back after.
    @Published var fullScreen = false {
        didSet {
            guard fullScreen != oldValue else { return }
            guard fullScreen else { let back = parked; parked = []; back.forEach(post); return }
            let all = [alert].compactMap { $0 } + queue
            let wk = all.filter { Self.parks($0.id) }
            if expanded { expanded = false }
            for id in all.map(\.id) where !Self.fullScreenOK(id) { forceClear(id) }
            parked = wk
        }
    }
    private var parked: [NotchAlert] = []
    private static func parks(_ id: String) -> Bool { id == "music" || (id.hasPrefix("wk-") && id != "wk-open") }

    /// The screen is locked: the notch sits on the lock screen and shows
    /// only the HUD and charging, nothing private.
    @Published var locked = false {
        didSet {
            guard locked != oldValue else { return }
            if locked {
                for id in [alert?.id].compactMap({ $0 }) + queue.map(\.id) where !Self.lockSafe.contains(id) { forceClear(id) }
            }
            lockChanged?(locked)
        }
    }
    /// Music too: like the system's own lock screen player (Dock bar only posts it).
    static let lockSafe: Set<String> = ["hud", "power", "music"]
    /// Shown over a full-screen app too. With the Dock bar the Dock's widgets
    /// are hidden there, so the notch also keeps a Claude chat that needs you.
    static func fullScreenOK(_ id: String) -> Bool {
        id == "hud"
            || (Config.bar && id.hasPrefix("claude-") && !id.hasPrefix("claude-done"))
    }
    var lockChanged: ((Bool) -> Void)?

    private var queue: [NotchAlert] = []
    /// The volume or brightness HUD while the music or WaniKani card is open:
    /// the card grows a row for it instead of closing.
    @Published private(set) var hudOver: NotchAlert?
    private var hudTimer: Timer?
    private var timers: [Timer] = []
    private var finishWhenLeft: String?

    /// Shows an alert now, or after the current one. Timed alerts wait for
    /// each other; one that stays (needs you) steps aside for them and comes
    /// back compact afterwards.
    func post(_ a: NotchAlert) {
        if locked && !Self.lockSafe.contains(a.id) { return }
        if fullScreen, Self.parks(a.id) { parked.removeAll { $0.id == a.id }; parked.append(a); return }
        if a.id != "hud" && ((fullScreen && !Self.fullScreenOK(a.id)) || !Self.alertsOn) { return }
        if a.id == "hud", showsCard, Self.grows(alert?.id) {
            hudOver = a
            hudTimer?.invalidate()
            hudTimer = .scheduledTimer(withTimeInterval: a.duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hudOver = nil }
            }
            return
        }
        var a = a
        a.posted = Date()
        queue.removeAll { $0.id == a.id }
        // A WaniKani review open in the notch isn't interrupted: other
        // alerts (the volume HUD aside) wait until it closes.
        if reviewing, a.id != "hud", !a.id.hasPrefix("wk-") { queue.append(a); return }
        guard var current = alert, current.id != a.id else { show(a); return }
        if current.duration > 0 && a.duration > 0 && !a.jumpsQueue { queue.append(a); return }
        if current.duration == 0 {
            current.opensCard = false
            queue.insert(current, at: 0)
        }
        show(a, fresh: true)
    }

    private func forceClear(_ id: String) {
        finishWhenLeft = nil
        let hover = hovering
        hovering = false
        clear(id)
        hovering = hover
    }

    func clear(_ id: String) {
        queue.removeAll { $0.id == id }
        parked.removeAll { $0.id == id }
        guard alert?.id == id else { return }
        if hovering, alert?.duration ?? 0 > 0 { finishWhenLeft = id; return }
        timers.forEach { $0.invalidate() }
        cardShown = false
        // Moments that waited too long are old news.
        queue.removeAll { $0.duration > 0 && Date().timeIntervalSince($0.posted) > 8 }
        guard !queue.isEmpty else { alert = nil; return }
        // Others before the music: it joins them beside the camera (shared
        // notch), while one waiting behind the music would be hidden.
        let next = queue.remove(at: queue.firstIndex { $0.id != "music" } ?? 0)
        // The music was already showing beside it: the next one (or the
        // music itself) takes over in one move, without the notch closing
        // in between.
        if next.id == "music" || music != nil { show(next); return }
        alert = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if self.alert == nil { self.show(next) } }
    }

    private func show(_ a: NotchAlert, fresh: Bool = false) {
        let replacing = alert?.id == a.id && !fresh
        alert = a
        timers.forEach { $0.invalidate() }
        timers = []
        if !replacing { cardShown = a.opensCard }
        if a.opensCard && !replacing {
            // A prompt you can answer here stays open until it times out.
            let open = a.approve != nil ? ClaudeHooks.permissionWait : 4
            timers.append(.scheduledTimer(withTimeInterval: open, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.cardShown = false }
            })
        }
        if a.duration > 0 {
            timers.append(.scheduledTimer(withTimeInterval: a.duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.clear(a.id) }
            })
        }
    }

    /// A file being dragged: the notch offers the shelf. Set by AppDelegate.
    var dragging = false {
        didSet {
            guard dragging != oldValue else { return }
            if dragging {
                post(NotchAlert(id: "drop", icon: .symbol("tray.and.arrow.down.fill", .white, .dropping), trailing: .symbol("arrow.down", .white.opacity(0.6)),
                                title: "Drop here to keep", subtitle: "File shelf", duration: 0))
            } else {
                clear("drop")
            }
        }
    }
    var onDrop: (([URL]) -> Void)?

    private var feeds: [AnyCancellable] = []

    /// The playing track's alert while it lives in the notch (Dock bar).
    @Published private(set) var music: NotchAlert?
    /// The player, for the music card.
    private(set) var player: Music?
    /// The music card was clicked: the notch grows into the whole player
    /// (lyrics, up next, search) until the pointer leaves it.
    @Published var expanded = false {
        didSet {
            // The WaniKani panel opened from the Dock goes once it closes.
            if oldValue, !expanded { clear("wk-open") }
            // A review closed: whatever waited behind it (Claude needing you)
            // comes up now, the review's tile stepping back.
            guard oldValue, !expanded, alert?.id.hasPrefix("wk-") == true, let i = queue.firstIndex(where: { $0.id != "music" }) else { return }
            let next = queue.remove(at: i)
            post(next)
        }
    }
    /// The grown WaniKani panel's own height (it fits its content: the
    /// summary and a review question differ).
    @Published var panelHeight: CGFloat = 0
    /// Another one-line alert while music plays: they share the notch, the
    /// track left of the camera and the alert right of it.
    var ears: Bool { music != nil && !fullScreen && alert.map { $0.id != "music" && $0.label == nil } == true }

    /// Dock bar: the playing track lives in the notch (cover left of the
    /// camera, live levels right; hover for the card, click opens the
    /// player) and the Dock's music widget steps aside meanwhile. Another
    /// alert shares the notch with it (`ears`) and the track takes the whole
    /// notch again afterwards.
    func watch(music: Music) {
        guard Config.bar, Self.locate() != nil else { return }
        player = music
        var last: (String, String, NSImage?)?
        feeds.append(Publishers.CombineLatest4(music.$isPlaying, music.$title, music.$artist, music.$art)
            .receive(on: RunLoop.main).sink { [unowned self] playing, title, artist, art in
                guard playing, !title.isEmpty else { last = nil; self.music = nil; expanded = false; clear("music"); return }
                if let l = last, l.0 == title, l.1 == artist, l.2 === art { return }
                last = (title, artist, art)
                let a = NotchAlert(id: "music", icon: art.map { .image($0) } ?? .symbol("music.note", .white),
                                   trailing: .bars(music.live), title: title, subtitle: artist, duration: 0,
                                   action: { music.openPlayer() })
                self.music = a
                if let current = alert, current.id != "music", !fullScreen {
                    queue.removeAll { $0.id == "music" }
                    queue.append(a)
                } else {
                    post(a)
                }
            })
    }

    /// Turns changes in the other models into alerts. Each source's first
    /// value is its baseline; only later changes alert.
    func watch(claude: ClaudeStatus, batteries: Batteries) {
        var states: [String: ClaudeStatus.State]?
        feeds.append(claude.$sessions.sink { [unowned self] sessions in
            defer { states = sessions.mapValues(\.state) }
            guard let before = states else { return }
            for (id, s) in sessions where s.state != before[id] {
                let open = { claude.open(session: id) }
                if s.state == .waiting {
                    post(NotchAlert(id: "claude-\(id)", icon: .claude(.waiting), title: s.project, subtitle: s.activity,
                                    duration: 0, opensCard: true,
                                    approve: s.request == nil ? nil : { claude.answer(session: id, allow: $0) }, action: open))
                } else if s.state == .done, before[id] == .working {
                    post(NotchAlert(id: "claude-done-\(id)", icon: .claude(.done), trailing: .done,
                                    title: s.project, subtitle: s.prompt.isEmpty ? "Finished" : s.prompt, action: open))
                }
            }
            for (id, state) in before where state == .waiting && sessions[id]?.state != .waiting { clear("claude-\(id)") }
        })
        // The Mac getting hot enough to slow down.
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            let state = ProcessInfo.processInfo.thermalState
            guard state == .serious || state == .critical else { return }
            MainActor.assumeIsolated {
                self.post(NotchAlert(id: "thermal", icon: .symbol("thermometer.high", state == .critical ? .red : .orange, .wiggle),
                                     title: state == .critical ? "Mac is very hot" : "Mac is hot",
                                     subtitle: "Slowing down to cool off", duration: 4))
            }
        }
        // Headphones connecting: Batteries says so first; the device and its
        // level show up in its list a moment later.
        var waitingFor: Set<String>?
        NotificationCenter.default.addObserver(forName: .audioConnected, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { waitingFor = Set(batteries.items.map(\.id)) }
        }
        var mac: BatteryItem?
        feeds.append(batteries.$items.receive(on: RunLoop.main).sink { [unowned self] items in
            for item in items { if let pid = item.productID { Self.productIDs[item.name] = pid } }
            if let known = waitingFor, let device = items.first(where: { !known.contains($0.id) && $0.id != "mac" }) {
                waitingFor = nil
                post(NotchAlert(id: "pods", icon: device.symbol == "airpods" ? .airpods(device.name, device.productID) : .symbol(device.symbol, .white),
                                trailing: .ring(Double(device.percent) / 100, Self.batteryColor(device.percent)),
                                title: device.name, subtitle: "Connected · \(device.percent)%"))
            }
            guard let now = items.first(where: { $0.id == "mac" }) else { return }
            defer { mac = now }
            let on = now.charging || now.plugged
            guard let before = mac, on != (before.charging || before.plugged) else { return }
            let word = on ? (now.charging ? "Charging" : "On power") : "On battery"
            post(NotchAlert(id: "power", icon: .none, trailing: .battery(now.percent, on ? Self.green : Self.batteryColor(now.percent), charging: now.charging),
                            title: word, subtitle: "\(now.percent)%", duration: 2.5, label: word))
        })
    }

    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    /// Bluetooth product IDs by device name (from Batteries), so the HUD can
    /// tell AirPods by model even when they're renamed.
    nonisolated(unsafe) static var productIDs: [String: Int] = [:]

    /// The SF Symbol for an Apple headphone product ID, nil for others.
    nonisolated static func airpodsSymbol(_ pid: Int) -> String? {
        guard (0x2000...0x20FF).contains(pid) else { return nil }
        if [0x200A, 0x201F].contains(pid) { return "airpodsmax" }
        if [0x200E, 0x2014, 0x2024, 0x2027].contains(pid) { return "airpodspro" }
        return "airpods"
    }
    /// Battery colour like the system's: green, yellow when low, red when very low.
    static func batteryColor(_ percent: Int) -> Color {
        percent <= 10 ? Color(red: 1, green: 0.27, blue: 0.23) : percent <= 20 ? Color(red: 1, green: 0.8, blue: 0) : green
    }

    /// The notch of the first screen that has one, in screen coordinates.
    static func locate() -> (rect: NSRect, screen: NSScreen)? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { continue }
            let h = screen.safeAreaInsets.top
            return (NSRect(x: l.maxX, y: screen.frame.maxY - h, width: r.minX - l.maxX, height: h), screen)
        }
        return nil
    }

    /// Test aid (`Demo notch`): a loop of sample alerts.
    func runDemo() {
        let steps: [(TimeInterval, () -> Void)] = [
            (1, { self.post(NotchAlert(id: "claude", icon: .claude(.waiting), title: "dockwings",
                                       subtitle: "Wants to run: swift build", duration: 0, opensCard: true)) }),
            (7, { self.clear("claude") }),
            (1, { self.post(NotchAlert(id: "job", icon: .symbol("checkmark", .green), trailing: .text("42 s", .white.opacity(0.7)),
                                       title: "swift build -c release", subtitle: "Finished in 42 s")) }),
            (4, { self.post(NotchAlert(id: "wk", icon: .symbol("character.book.closed.fill", Color(red: 0.95, green: 0.35, blue: 0.6)),
                                       trailing: .text("12", Color(red: 0.95, green: 0.55, blue: 0.75)),
                                       title: "WaniKani", subtitle: "12 reviews ready")) }),
            (0.8, { self.hovering = true }),
            (2.2, { self.hovering = false }),
            (2, { self.post(NotchAlert(id: "pods", icon: .airpods("AirPods Pro", 0x2027), trailing: .ring(0.84, Notch.green),
                                       title: "AirPods Pro", subtitle: "Connected")) }),
            (4, { self.post(NotchAlert(id: "claude-done-demo", icon: .claude(.done), trailing: .done, title: "dockwings",
                                       subtitle: "Finished")) }),
            (4, { self.post(NotchAlert(id: "power", icon: .none, trailing: .battery(50, Notch.green, charging: true), title: "Charging",
                                       subtitle: "50%", duration: 2.5, label: "Charging")) }),
            (4, {}),
        ]
        var delay: TimeInterval = 0
        for (wait, step) in steps {
            delay += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.runDemo() }
    }
}

/// The notch outline: outward-curved top corners (`flare`) and rounded
/// bottom corners, both animatable.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(flare, bottom) }
        set { flare = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let f = flare, b = max(0, min(bottom, r.height - f, (r.width - 2 * f) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.minY + f), control: CGPoint(x: r.minX + f, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + f + b, y: r.maxY), control: CGPoint(x: r.minX + f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - f - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - f, y: r.maxY - b), control: CGPoint(x: r.maxX - f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY + f))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - f, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Content fades in with the shape; the old content fades out meanwhile
/// (cross-fading, so the bare notch never shows in between). No blur: a blur
/// flattens the looping layer animations inside (bars, Claude's mark).
private struct BlurIn: ViewModifier {
    let shown: Bool
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0)
    }
}

private extension AnyTransition {
    static var blurIn: AnyTransition {
        // Fades in together with the shape's change, one movement (a delay
        // made it two: shape first, content after).
        .asymmetric(insertion: .modifier(active: BlurIn(shown: false), identity: BlurIn(shown: true))
                        .animation(.easeOut(duration: 0.22)),
                    removal: .modifier(active: BlurIn(shown: false), identity: BlurIn(shown: true))
                        .animation(.easeIn(duration: 0.2)))
    }
}

struct NotchView: View {
    @ObservedObject var notch = Notch.shared
    private enum Phase: Hashable { case idle, compact(String), card(String) }

    private var phase: Phase {
        guard let a = notch.alert else { return .idle }
        return notch.showsCard ? .card(Self.key(a.id)) : .compact(Self.key(a.id))
    }

    /// One phase for all of WaniKani's alerts (open, reviews, lessons), so
    /// starting reviews in the open panel morphs it instead of rebuilding it.
    private static func key(_ id: String) -> String { id.hasPrefix("wk-") ? "wk" : id }

    private let cardWidth: CGFloat = 330
    /// The playing track's cover, when it has one.
    private var musicArt: NSImage? {
        if case let .image(art)? = notch.music?.icon { return art }
        return nil
    }
    /// The current alert's picture when it is WaniKani's tile.
    private var wkTile: NSImage? {
        if let a = notch.alert, a.id.hasPrefix("wk-"), Notch.grows(a.id), case let .image(tile) = a.icon { return tile }
        return nil
    }
    /// The picture that slides between the small notch and the card, and
    /// where it sits now (centre x in the shape, side); nil when hidden.
    /// Shared with music, the song's cover keeps the left spot and the other
    /// alert's icon sits right of the camera as usual.
    private func slide(flare: CGFloat) -> (art: NSImage, x: CGFloat, size: CGFloat)? {
        switch phase {
        case .card(let id) where Notch.grows(id):
            return (id == "music" ? musicArt : wkTile).map { ($0, flare + 20 + 11, 22) }
        case .compact where notch.ears:
            return musicArt.map { ($0, flare + 10 + 10, 20) }
        case .compact(let id) where Notch.grows(id):
            return (id == "music" ? musicArt : wkTile).map { ($0, flare + hudSide / 2, 20) }
        default: return nil
        }
    }

    /// The music or WaniKani card's height: small, or grown into the panel
    /// (the music player a fixed size, WaniKani as tall as its content).
    private var cardHeight: CGFloat {
        let n = notch.size
        // The volume row, while it shows, adds to whichever height.
        let hud: CGFloat = notch.hudOver != nil ? HUDRow.height : 0
        guard notch.expanded else { return n.height + 74 + hud }
        if notch.alert?.id.hasPrefix("wk-") == true, notch.panelHeight > 0 { return notch.panelHeight + hud }
        return n.height + 446 + hud
    }

    /// Solid black down past the hardware notch (its bottom edge would
    /// otherwise show against the colour), then the cover's colour.
    private func coverFade(height: CGFloat?) -> LinearGradient {
        let tint = notch.alert?.id.hasPrefix("wk-") == true ? WK.pink : notch.player?.artColor
        let art = tint.map { NSColor($0).blended(withFraction: 0.5, of: .black) ?? .black } ?? NSColor(white: 0.12, alpha: 1)
        let black = min(0.8, (notch.size.height + 10) / max(height ?? 120, 1))
        return LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: black),
                                      .init(color: Color(nsColor: art).opacity(0.82), location: 1)],
                              startPoint: .top, endPoint: .bottom)
    }
    private let musicCardWidth: CGFloat = 440
    /// One-line alerts and the HUD: both sides as wide, so the notch grows
    /// evenly around the camera.
    private let hudSide: CGFloat = 44
    /// The HUD, like Alcove's: icon and "Sound" on the left, a long bar on the right.
    private let hudWide: CGFloat = 84

    /// `NotchStyle` key: "island" puts every alert in a glass pill below the
    /// notch; "card" keeps the compact alert black and drops the card below
    /// in glass. Otherwise all of it is the black shape.
    private var inGlass: Bool {
        switch (Config.notchStyle, phase) {
        case ("island", .compact), ("island", .card), ("card", .card): true
        default: false
        }
    }

    var body: some View {
        let n = notch.size
        let glass = inGlass
        let (width, height, flare, bottom): (CGFloat, CGFloat?, CGFloat, CGFloat) = switch phase {
        case .idle: (n.width - 6, n.height - 2, 0, 8)
        case _ where glass: (n.width - 6, n.height - 2, 0, 8)
        case .compact where notch.alert?.label != nil || notch.ears: (n.width + 2 * hudWide + 12, n.height, 6, 12)
        case .compact: (n.width + 2 * hudSide + 12, n.height, 6, 10)
        // Fixed heights, so the notch springs between card and player
        // instead of jumping to the content's size.
        case .card where Notch.grows(notch.alert?.id): (musicCardWidth, cardHeight, 10, 24)
        case .card: (cardWidth + 20, notch.alert?.approve != nil || notch.alert?.id == "music" ? nil : n.height + 62, 10, 24)
        }
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                // With music the background is one fixed picture as tall as
                // the card or player: black down past the camera, then the
                // cover's colour (darkened, so white text reads) over frosted
                // glass. The growing notch shape only reveals more of it, so
                // opening is one movement (separate fades read as stages).
                Group {
                    if Notch.grows(notch.alert?.id) {
                        let full = cardHeight
                        ZStack(alignment: .top) {
                            GlassBackground(cornerRadius: 0)
                            Rectangle().fill(coverFade(height: full))
                        }
                        .frame(height: full)
                        .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        Color.black
                    }
                }
                .mask(NotchShape(flare: flare, bottom: bottom))
                Group {
                    switch phase {
                    case .idle: EmptyView()
                    case _ where glass: EmptyView()
                    case .compact(let id) where Notch.grows(id): EmptyView()
                    case .compact: notch.alert.map { compact($0) }
                    case .card: notch.alert.map { card($0) }
                    }
                }
                .id(phase)
                .transition(.blurIn)
                .padding(.horizontal, flare)
                if case .card = phase, !glass, let hud = notch.hudOver {
                    HUDRow(hud: hud)
                        .padding(.horizontal, flare + 20)
                        .padding(.bottom, 14)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                // The music's small notch (cover, levels) is one lasting view
                // that fades out while the card fades in: swapped out like the
                // rest, the bare notch showed for a frame between them.
                if !glass, let a = notch.alert, Notch.grows(a.id) {
                    compact(a)
                        .opacity(phase == .compact(Self.key(a.id)) ? 1 : 0)
                        .animation(.easeInOut(duration: 0.25), value: phase)
                        .padding(.horizontal, flare)
                        .allowsHitTesting(phase == .compact(Self.key(a.id)))
                }
                // The song's cover, drawn once so it slides between the small
                // notch (left of the camera) and the card's corner.
                if !glass, let spot = slide(flare: flare) {
                    Image(nsImage: spot.art).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: spot.size, height: spot.size)
                        .clipShape(RoundedRectangle(cornerRadius: spot.size * 0.24, style: .continuous))
                        .position(x: spot.x, y: n.height / 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: height, alignment: .top)
            .fixedSize(horizontal: false, vertical: height == nil)
            // Content stays inside the shape while it shrinks.
            .mask(NotchShape(flare: flare, bottom: bottom))
            if glass, let a = notch.alert { glassBox(a) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            notch.onDrop?(urls)
            return true
        } isTargeted: { on in
            if notch.hovering != on { notch.hovering = on }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { notch.frame = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // No overshoot: a bounce read as a second step.
        .animation(.smooth(duration: 0.34), value: phase)
        // Music leaving or joining while another alert shows (the shared
        // notch) changes no phase; animate that too instead of jumping.
        .animation(.smooth(duration: 0.34), value: notch.ears)
        // The WaniKani panel changing size (summary, a question, its info).
        .animation(.smooth(duration: 0.34), value: notch.panelHeight)
        .animation(.smooth(duration: 0.25), value: notch.hudOver == nil)
        .environment(\.ambient, notch.visible)
        .foregroundStyle(.white)
    }

    /// The alert on glass below the notch, the bar's material and corners.
    private func glassBox(_ a: NotchAlert) -> some View {
        let isCard = if case .card = phase { true } else { false }
        return Group {
            if isCard {
                card(a, top: 14).frame(width: cardWidth + 20)
            } else {
                compact(a, island: true)
            }
        }
        .id(phase)
        .transition(.blurIn)
        .background(GlassBackground(cornerRadius: isCard ? 24 : 15))
        .transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func compact(_ a: NotchAlert, island: Bool = false) -> some View {
        let row = Group { if island { islandRow(a) } else { compactRow(a) } }
        if a.tapOpens {
            Button { notch.run(a) } label: { row.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            row
        }
    }

    /// The compact alert as a pill: no gap for the camera.
    private func islandRow(_ a: NotchAlert) -> some View {
        HStack(spacing: 8) {
            if case .none = a.icon {} else { NotchIcon(icon: a.icon, small: true) }
            if let label = a.label { Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize() }
            NotchTrailing(trailing: a.trailing).frame(width: a.label != nil ? hudWide : hudSide)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private func compactRow(_ a: NotchAlert) -> some View {
        HStack(spacing: 0) {
            if notch.ears, let m = notch.music {
                // Music left of the camera, the other alert right of it.
                HStack(spacing: 8) {
                    if musicArt != nil { Color.clear.frame(width: 20, height: 20) } else { NotchIcon(icon: m.icon, small: true) }
                    NotchTrailing(trailing: m.trailing)
                }
                .frame(width: hudWide, alignment: .leading)
                .padding(.leading, 10)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    NotchTrailing(trailing: a.trailing)
                    NotchIcon(icon: a.icon, small: true)
                }
                .frame(width: hudWide, alignment: .trailing)
                .padding(.trailing, 10)
            } else if let label = a.label {
                HStack(spacing: 7) {
                    if case .none = a.icon {} else { NotchIcon(icon: a.icon, small: true) }
                    Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                }
                .frame(width: hudWide, alignment: .leading)
                .padding(.leading, 10)
                Spacer(minLength: 0)
                NotchTrailing(trailing: a.trailing).frame(width: hudWide, alignment: .trailing).padding(.trailing, 10)
            } else {
                Group {
                    // The song's cover is drawn once by NotchView (it slides).
                    if Notch.grows(a.id), (a.id == "music" ? musicArt : wkTile) != nil { Color.clear.frame(width: 20, height: 20) } else { NotchIcon(icon: a.icon, small: true) }
                }
                .frame(width: hudSide)
                Spacer(minLength: 0)
                NotchTrailing(trailing: a.trailing).frame(width: hudSide)
            }
        }
        .frame(height: notch.size.height)
    }

    @ViewBuilder
    private func card(_ a: NotchAlert, top: CGFloat? = nil) -> some View {
        if a.id.hasPrefix("wk-"), Notch.grows(a.id) {
            WaniKaniNotchCard(wk: WaniKani.shared, alert: a, band: notch.size)
        } else if a.id == "music", let player = notch.player {
            MusicCard(music: player, band: notch.size)
        } else {
            plainCard(a, top: top)
        }
    }

    @ViewBuilder
    private func plainCard(_ a: NotchAlert, top: CGFloat? = nil) -> some View {
        let content = VStack(alignment: .trailing, spacing: 10) {
            cardRow(a)
            if let approve = a.approve {
                ApprovalButtons(allow: { approve(true) }, deny: { approve(false) })
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, top ?? notch.size.height + 4)
        .padding(.bottom, 14)
        // Without Allow / Deny the whole card opens the thing.
        if a.approve == nil {
            Button { notch.run(a) } label: { content.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            content
        }
    }

    @ViewBuilder
    private func cardRow(_ a: NotchAlert) -> some View {
        let row = HStack(spacing: 12) {
            NotchIcon(icon: a.icon, small: false).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(a.subtitle).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        if a.approve == nil {
            HStack(spacing: 12) { row; NotchTrailing(trailing: a.trailing) }
        } else {
            // The text part opens the thing; Allow / Deny sit beside it, not inside.
            Button { notch.run(a) } label: { row.contentShape(Rectangle()) }.buttonStyle(.plain)
        }
    }
}

/// The music card. The band beside the camera holds the cover and levels
/// (left) and the time (right); below it the title, the lyric line or
/// artist, the controls and the seek bar. A click on the cover, title or list
/// button, or anywhere on the card, grows the notch into the whole player.
/// Volume or brightness while a card is open: a row the card grows at its
/// bottom, the icon and a level bar as wide as the card.
private struct HUDRow: View {
    let hud: NotchAlert
    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 10) {
            NotchIcon(icon: hud.icon, small: true).frame(width: 20)
            if case let .level(value) = hud.trailing {
                // Negative: muted, the bar keeps its length but goes grey.
                let v = value.isFinite ? min(1, max(0, abs(value))) : 0
                Capsule().fill(.white.opacity(0.2)).frame(height: 5)
                    .overlay {
                        Capsule().fill(.white.opacity(value < 0 ? 0.35 : 1))
                            .scaleEffect(x: v, anchor: .leading)
                    }
                    .animation(.smooth(duration: 0.18), value: value)
            }
        }
        .frame(height: Self.height)
    }
}

private struct MusicCard: View {
    @ObservedObject var music: Music
    @ObservedObject private var notch = Notch.shared
    let band: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // The cover itself is drawn by NotchView, sliding in from the
                // small notch; this keeps its place and its click.
                Color.clear.frame(width: 22, height: 22).tapAction(openDrawer)
                EqualizerBars(playing: music.isPlaying, live: music.live)
                Spacer(minLength: band.width + 16)
                // No length known (Tide sent none): no time rather than 0:00 / 0:00.
                if music.duration > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(MusicDrawer.clock(music.progress(at: context.date) * music.duration) + " / " + MusicDrawer.clock(music.duration))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(height: band.height)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.title).font(.system(size: 14, weight: .semibold))
                    Text(music.lyric.isEmpty ? music.artist : music.lyric).font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .id(music.lyric)
                        .transition(.opacity)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tapAction(openDrawer)
                // Controls in the middle, under the camera; like (Tide) and
                // the drawer on the right.
                Transport(music: music)
                HStack(spacing: 14) {
                    if music.isTide {
                        Button { music.toggleLike() } label: {
                            Image(systemName: music.liked ? "heart.fill" : "heart").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(music.liked ? Color.pink : .white.opacity(0.7)).frame(width: 22, height: 30).contentShape(Rectangle())
                        }
                        .buttonStyle(WidgetPress())
                    }
                    Button(action: openDrawer) {
                        Image(systemName: "list.bullet").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7)).frame(width: 22, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(WidgetPress())
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if music.duration > 0 { ProgressBar(music: music) }
            if notch.expanded {
                MusicDrawer(music: music, bare: true)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .offset(y: -10)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        // A click anywhere else on the card opens the whole player too.
        .background(Button(action: openDrawer) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain))
        .animation(.smooth(duration: 0.3), value: music.lyric)
    }

    private func openDrawer() {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { Notch.shared.expanded.toggle() }
    }

}

/// WaniKani in the notch (Dock bar): the tile (drawn by NotchView, it
/// slides) and today's count in the band beside the camera, then what is
/// waiting with a button to study; a click grows it into the WaniKani panel,
/// where reviews happen.
private struct WaniKaniNotchCard: View {
    @ObservedObject var wk: WaniKani
    @ObservedObject private var notch = Notch.shared
    let alert: NotchAlert
    let band: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 22, height: 22)
                Spacer(minLength: band.width + 16)
                NotchTrailing(trailing: alert.trailing)
            }
            .frame(height: band.height)
            if notch.expanded {
                WaniKaniDrawer(wk: wk, bare: true)
                    .transition(.opacity.combined(with: .offset(y: -10)))
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(alert.title).font(.system(size: 14, weight: .semibold))
                        Text(alert.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: grow) {
                        Text(wk.reviews > 0 ? "Reviews" : "Open").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(WK.pink))
                    }
                    .buttonStyle(WidgetPress())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .background(Button(action: grow) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain))
        // Its natural height, for the notch to fit it.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            if abs(notch.panelHeight - h) > 0.5 { notch.panelHeight = h }
        }
    }

    private func grow() {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { notch.expanded = true }
    }
}

/// Previous, play or pause, next: the music card's controls.
private struct Transport: View {
    @ObservedObject var music: Music

    var body: some View {
        HStack(spacing: 16) {
            button("backward.fill", 15) { music.previous() }
            button(music.isPlaying ? "pause.fill" : "play.fill", 22) { music.playPause() }
                .contentTransition(.symbolEffect(.replace))
            button("forward.fill", 15) { music.next() }
        }
        .foregroundStyle(.white)
    }

    private func button(_ name: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size, weight: .semibold)).frame(width: 24, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(WidgetPress())
    }
}

struct NotchIcon: View {
    let icon: NotchAlert.Icon
    let small: Bool

    var body: some View {
        switch icon {
        case let .symbol(name, color, motion):
            SymbolIcon(name: name, color: color, motion: motion, size: small ? 13 : 19)
        case let .claude(state):
            ClaudeMark(state: state, badge: false).scaleEffect(small ? 0.55 : 0.85).frame(width: small ? 20 : 30, height: small ? 20 : 30)
        case .none:
            EmptyView()
        case let .airpods(name, pid):
            if let movie = AirPodsMovie.url(for: pid) {
                AirPodsMovie(url: movie).frame(width: small ? 26 : 34, height: small ? 26 : 34)
            } else {
                AirPodsSpin(name: name, size: small ? 14 : 20)
            }
        case let .image(image):
            ImageIcon(image: image, small: small)
        }
    }
}

struct NotchTrailing: View {
    let trailing: NotchAlert.Trailing

    var body: some View {
        switch trailing {
        case let .text(s, color):
            // Counts (WaniKani's done/total) roll to the next number.
            Text(s).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                .contentTransition(.numericText()).animation(.smooth(duration: 0.3), value: s)
        case let .symbol(name, color): Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
        case let .bars(live): EqualizerBars(playing: true, live: live)
        case let .level(value):
            // Negative: muted, the bar keeps its length but goes grey.
            let v = value.isFinite ? min(1, max(0, abs(value))) : 0
            Capsule().fill(.white.opacity(0.2)).frame(width: 68, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(.white.opacity(value < 0 ? 0.35 : 1)).frame(width: 68 * v, height: 5)
                }
                .animation(.smooth(duration: 0.18), value: value)
        case let .ring(value, color):
            ZStack {
                Circle().stroke(color.opacity(0.22), lineWidth: 3)
                Circle().trim(from: 0, to: min(1, max(0, value))).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            .animation(.smooth(duration: 0.4), value: value)
        case let .battery(percent, color, charging):
            ChargingBattery(percent: percent, color: color, charging: charging)
        case .done:
            DoneCheck()
        case .none: EmptyView()
        }
    }
}

/// AppKit's Liquid Glass behind a view. Samples what is behind the window
/// (SwiftUI's glassEffect only sees this transparent panel and draws grey).
struct GlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat
    /// Fades the glass in and out with AppKit: SwiftUI's opacity doesn't
    /// reach it, so it would pop in at full strength for a frame.
    var shown = true
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.style = .clear
        view.alphaValue = shown ? 1 : 0
        return view
    }
    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
        let alpha: CGFloat = shown ? 1 : 0
        guard view.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.3
            view.animator().alphaValue = alpha
        }
    }
}

/// The AirPods turning over like Alcove's: the pair, the right bud, the
/// left bud, the case, each flipping in around its vertical axis. Only runs
/// while the alert is up (a few seconds).
struct AirPodsSpin: View {
    let name: String
    let size: CGFloat

    private var frames: [String] {
        if name.contains("Max") { return ["airpodsmax"] }
        if name.contains("Pro") { return ["airpodspro", "airpodpro.right", "airpodpro.left", "airpodspro.chargingcase.wireless.fill"] }
        return ["airpods", "airpod.right", "airpod.left", "airpods.chargingcase.fill"]
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.8)) { context in
            let i = Int(context.date.timeIntervalSinceReferenceDate / 0.8) % frames.count
            Image(systemName: frames[i])
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .id(i)
                .transition(.asymmetric(insertion: .modifier(active: Flip(angle: -90), identity: Flip(angle: 0)),
                                        removal: .modifier(active: Flip(angle: 90), identity: Flip(angle: 0))))
                .animation(.easeInOut(duration: 0.32), value: i)
        }
        .frame(width: size * 1.6, height: size * 1.4)
    }
}

private struct Flip: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .opacity(abs(angle) > 45 ? 0 : 1)
    }
}

/// Apple's own turning-AirPods animation, the one macOS shows when AirPods
/// connect: a short transparent movie per model in BluetoothUIService
/// (named by Bluetooth product ID), looped and muted. Nil when there's none
/// for this model; then the symbol version (AirPodsSpin) shows.
struct AirPodsMovie: NSViewRepresentable {
    let url: URL

    static func url(for pid: Int?) -> URL? {
        guard let pid else { return nil }
        let folder = URL(fileURLWithPath: "/System/Library/CoreServices/BluetoothUIService.app/Contents/Resources/Banner-PID-\(pid)-mov")
        let exact = folder.appendingPathComponent("Banner-PID-\(pid)-Loop.mov")
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        let any = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix("Loop.mov") }.sorted { $0.path < $1.path }
        return any?.first
    }

    final class MovieView: NSView {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.layer = layer
            player.isMuted = true
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    func makeNSView(context: Context) -> MovieView {
        let view = MovieView(frame: .zero)
        view.looper = AVPlayerLooper(player: view.player, templateItem: AVPlayerItem(url: url))
        view.player.play()
        return view
    }

    func updateNSView(_ view: MovieView, context: Context) {}

    static func dismantleNSView(_ view: MovieView, coordinator: ()) {
        view.player.pause()
        view.looper = nil
    }
}

/// The percent and a battery drawn like the system's. It fills up from empty
/// when it appears; while charging a bolt pops in and a soft shine sweeps
/// along the fill. Only lives while the alert is up (a few seconds).
struct ChargingBattery: View {
    let percent: Int
    let color: Color
    let charging: Bool
    @State private var filled = false
    @State private var shine = false

    private var level: CGFloat { CGFloat(min(100, max(0, percent))) / 100 }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(percent)%").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(color.opacity(0.3))
                    .frame(width: 24, height: 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(color)
                            .frame(width: max(4, 24 * (filled ? level : 0)), height: 12)
                            .overlay {
                                if charging {
                                    LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: 10)
                                        .offset(x: shine ? 16 : -16)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    }
                    .overlay {
                        if charging && filled {
                            Image(systemName: "bolt.fill").font(.system(size: 8, weight: .heavy)).foregroundStyle(.black.opacity(0.75))
                                .transition(.scale(scale: 0.2).combined(with: .opacity))
                        }
                    }
                RoundedRectangle(cornerRadius: 1).fill(color.opacity(0.5)).frame(width: 2, height: 4.5)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.2).delay(0.15)) { filled = true }
            if charging {
                withAnimation(.easeInOut(duration: 1.1).delay(0.6).repeatForever(autoreverses: false)) { shine = true }
            }
        }
    }
}

/// Claude finished: a green ring draws itself round, then the tick inside,
/// with a small pop at the end. Plays once when the alert appears.
struct DoneCheck: View {
    @State private var ring: CGFloat = 0
    @State private var tick: CGFloat = 0
    @State private var pop = false

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: ring)
                .stroke(Notch.green, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Path { p in
                p.move(to: CGPoint(x: 4.6, y: 8.4))
                p.addLine(to: CGPoint(x: 7.2, y: 11))
                p.addLine(to: CGPoint(x: 12, y: 5.6))
            }
            .trim(from: 0, to: tick)
            .stroke(Notch.green, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 16, height: 16)
        .scaleEffect(pop ? 1 : 0.85)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.25).delay(0.55)) { tick = 1 }
            withAnimation(.spring(duration: 0.35, bounce: 0.5).delay(0.75)) { pop = true }
        }
    }
}

/// A symbol icon that moves (SF Symbols effects, which macOS runs itself):
/// bounces once as it appears, keeps dropping (downloads, the file tray),
/// pulses, wiggles (heat), or animates between symbols as they change (the
/// HUD's speaker waves and sun).
/// A picture icon (the WaniKani tile, a kept file) pops in as it appears,
/// like the symbols' bounce.
struct ImageIcon: View {
    let image: NSImage
    let small: Bool
    @State private var shown = false

    var body: some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: small ? 20 : 30, height: small ? 20 : 30)
            .clipShape(RoundedRectangle(cornerRadius: small ? 5 : 7, style: .continuous))
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.snappy(duration: 0.3)) { shown = true }
                }
            }
    }
}

struct SymbolIcon: View {
    let name: String
    let color: Color
    let motion: NotchAlert.Motion
    let size: CGFloat
    @State private var shown = false

    var body: some View {
        let image = Image(systemName: name).font(.system(size: size, weight: .semibold)).foregroundStyle(color)
        Group {
            switch motion {
            case .bounce: image.symbolEffect(.bounce, value: shown)
            case .dropping: image.symbolEffect(.bounce.down, options: .repeat(.periodic(delay: 0.5)), isActive: shown)
            case .pulse: image.symbolEffect(.pulse, options: .repeating, isActive: shown)
            case .wiggle: image.symbolEffect(.wiggle, options: .repeat(.periodic(delay: 0.6)), isActive: shown)
            case .swap: image.contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce, value: name)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { shown = true } }
    }
}
