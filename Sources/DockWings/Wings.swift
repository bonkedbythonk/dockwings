// The two wings beside the Dock. Every widget has a home side and a
// priority; WingPlan measures all of them and fills both sides from the
// screen corners inward, most important first. A widget that doesn't fit on
// its home side moves to the other side when there is room there, unless it
// is quiet (priority 3 or less: it stays home on a later page). Widgets rise
// in and out, slide when neighbours change, bump when their content changes,
// and magnify with the Dock's own setting. Widgets that fit nowhere go onto
// extra pages per side; a two-finger swipe up or down over a wing flips pages.
import SwiftUI

enum Side { case left, right }

/// One widget: whether it has something to show, its home side, how much it
/// matters when space runs out (higher stays longer), and a value that
/// changes whenever its content does (to trigger the bump).
struct WingItem {
    let id: String
    let home: Side
    let show: Bool
    let priority: Int
    let bump: AnyHashable
    let view: AnyView
    /// What to measure for layout: the widget at its widest, so hovering
    /// never reshuffles the wings.
    let widest: AnyView
    /// For a widget that can grow: builds it with the spare width on its side.
    var flex: ((CGFloat) -> AnyView)?

    init<V: View, W: View>(_ id: String, _ home: Side, show: Bool, priority: Int, bump: AnyHashable = 0,
                           @ViewBuilder _ view: () -> V, @ViewBuilder widest: () -> W) {
        self.id = id
        self.home = home
        self.show = show
        self.priority = priority
        self.bump = bump
        self.view = AnyView(view())
        self.widest = AnyView(widest())
    }

    init<V: View>(_ id: String, _ home: Side, show: Bool, priority: Int, bump: AnyHashable = 0, @ViewBuilder _ view: () -> V) {
        self.init(id, home, show: show, priority: priority, bump: bump, view, widest: view)
    }
}

/// Every model a widget reads; passed to both wings.
struct WingModels {
    let music: Music
    let weather: Weather
    let claude: ClaudeStatus
    let todos: Todos
    let jobs: Jobs
    let latest: Latest
    let clipboard: Clipboard
    let batteries: Batteries
    let wanikani: WaniKani
    let shelf: Shelf
}

/// Widths and space shared by both wings, and the assignment of widgets to
/// sides.
@MainActor
final class WingPlan: ObservableObject {
    @Published private(set) var widths: [String: CGFloat] = [:]
    @Published private(set) var space: [Side: CGFloat] = [.left: 0, .right: 0]
    /// Which side each widget is on right now (drawers anchor with this).
    private(set) var placedSide: [String: Side] = [:]
    /// The page each side shows; extra widgets live on later pages.
    @Published var page: [Side: Int] = [.left: 0, .right: 0]
    private(set) var pageCount: [Side: Int] = [.left: 1, .right: 1]
    /// Widgets on a side's later pages (kept apart: both sides recompute
    /// `placedSide` for the main page).
    private var extras: [Side: Set<String>] = [:]

    /// Side a widget is shown on, main page or later.
    func side(of id: String) -> Side? {
        placedSide[id] ?? extras.first { $0.value.contains(id) }?.key
    }

    /// Next or previous page on a side, wrapping around.
    func flip(_ side: Side, by step: Int) {
        let count = pageCount[side] ?? 1
        guard count > 1 else { return }
        // A drawer belongs to a widget that's about to leave; close it.
        if let open = Drawers.shared.open, self.side(of: open) == side { Drawers.shared.open = nil }
        withAnimation(.spring(duration: 0.5, bounce: 0.15)) {
            page[side] = ((page[side] ?? 0) + step + count) % count
        }
    }

    /// The pages of one side: the main page (from `assign`), then the home
    /// widgets that didn't fit anywhere, packed into as many pages as needed.
    func pages(_ items: [WingItem], for side: Side) -> [[WingItem]] {
        let first = assign(items, to: side)
        let room = room(side)
        var pages: [[WingItem]] = [first]
        // First fit: each leftover joins the earliest later page with room,
        // so a small widget fills a gap instead of waiting for a new page.
        var used: [CGFloat] = []
        for item in items.sorted(by: { $0.priority > $1.priority })
        where item.home == side && placedSide[item.id] == nil {
            let width = widths[item.id] ?? 140
            if let i = used.indices.first(where: { used[$0] + Self.minSpacing + width <= room }) {
                pages[i + 1].append(item)
                used[i] += Self.minSpacing + width
            } else {
                pages.append([item])
                used.append(width)
            }
        }
        // Later pages keep the same corner-to-Dock order as the main page.
        let order = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        for i in pages.indices.dropFirst() { pages[i].sort { order[$0.id]! < order[$1.id]! } }
        extras[side] = Set(pages.dropFirst().flatMap { $0.map(\.id) })
        if pageCount[side] != pages.count {
            let count = pages.count
            DispatchQueue.main.async {
                self.pageCount[side] = count
                if (self.page[side] ?? 0) >= count { self.page[side] = 0 }
            }
        }
        return pages
    }

