// Drawers: the panels that slide up above a widget when you click it (todo
// list, clipboard history, weather hours, batteries, Claude sessions, music,
// the buddy's characters). One at a time. The
// drawer window spans the screen width above the Dock; AppDelegate sets
// `anchorX` to the clicked widget's centre so the drawer sits right above it.
// Escape or a click in another app closes it. The WaniKani drawer (summary
// and reviews) sits centred at the top of the screen instead, easier on the eyes,
// and grows out of the notch like the Dynamic Island.
import SwiftUI

@MainActor
final class Drawers: ObservableObject {
    static let shared = Drawers()

    /// Id of the widget whose drawer is open.
    @Published var open: String?
    /// Centre of that widget, in the drawer window's coordinates.
    @Published var anchorX: CGFloat = 0
    /// The open drawer's frame in its window (top-left origin), so the
    /// window can let clicks through everywhere else.
    var frame = CGRect.zero

    /// The Dock's centre, in drawer coordinates. The WaniKani drawer sits
    /// centred on it, at the top of the screen.
    var dockCenter: CGFloat = 0

    /// Set by AppDelegate: the centre of a widget, in drawer coordinates.
    var locate: ((String) -> CGFloat?)?

    /// Places the drawer before opening it, so it appears right above the
    /// widget instead of sliding over from where the last one was.
    func toggle(_ id: String) {
        if open == id { open = nil; return }
        if let x = locate?(id) { anchorX = x }
        open = id
    }
}

struct DrawerHost: View {
    @ObservedObject var drawers = Drawers.shared
    let todos: Todos
    let clipboard: Clipboard
    let weather: Weather
    let batteries: Batteries
    let claude: ClaudeStatus
    let music: Music
    @ObservedObject var wanikani: WaniKani

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                // Full-width base, so the drawer's alignment guide has room.
                Color.clear.frame(width: g.size.width, height: g.size.height)
                if let id = drawers.open {
                    let top = id == "wanikani"
                    content(id)
                        .fixedSize()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drawers.frame = $0 }
                        .padding(.top, top ? 8 : 0)
                        .frame(maxHeight: .infinity, alignment: top ? .top : .bottom)
                        // Centre over the widget using the drawer's real width,
                        // kept 12pt inside the screen.
                        .alignmentGuide(.leading) { d in
                            let x = top || drawers.anchorX <= 0 ? drawers.dockCenter - d.width / 2 : drawers.anchorX - d.width / 2
                            return -min(max(x, 12), g.size.width - d.width - 12)
                        }
                        .id(id)
                        .transition(top ? .island : .offset(y: 24).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
        }
        .onExitCommand { drawers.open = nil }
        .animation(.spring(duration: 0.4, bounce: 0.12), value: drawers.open)
        .onChange(of: drawers.open) { _, id in
            withAnimation(.spring(duration: 0.36, bounce: 0.1)) { Notch.shared.yielded = id == "wanikani" }
        }
    }

    @ViewBuilder
    private func content(_ id: String) -> some View {
        switch id {
        case "todo": TodoList(todos: todos)
        case "clipboard": ClipboardList(clipboard: clipboard)
        case "weather": WeatherHours(weather: weather)
        case "batteries": BatteryList(batteries: batteries)
        case "mac": MacDrawer(health: Health.shared)
        case "claude": ClaudeSessions(claude: claude)
        case "music": MusicDrawer(music: music)
        case "wanikani": WaniKaniDrawer(wk: wanikani)
        case "buddy": BuddyDrawer()
        default: EmptyView()
        }
    }
}

/// Like the Dynamic Island: the drawer starts as a pill the notch's size
/// right under it and grows into the card (a growing mask, so nothing
/// stretches), its content fading in. Closing goes back in.
private struct Island: ViewModifier {
    let shown: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: shown ? 0 : 6)
            .opacity(shown ? 1 : 0)
            // The pill is the card's own colour (no black box), there only
            // while the content isn't.
            .background(Color(white: 0.09).opacity(shown ? 0 : 0.88))
            .clipShape(IslandShape(progress: shown ? 1 : 0, start: Notch.shared.size))
            .offset(y: shown ? 0 : -8)
    }
}

/// A rounded rect growing from a notch-sized pill at the top centre to the
/// full frame. Animates through `progress`, so every frame is in between.
private struct IslandShape: Shape {
    var progress: CGFloat
    let start: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in r: CGRect) -> Path {
        let p = max(0, progress)
        let w = start.width + (r.width - start.width) * p
        let h = start.height + (r.height - start.height) * p
        let radius = start.height / 2 + (18 - start.height / 2) * min(p, 1)
        return Path(roundedRect: CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: max(h, 0)),
                    cornerRadius: max(radius, 0), style: .continuous)
    }
}

private extension AnyTransition {
    static var island: AnyTransition {
        .asymmetric(insertion: .modifier(active: Island(shown: false), identity: Island(shown: true)).animation(.spring(duration: 0.5, bounce: 0.18)),
                    removal: .modifier(active: Island(shown: false), identity: Island(shown: true)).animation(.spring(duration: 0.4, bounce: 0)))
    }
}

/// Press feedback for a whole widget: dips while held.
struct WidgetPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.95 : 1, anchor: .bottom)
            .animation(.spring(duration: 0.2, bounce: 0.35), value: configuration.isPressed)
    }
}

extension View {
    /// Makes a whole widget clickable. A real button, not a tap gesture:
    /// tap gestures don't fire in DockWings' background panels.
    func tapAction(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { contentShape(Rectangle()) }.buttonStyle(WidgetPress())
    }
}

/// Lets widgets leave and rise in again, e.g. after a full-screen app.
@MainActor
final class Presence: ObservableObject {
    static let shared = Presence()
    @Published var shown = true
    /// The macOS screenshot thumbnail is in the bottom-right corner; the
    /// right wing steps aside for it.
    @Published var screenshotThumbnail = false
    /// The wings are on a lit, unlocked screen and not covered.
    @Published var visible = true

    /// Rise back in after being hidden (`shown` was cleared while concealed).
    func replay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(duration: 0.6, bounce: 0.15)) { self.shown = true }
        }
    }
}
