// The camera notch on the built-in display: what is happening right now.
// At rest it draws nothing (the shape sits just inside the hardware notch).
// An alert widens the notch sideways, one line tall: an icon left of the
// camera, a short value right of it. An alert that needs you drops it into a
// card by itself (click runs its action); hovering or a swipe down opens the
// card, a swipe up dismisses. Alerts: Claude (needs you, done), headphones,
// power, heat, downloads (Downloads.swift), the volume and brightness HUD
// (MediaKeys.swift) and the file tray while dragging. Music, shelf and the
// rest stay in the wings. In full screen only the HUD shows. The shape
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
    /// tile, whose drawer grows out of the notch like the Dynamic Island).
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

    @Published private(set) var alert: NotchAlert?
    /// The pointer is over the shape.
    @Published var hovering = false {
        didSet {
            if !hovering { clicked = false }
            if !hovering, let id = finishWhenLeft { finishWhenLeft = nil; clear(id) }
        }
    }
    /// The card was clicked: it folds away and hovering doesn't reopen it
    /// until the pointer has left (what it opened may sit right below).
    @Published private var clicked = false

    func run(_ a: NotchAlert) {
        cardShown = false
        clicked = true
        a.action?()
    }
    @Published private(set) var cardShown = false
    /// The WaniKani drawer is open: it grew out of the notch, so the notch's
    /// WaniKani tile steps back meanwhile. Set by the drawer.
    @Published var yielded = false
    /// The notch window can be seen (looping animations stop otherwise).
    @Published var visible = true
    /// Size of the hardware notch.
    @Published var size = CGSize(width: 185, height: 32)
    /// The shape's frame in the window (top-left origin).
    var frame = CGRect.zero

    static let windowSize = CGSize(width: 480, height: 280)

    /// Swipe down on the notch: the alert's card.
    func swipeDown() {
        if alert != nil, !cardShown { cardShown = true }
    }

    /// Swipe up: closes the card, else sends the alert away.
    func swipeUp() {
        if cardShown { cardShown = false } else if let a = alert, a.id != "drop" { forceClear(a.id) }
    }

    /// Hover or a swipe opens the alert's card; an alert that needs you opens
    /// it by itself. During a file drag the drop card is open from the start,
    /// reaching well below the screen edge (dragging up to the very top opens
    /// Mission Control).
    var showsCard: Bool { alert != nil && alert?.id != "hud" && alert?.tapOpens != true && (cardShown || (hovering && !clicked) || (dragging && alert?.id == "drop")) }
    /// How wide the black shape is drawn now (same sizes as NotchView), so
    /// buddies can keep clear of it.
    var shapeWidth: CGFloat {
        guard let a = alert else { return size.width }
        if showsCard { return 350 }
        return size.width + 2 * (a.label != nil ? 84 : 44) + 12
    }

    /// Settings switches (on unless turned off).
    static var alertsOn: Bool { UserDefaults.standard.object(forKey: "notchAlerts") as? Bool ?? true }
    static var hudOn: Bool { UserDefaults.standard.object(forKey: "notchHUD") as? Bool ?? true }

    /// A full-screen app is in front: only the volume and brightness HUD shows.
    @Published var fullScreen = false {
        didSet {
            guard fullScreen != oldValue, fullScreen else { return }
            for id in [alert?.id].compactMap({ $0 }) + queue.map(\.id) where !Self.fullScreenSafe.contains(id) { forceClear(id) }
        }
    }

    /// The screen is locked: the notch sits on the lock screen and shows
    /// only the HUD and charging, nothing private (the player is its own
    /// lock screen widget).
    @Published var locked = false {
        didSet {
            guard locked != oldValue else { return }
            if locked {
                for id in [alert?.id].compactMap({ $0 }) + queue.map(\.id) where !Self.lockSafe.contains(id) { forceClear(id) }
            }
            lockChanged?(locked)
        }
    }
    static let lockSafe: Set<String> = ["hud", "power"]
    /// Shown over a full-screen app too (WaniKani lessons run in a full-screen browser).
    static let fullScreenSafe: Set<String> = ["hud", "wk-lessons", "wk-reviews"]
    var lockChanged: ((Bool) -> Void)?

    private var queue: [NotchAlert] = []
    private var timers: [Timer] = []
    private var finishWhenLeft: String?

    /// Shows an alert now, or after the current one. Timed alerts wait for
    /// each other; one that stays (needs you) steps aside for them and comes
    /// back compact afterwards.
    func post(_ a: NotchAlert) {
        if locked && !Self.lockSafe.contains(a.id) { return }
        if a.id != "hud" && ((fullScreen && !Self.fullScreenSafe.contains(a.id)) || !Self.alertsOn) { return }
        var a = a
        a.posted = Date()
        queue.removeAll { $0.id == a.id }
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
        guard alert?.id == id else { return }
        if hovering, alert?.duration ?? 0 > 0 { finishWhenLeft = id; return }
        timers.forEach { $0.invalidate() }
        alert = nil
        cardShown = false
        // Moments that waited too long are old news.
        queue.removeAll { $0.duration > 0 && Date().timeIntervalSince($0.posted) > 8 }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
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

/// Content fades in as the shape settles and leaves quicker. No blur: a blur
/// flattens the looping layer animations inside (bars, Claude's mark).
private struct BlurIn: ViewModifier {
    let shown: Bool
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0)
    }
}