    static let spacing: CGFloat = 26
    static let margin: CGFloat = 20
    /// When widgets need the room, the Dock-end margin gives way down to
    /// this first, then the spacing between widgets down to `minSpacing`.
    static let minDockMargin: CGFloat = 0
    static let minSpacing: CGFloat = 12

    /// Widest a side's widgets can be, with the Dock-end margin at its smallest.
    private func room(_ side: Side) -> CGFloat {
        (space[side] ?? 0) - Self.margin - Self.minDockMargin
    }

    /// Dock-end margin and widget spacing for a side: full while widgets fit
    /// with them, smaller when a widget would otherwise move to another page.
    func fit(_ items: [WingItem], on side: Side) -> (dockMargin: CGFloat, spacing: CGFloat) {
        let widgets = items.reduce(0) { $0 + (widths[$1.id] ?? 140) }
        let gaps = CGFloat(max(items.count - 1, 0))
        let free = (space[side] ?? 0) - Self.margin - widgets
        let dockMargin = free - gaps * Self.spacing
        if dockMargin >= Self.minDockMargin || gaps == 0 {
            return (min(Self.margin, max(Self.minDockMargin, dockMargin)), Self.spacing)
        }
        return (Self.minDockMargin, max(Self.minSpacing, (free - Self.minDockMargin) / gaps))
    }

    func setSpace(left: CGFloat, right: CGFloat) {
        if space[.left] != left || space[.right] != right { space = [.left: left, .right: right] }
    }

    func measured(_ id: String, _ width: CGFloat) {
        if abs((widths[id] ?? 0) - width) > 0.5 { widths[id] = width }
    }

    /// Room left over on a side after its widgets, for one that can grow.
    func spare(_ items: [WingItem], on side: Side) -> CGFloat {
        let used = items.reduce(0) { $0 + (widths[$1.id] ?? 140) } + CGFloat(max(items.count - 1, 0)) * Self.spacing
        return max(0, (space[side] ?? 0) - 2 * Self.margin - used - 8)
    }

    /// Widgets for one side, in display order (screen corner first).
    func assign(_ items: [WingItem], to side: Side) -> [WingItem] {
        var used: [Side: CGFloat] = [.left: 0, .right: 0]
        var placed: [String: Side] = [:]
        let ranked = items.sorted { $0.priority > $1.priority }
        func tryPlace(_ item: WingItem, on candidate: Side) {
            let extra = (widths[item.id] ?? 140) + (used[candidate]! > 0 ? Self.minSpacing : 0)
            if used[candidate]! + extra <= room(candidate) {
                used[candidate]! += extra
                placed[item.id] = candidate
            }
        }
        // Everyone gets their home side first; leftovers try the other side,
        // except quiet ones (priority 3 or less), which stay home on a later
        // page (weather keeps a paused player company).
        for item in ranked { tryPlace(item, on: item.home) }
        for item in ranked where placed[item.id] == nil && item.priority > 3 { tryPlace(item, on: item.home == .left ? .right : .left) }
        placedSide = placed
        // Home widgets keep their order; guests sit at the Dock end.
        let home = items.filter { $0.home == side && placed[$0.id] == side }
        let guests = items.filter { $0.home != side && placed[$0.id] == side }
        return side == .left ? home + guests : guests + home
    }
}

struct WingSide: View {
    let side: Side
    let models: WingModels
    @ObservedObject var plan: WingPlan
    @ObservedObject var pointer: WingPointer
    @ObservedObject private var presence = Presence.shared
    @ObservedObject private var inkState = Ink.shared
    @ObservedObject private var health = Health.shared
    @ObservedObject private var inUse = InUse.shared
    @ObservedObject private var phone = PhoneApps.shared
    @ObservedObject private var music: Music
    @ObservedObject private var weather: Weather
    @ObservedObject private var claude: ClaudeStatus
    @ObservedObject private var todos: Todos
    @ObservedObject private var jobs: Jobs
    @ObservedObject private var latest: Latest
    @ObservedObject private var clipboard: Clipboard
    @ObservedObject private var batteries: Batteries
    @ObservedObject private var wanikani: WaniKani
    @ObservedObject private var shelf: Shelf
    /// Bumped when a widget is switched on or off in Settings.
    @State private var prefsVersion = 0

    init(side: Side, models: WingModels, plan: WingPlan, pointer: WingPointer) {
        self.side = side
        self.models = models
        self.plan = plan
        self.pointer = pointer
        music = models.music; weather = models.weather; claude = models.claude; todos = models.todos
        jobs = models.jobs; latest = models.latest; clipboard = models.clipboard; batteries = models.batteries
        wanikani = models.wanikani
        shelf = models.shelf
    }

    private var items: [WingItem] {
        let focus = claude.focus
        // Active things (a Claude chat working or waiting, music playing, a
        // fresh file or connection, a Mac that needs charging) keep the best
        // spots. WaniKani ranks above everything passive, and right after a
        // natural pause it moves up to the first page for a moment, still
        // below anything active.
        let claudeActive = focus.map { $0.session.state != .done } ?? false
        let list = [
            // Left wing, corner to Dock: passive info at the corner, music by the Dock.
            WingItem("mac", .left, show: health.batteryTime != nil || health.celsius != nil, priority: health.needsCharge ? 7 : 0,
                     bump: health.needsCharge) { MacView(health: health) },
            WingItem("weather", .left, show: weather.temperature != nil, priority: 1, bump: weather.symbol) { WeatherView(weather: weather) },
            // While a file is dragged the shelf outranks everything, and while
            // it holds files it stays in view.
            WingItem("shelf", .left, show: shelf.visible, priority: shelf.dragging ? 9 : 7,
                     bump: shelf.items.count) { ShelfView(shelf: shelf) },
            WingItem("wanikani", .left, show: wanikani.connected,
                     priority: wanikani.reviewing ? 8 : wanikani.celebrating ? 7 : !wanikani.hasWork ? 1 : wanikani.nudging ? 5 : 4,
                     bump: "\(wanikani.doneToday)\(wanikani.lessonsToday)\(wanikani.nudging)\(wanikani.celebrating)\(wanikani.reviewing)") { WaniKaniView(wk: wanikani) },
            WingItem("health", .left, show: health.issue != nil, priority: health.issue?.critical == true ? 8 : 5,
                     bump: health.issue?.key) { HealthView(health: health) },
            {
                var item = WingItem("music", .left, show: !music.title.isEmpty && !music.idle, priority: music.settled ? 3 : 6, bump: music.trackKey) {
                    MusicView(music: music, height: pointer.boxHeight)
                }
                item.flex = { [music, pointer] extra in AnyView(MusicView(music: music, height: pointer.boxHeight, extra: extra)) }
                return item
            }(),
            WingItem("claude", .right, show: focus != nil, priority: claudeActive ? 7 : 2, bump: "\(focus?.id ?? "")\(String(describing: focus?.session.state))") { ClaudeView(claude: claude) },
            WingItem("job", .right, show: jobs.job != nil, priority: 6, bump: jobs.job?.date) { JobView(jobs: jobs) },
            WingItem("latest", .right, show: latest.item != nil, priority: 6, bump: latest.item?.url) { LatestView(latest: latest) },
            WingItem("todo", .right, show: !todos.upcoming.isEmpty || todos.denied, priority: 3, bump: todos.upcoming.count) { TodoView(todos: todos, height: pointer.boxHeight) },
            WingItem("clipboard", .right, show: clipboard.recent && !clipboard.entries.isEmpty, priority: 2, bump: clipboard.entries.first?.id) { ClipboardView(clipboard: clipboard) },
            WingItem("phone", .right, show: phone.status != nil, priority: 5, bump: phone.status?.reason) { PhoneAppsView(phone: phone) },
            WingItem("inuse", .right, show: inUse.active, priority: 6, bump: inUse.state) { InUseView(inUse: inUse) },
            WingItem("batteries", .right, show: !batteries.items.isEmpty, priority: batteries.isNews ? 7 : 2, bump: batteries.news) { BatteriesView(batteries: batteries) },
        ].filter { $0.show && !UserDefaults.standard.bool(forKey: WidgetPrefs.key($0.id)) }
        // During a review WaniKani is only its tile, at the Dock end of its wing.
        return wanikani.reviewing ? list.filter { $0.id != "wanikani" } + list.filter { $0.id == "wanikani" } : list
    }