private extension AnyTransition {
    static var blurIn: AnyTransition {
        .asymmetric(insertion: .modifier(active: BlurIn(shown: false), identity: BlurIn(shown: true))
                        .animation(.easeOut(duration: 0.2).delay(0.14)),
                    removal: .modifier(active: BlurIn(shown: false), identity: BlurIn(shown: true))
                        .animation(.easeIn(duration: 0.08)))
    }
}

struct NotchView: View {
    @ObservedObject var notch = Notch.shared
    private enum Phase: Hashable { case idle, compact(String), card(String) }

    private var phase: Phase {
        guard let a = notch.alert, !(notch.yielded && a.id.hasPrefix("wk-")) else { return .idle }
        return notch.showsCard ? .card(a.id) : .compact(a.id)
    }

    private let cardWidth: CGFloat = 330
    /// One-line alerts and the HUD: both sides as wide, so the notch grows
    /// evenly around the camera.
    private let hudSide: CGFloat = 44
    /// The HUD, like Alcove's: icon and "Sound" on the left, a long bar on the right.
    private let hudWide: CGFloat = 84

    var body: some View {
        let n = notch.size
        let (width, height, flare, bottom): (CGFloat, CGFloat?, CGFloat, CGFloat) = switch phase {
        case .idle: (n.width - 6, n.height - 2, 0, 8)
        case .compact where notch.alert?.label != nil: (n.width + 2 * hudWide + 12, n.height, 6, 12)
        case .compact: (n.width + 2 * hudSide + 12, n.height, 6, 10)
        case .card: (cardWidth + 20, notch.alert?.approve != nil ? nil : n.height + 62, 10, 24)
        }
        ZStack(alignment: .top) {
            NotchShape(flare: flare, bottom: bottom).fill(.black)
            Group {
                switch phase {
                case .idle: EmptyView()
                case .compact: notch.alert.map { compact($0) }
                case .card: notch.alert.map { card($0) }
                }
            }
            .id(phase)
            .transition(.blurIn)
            .padding(.horizontal, flare)
        }
        .frame(width: width, height: height)
        .fixedSize(horizontal: false, vertical: height == nil)
                .dropDestination(for: URL.self) { urls, _ in
            notch.onDrop?(urls)
            return true
        } isTargeted: { on in
            if notch.hovering != on { notch.hovering = on }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { notch.frame = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.36, bounce: 0.1), value: phase)
        .environment(\.ambient, notch.visible)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func compact(_ a: NotchAlert) -> some View {
        if a.tapOpens {
            Button { notch.run(a) } label: { compactRow(a).contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            compactRow(a)
        }
    }

    private func compactRow(_ a: NotchAlert) -> some View {
        HStack(spacing: 0) {
            if let label = a.label {
                HStack(spacing: 7) {
                    if case .none = a.icon {} else { NotchIcon(icon: a.icon, small: true) }
                    Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                }
                .frame(width: hudWide, alignment: .leading)
                .padding(.leading, 10)
                Spacer(minLength: 0)
                NotchTrailing(trailing: a.trailing).frame(width: hudWide, alignment: .trailing).padding(.trailing, 10)
            } else {
                NotchIcon(icon: a.icon, small: true).frame(width: hudSide)
                Spacer(minLength: 0)
                NotchTrailing(trailing: a.trailing).frame(width: hudSide)
            }
        }
        .frame(height: notch.size.height)
    }

    @ViewBuilder
    private func card(_ a: NotchAlert) -> some View {
        let content = VStack(alignment: .trailing, spacing: 10) {
            cardRow(a)
            if let approve = a.approve {
                ApprovalButtons(allow: { approve(true) }, deny: { approve(false) })
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, notch.size.height + 4)
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

/// Cover, title, artist, progress with times, and back / play / next.
/// The lock screen widget's player.
struct PlayerRow: View {
    @ObservedObject var music: Music
    let cover: CGFloat

    /// Small (the notch): controls sit beside the song instead of below it.
    private var small: Bool { cover < 50 }

    var body: some View { lockBody }

    private var lockBody: some View {
        VStack(spacing: small ? 8 : 12) {
            HStack(spacing: small ? 10 : 12) {
                Group {
                    if let art = music.art { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                    else { Color.white.opacity(0.08).overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))) }
                }
                .frame(width: cover, height: cover)
                .clipShape(RoundedRectangle(cornerRadius: cover * 0.23, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(music.title).font(.system(size: small ? 12.5 : 14, weight: .semibold)).lineLimit(1)
                    Text(music.artist).font(.system(size: small ? 11 : 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if small { controls } else if music.isPlaying { EqualizerBars(playing: true, live: music.live).padding(.trailing, 6) }
            }
            if music.duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let p = min(1, max(0, music.scrub ?? music.progress(at: context.date)))
                    HStack(spacing: 8) {
                        Text(Self.time(p * music.duration))
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.2))
                                .overlay(alignment: .leading) { Capsule().fill(.white.opacity(0.9)).frame(width: g.size.width * p) }
                        }
                        .frame(height: small ? 3 : 4)
                        Text("-" + Self.time((1 - p) * music.duration))
                    }
                    .font(.system(size: small ? 9.5 : 10.5, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                }
            }
            if !small { controls }
        }
    }

    private var controls: some View {
        HStack(spacing: small ? 14 : 34) {
            Button { music.previous() } label: { Image(systemName: "backward.fill") }
            Button { music.playPause() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").frame(width: small ? 18 : 24) }
                .font(.system(size: small ? 17 : 22))
            Button { music.next() } label: { Image(systemName: "forward.fill") }
        }
        .font(.system(size: small ? 13 : 17))
        .buttonStyle(NotchPress())
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Dips while pressed, like the wings' widgets.
struct NotchPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
    }
}

/// The player on the lock screen, low and centred above the login, like
/// Alcove's: a Liquid Glass card.
struct LockWidget: View {
    @ObservedObject var music: Music
    @ObservedObject var notch = Notch.shared

    var body: some View {
        ZStack {
            if notch.locked && !music.title.isEmpty && UserDefaults.standard.object(forKey: "lockCard") as? Bool ?? true {
                PlayerRow(music: music, cover: 56)
                    .padding(18)
                    .frame(width: 340)
                    // Liquid Glass, so it follows the Clear / Tinted setting like the system's own.
                    .background(GlassBackground(cornerRadius: 26))
                    // The bright rim Liquid Glass has on the system's own cards.
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.12), .white.opacity(0.3)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .foregroundStyle(.white)
                    .transition(.blurIn)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.36, bounce: 0.1), value: notch.locked)
    }
}

/// AppKit's Liquid Glass behind a view. Samples what is behind the window
/// (SwiftUI's glassEffect only sees this transparent panel and draws grey).
struct GlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.style = .clear
        return view
    }
    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
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