    /// Mid-review the WaniKani tile stays on every page of its side.
    private func withReviewTile(_ page: [WingItem], _ pages: [[WingItem]]) -> [WingItem] {
        guard wanikani.reviewing, !page.contains(where: { $0.id == "wanikani" }),
              let tile = pages.joined().first(where: { $0.id == "wanikani" }) else { return page }
        return page + [tile]
    }

    var body: some View {
        let _ = prefsVersion
        let shown = items
        let hidden = !presence.shown || (side == .right && presence.screenshotThumbnail)
        let pages = plan.pages(shown, for: side)
        let pageIndex = min(plan.page[side] ?? 0, pages.count - 1)
        let visible = hidden ? [] : withReviewTile(pages[pageIndex], pages)
        let spare = plan.spare(visible, on: side)
        let fit = plan.fit(visible, on: side)
        ZStack(alignment: Alignment(horizontal: side == .left ? .leading : .trailing, vertical: .bottom)) {
            HStack(spacing: fit.spacing) {
                ForEach(visible, id: \.id) { item in
                    let dark = inkState.dark[item.id] ?? inkState.dark[Ink.key(side)] ?? false
                    (item.flex?(spare) ?? item.view)
                        .modifier(Legibility(dark: dark, mixed: inkState.mixed.contains(item.id)))
                        .environment(\.inkDark, dark)
                        .animation(.smooth(duration: 0.6), value: dark)
                        .modifier(Bump(trigger: item.bump))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("wing")) } action: { pointer.frames[item.id] = $0 }
                        .scaleEffect(pointer.scale(at: pointer.frames[item.id]), anchor: .bottom)
                        .transition(.rise)
                }
            }
            .frame(height: pointer.boxHeight)
            .padding(side == .left ? .leading : .trailing, WingPlan.margin)
            .padding(side == .left ? .trailing : .leading, fit.dockMargin)
            // Page dots at the screen-corner end when a side has more pages.
            .overlay(alignment: side == .left ? .leading : .trailing) {
                if pages.count > 1 && !hidden {
                    VStack(spacing: 4) {
                        ForEach(0..<pages.count, id: \.self) { i in
                            Circle().fill(ink(i == pageIndex ? 0.85 : 0.3)).frame(width: 4, height: 4)
                        }
                    }
                    .padding(.horizontal, 7)
                    .modifier(Legibility(dark: inkState.dark[Ink.key(side)] ?? false))
                    .environment(\.inkDark, inkState.dark[Ink.key(side)] ?? false)
                    .transition(.opacity)
                }
            }
            .foregroundStyle(ink(0.88))
            // Quieter than the Dock at rest, brighter while the pointer is there.
            .opacity(pointer.x != nil ? 0.9 : 0.7)
            .environment(\.ambient, presence.visible && !hidden)
            .animation(.spring(duration: 0.55, bounce: 0.18), value: visible.map(\.id))
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: pointer.x)
            .animation(.smooth(duration: 0.3), value: pointer.x != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: side == .left ? .leading : .trailing, vertical: .bottom))
        // Invisible copies, only to learn each widget's natural width; in the
        // background so they never affect the layout.
        .background(alignment: .bottomLeading) {
            ZStack {
                ForEach(shown, id: \.id) { item in
                    item.widest.fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plan.measured(item.id, $0) }
                }
            }
            .frame(height: pointer.boxHeight)
            .environment(\.ambient, false)
            .hidden()
        }
        .coordinateSpace(.named("wing"))
        // Playing again moves music to the main page; follow it there.
        .onChange(of: music.isPlaying) { _, playing in
            guard playing, plan.side(of: "music") == side, (plan.page[side] ?? 0) != 0 else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.15)) { plan.page[side] = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            withAnimation(.spring(duration: 0.5, bounce: 0.15)) { prefsVersion += 1 }
        }
    }
}

/// A short springy hop whenever `trigger` changes: something new arrived.
private struct Bump: ViewModifier {
    let trigger: AnyHashable

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, scale in
            view.scaleEffect(scale, anchor: .bottom)
        } keyframes: { _ in
            SpringKeyframe(1.09, duration: 0.16, spring: .snappy)
            SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
        }
    }
}
