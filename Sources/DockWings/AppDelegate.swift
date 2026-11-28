// Creates the panel areas and keeps them placed around the Dock: the two
// wings beside it (Wings.swift decides which widget goes where), the shelf
// and the drawer window above it. Re-places on Dock changes, feeds the
// pointer to the magnification, and keeps the drawer window click-through
// except over the drawer itself.
// Re-places on Dock changes (apps launching/quitting, display changes), holds
// still while the mouse is over the Dock (magnification), and hides
// everything when the Dock isn't a fixed bottom Dock.
import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let music = Music()
    private let todos = Todos()
    private let shelf = Shelf()
    private let pointer = Pointer()
    private let plan = WingPlan()
    private let claude = ClaudeStatus()
    private let weather = Weather()
    private let batteries = Batteries()
    private let clipboard = Clipboard()
    private let latest = Latest()
    private let jobs = Jobs()
    private let wanikani = WaniKani.shared
    private let downloads = Downloads()

    private var musicPanel: StripPanel!
    private var todoPanel: StripPanel!
    private var drawerPanel: StripPanel!
    private var notchPanel: StripPanel!
    /// The player widget on the lock screen; empty (and click-through) while unlocked.
    private var buddy: Buddy!
    private var backdrop: NSWindow?
    private var watchers: [AnyCancellable] = []
    private let windows = Windows()

    private var dragCount = NSPasteboard(name: .drag).changeCount

    /// Dock bar: apps dragged in among the spacers (screen x).
    private var barHoles: [ClosedRange<CGFloat>] = []
    /// Dock bar: the right wing's region on screen (the door's room is in it).
    private var rightWing: NSRect?

    /// Space between the Dock and a panel.
    private let gap: CGFloat = 12

    /// DockWings has no menu bar, but Cmd-C/V/X/A/Z only reach text fields
    /// through a main menu, so install a hidden Edit menu.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "DockWings", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Opening DockWings again (Spotlight, Finder) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showSettings()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        Hotkey.install()
        if Config.demo == nil && !UserDefaults.standard.bool(forKey: "SetUpDone") { windows.showSetup() }
        // Keep the Claude Code hooks pointing at wherever this copy lives.
        if ClaudeHooks.installed { ClaudeHooks.set(true) }
        DistributedNotificationCenter.default().addObserver(forName: .init("local.dockwings.reopen"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotificationCenter.default.post(name: .openSettings, object: nil) }
        }
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { self.windows.showSettings() }
        }
        if let path = Config.backdrop { backdrop = Self.makeBackdrop(path) }

        let models = WingModels(music: music, weather: weather, claude: claude, todos: todos, jobs: jobs,
                                latest: latest, clipboard: clipboard, batteries: batteries, wanikani: wanikani, shelf: shelf)
        musicPanel = StripPanel(WingSide(side: .left, models: models, plan: plan, pointer: pointer.left))
        todoPanel = StripPanel(WingSide(side: .right, models: models, plan: plan, pointer: pointer.right))
        for monitor in [NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [unowned self] _ in
            MainActor.assumeIsolated { self.trackPointer() }
        }, NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [unowned self] event in
            MainActor.assumeIsolated { self.trackPointer() }
            return event
        }, NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [unowned self] event in
            MainActor.assumeIsolated { self.notchGesture(event) || self.swipe(event) ? nil : event }
        }, NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [unowned self] event in
            // Two-finger tap on the music widget plays or pauses (instead of the wing's menu).
            MainActor.assumeIsolated {
                guard music.hovering, musicPanel.frame.contains(NSEvent.mouseLocation) || Notch.shared.showsCard else { return event }
                music.playPause()
                return nil
            }
        }] { _ = monitor }
        buddy = Buddy(music: music, claude: claude, latest: latest, batteries: batteries,
                      clipboard: clipboard, todos: todos, wanikani: wanikani)
        buddy.widgetX = { [unowned self] id in
            for (side, wing, panel) in [(Side.left, pointer.left, musicPanel!), (.right, pointer.right, todoPanel!)] where plan.side(of: id) == side {
                if let f = wing.frames[id] { return panel.frame.minX + f.midX }
            }
            return nil
        }
        buddy.notchPanelRect = { [unowned self] in
            guard Notch.shared.expanded, Notch.shared.showsCard else { return nil }
            let f = Notch.shared.frame, p = notchPanel.frame
            return NSRect(x: p.minX + f.minX, y: p.maxY - f.maxY, width: f.width, height: f.height)
        }
        buddy.widgetSpans = { [unowned self] in
            guard Config.bar else { return [] }
            return barHoles + [(Side.left, pointer.left, musicPanel!), (.right, pointer.right, todoPanel!)].flatMap { side, wing, panel in
                wing.frames.filter { plan.side(of: $0.key) == side }.map { (panel.frame.minX + $0.value.minX)...(panel.frame.minX + $0.value.maxX) }
            }
        }
        buddy.guestRoom = { [unowned self] in
            guard Config.bar, let wing = rightWing else { return nil }
            let starts = pointer.right.frames.filter { plan.side(of: $0.key) == .right }.map { todoPanel.frame.minX + $0.value.minX }
            let end = (starts.min() ?? wing.maxX) - 20
            let start = wing.minX + 8
            return end > start ? start...end : nil
        }
        notchPanel = StripPanel(NotchView())
        // Above the menu bar (24), so the ears draw over it.
        notchPanel.level = .statusBar
        // Moves over the notch reach the app's own monitor even while the
        // window takes the pointer (the global monitor goes quiet then).
        notchPanel.acceptsMouseMovedEvents = true
        // Also in full-screen apps, where only the HUD shows.
        notchPanel.collectionBehavior.insert(.fullScreenAuxiliary)
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: notchPanel, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated {
                let seen = self.awake && self.notchPanel.occlusionState.contains(.visible)
                if Notch.shared.visible != seen { Notch.shared.visible = seen }
            }
        }
        placeNotch()
        if Config.demo == "notch" { Notch.shared.runDemo() }
        MediaKeys.start()
        downloads.start()
        DockSpacers.start()
        LockScreen.attach([notchPanel]) { locked in
            Notch.shared.locked = locked
        }
        Notch.shared.watch(claude: claude, batteries: batteries)
        Notch.shared.watch(music: music)
        Notch.shared.onDrop = { [unowned self] urls in
            shelf.add(urls)
            Notch.shared.dragging = false
            let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            Notch.shared.post(NotchAlert(id: "kept", icon: .image(NSWorkspace.shared.icon(forFile: urls[0].path)),
                                         trailing: .done, title: "On the shelf", subtitle: name, duration: 2))
        }
        drawerPanel = StripPanel(DrawerHost(todos: todos, clipboard: clipboard, weather: weather, batteries: batteries, claude: claude, music: music, wanikani: wanikani))
        // A click in any other app closes the drawer.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [unowned self] _ in
            MainActor.assumeIsolated {
                if Drawers.shared.open != nil { Drawers.shared.open = nil }
                if Notch.shared.expanded { withAnimation(.spring(duration: 0.4, bounce: 0.1)) { Notch.shared.expanded = false } }
                self.watchDragWhilePressed()
            }
        }
        Drawers.shared.locate = { [unowned self] id in self.drawerAnchor(id) }
        // The grown music player in the notch takes typing (its search field).
        watchers.append(Notch.shared.$expanded.receive(on: RunLoop.main).sink { [unowned self] on in
            if on { self.notchPanel.makeKey() }
        })
        watchers.append(Drawers.shared.$open.receive(on: RunLoop.main).sink { [unowned self] _ in
            self.updateClicks()
        })

        for publisher in [music.objectWillChange, todos.objectWillChange, shelf.objectWillChange, clipboard.objectWillChange,
                          latest.objectWillChange, jobs.objectWillChange, batteries.objectWillChange, claude.objectWillChange,
                          weather.objectWillChange, Health.shared.objectWillChange, InUse.shared.objectWillChange,
                          PhoneApps.shared.objectWillChange] {
            watchers.append(publisher.receive(on: RunLoop.main).sink { [unowned self] _ in self.updateClicks() })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in
                MainActor.assumeIsolated { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.checkFullScreen() } }
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in
                MainActor.assumeIsolated { self.layoutSoon() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { self.layoutSoon(); self.placeNotch() }
        }
        // Launches, quits and Space changes already relayout; this catches
        // the rest (icons dragged in or out of the Dock).
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { self.layout() }
        }
        // The screenshot thumbnail only needs watching while the screenshot
        // UI runs. It is a background app, which the launch notifications
        // leave out, so watch the running-app list instead.
        appsWatch = NSWorkspace.shared.observe(\.runningApplications) { [unowned self] _, _ in
            DispatchQueue.main.async { self.updateScreenshotWatch(); self.watchDockProcess() }
        }
        updateScreenshotWatch()
        watchDockProcess()
        // Looping animations stop while the wings can't be seen.
        for name in [NSWindow.didChangeOcclusionStateNotification] {
            for panel in [musicPanel!, todoPanel!] {
                NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [unowned self] _ in
                    MainActor.assumeIsolated { self.updateVisible() }
                }
            }
        }
        for (name, on) in [(NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
                           (NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in
                MainActor.assumeIsolated { self.awake = on; self.updateVisible(); if on { self.followDock() } }
            }
        }
        // Widgets fill in over the first second or two (music state, weather,
        // batteries) and would reshuffle; stay hidden meanwhile, then rise once.
        Presence.shared.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Presence.shared.replay() }
        layout()
        followDock()
        updateClicks()
        if let id = UserDefaults.standard.string(forKey: "Open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Drawers.shared.toggle(id)
            }
        }
    }

    /// The Dock animates when its contents change; place again once it settles.
    private func layoutSoon() {
        for delay in [0.35, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.layout() }
        }
    }

    /// The Dock is (re)starting: its spacers come back within a second or
    /// two, so place every 0.1 s for 4 s instead of waiting for the 3 s timer.
    private func followDock() {
        followUntil = Date().addingTimeInterval(4)
        guard followTimer == nil else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [unowned self] timer in
            MainActor.assumeIsolated {
                self.layout()
                if Date() > self.followUntil { timer.invalidate(); self.followTimer = nil }
            }
        }
    }
    /// A new Dock process (restarted for spacers, or crashed): follow it.
    private func watchDockProcess() {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        if let pid, pid != dockPID, dockPID != nil { followDock() }
        dockPID = pid ?? dockPID
    }
    private var dockPID: pid_t?
    private var followTimer: Timer?
    private var followUntil = Date.distantPast

    /// The notch window: fixed size, top-centred on the notch; hidden on
    /// screens without one. Independent of the Dock.
    private func placeNotch() {
        guard let (rect, _) = Notch.locate() else { notchPanel.conceal(); return }
        let size = Notch.windowSize
        if Notch.shared.size != rect.size { Notch.shared.size = rect.size }
        notchPanel.setRegion(NSRect(x: rect.midX - size.width / 2, y: rect.maxY - size.height, width: size.width, height: size.height))
    }

    /// Hover over the notch shape shows the alert's card; only then does the
    /// notch window take clicks.
    private func trackNotch(_ mouse: NSPoint) {
        guard Config.demo != "notch" else { return }
        let f = Notch.shared.frame, p = notchPanel.frame
        let shape = NSRect(x: p.minX + f.minX, y: p.maxY - f.maxY, width: f.width, height: f.height)
        // A file drag gets a wider catch area, so the notch is easy to hit;
        // an open widget a little slack before it closes.
        let margin: CGFloat = Notch.shared.dragging ? -40 : Notch.shared.hovering ? -12 : -2
        let inArea = notchPanel.alphaValue > 0 && (!Notch.shared.locked || Notch.shared.alert?.id == "music") && shape.insetBy(dx: margin, dy: margin).contains(mouse)
        notchCatch = inArea ? shape.insetBy(dx: margin, dy: margin) : .zero
        let over = inArea && Notch.shared.alert != nil && !Notch.shared.fullScreen
        if over != Notch.shared.hovering { Notch.shared.hovering = over }
        // Over the notch the window takes events even with nothing live, so
        // swipes and two-finger taps reach it (the menu bar has nothing there).
        notchPanel.passThrough = !inArea
        // While the notch has the pointer, check where it is a few times a
        // second too, so leaving is never missed.
        if inArea, notchWatch == nil {
            notchWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [unowned self] _ in
                MainActor.assumeIsolated { self.trackNotch(NSEvent.mouseLocation) }
            }
        } else if !inArea {
            notchWatch?.invalidate()
            notchWatch = nil
        }
    }

    private var notchWatch: Timer?

    /// Where the pointer counts as over the notch (screen coordinates); empty when it isn't.
    private var notchCatch = NSRect.zero
    private var notchAxisVertical: Bool?
    private var notchDistance: CGFloat = 0
    private var notchFlipped = false

    /// Two-finger swipe over the notch: down opens the alert's card (music
    /// and WaniKani: the grown player), up closes it or sends the alert
    /// away. One action per swipe.
    private func notchGesture(_ event: NSEvent) -> Bool {
        if event.momentumPhase != [] { return notchAxisVertical != nil }
        guard notchCatch.contains(NSEvent.mouseLocation) || notchAxisVertical != nil else { return false }
        // The grown player scrolls its lyrics and queue: notch swipes only on
        // its top band (where the small card was), so swiping up there folds it.
        let band = notchCatch.maxY - (Notch.shared.size.height + 74)
        if Notch.shared.expanded, notchAxisVertical == nil, NSEvent.mouseLocation.y < band { return false }
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY  // + = fingers up
        // Over the music card sideways swipes seek and skip (swipe(_:)), so
        // it sees every phase too; this one keeps the vertical swipes.
        let musicCard = Notch.shared.showsCard && Notch.shared.alert?.id == "music"
        switch event.phase {
        case .began:
            notchAxisVertical = nil
            notchDistance = 0
            notchFlipped = false
            if musicCard { return false }
        case .changed:
            if notchAxisVertical == nil, abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 2 {
                notchAxisVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            }
            guard notchAxisVertical == true else { return notchAxisVertical == false && !musicCard }
            notchDistance += dy
            if !notchFlipped, abs(notchDistance) > 30 {
                notchFlipped = true
                withAnimation(.spring(duration: 0.36, bounce: 0.1)) {
                    notchDistance < 0 ? Notch.shared.swipeDown() : Notch.shared.swipeUp()
                }
            }
        case .ended, .cancelled:
            notchAxisVertical = nil
            if musicCard { return false }
        default:
            return false
        }
        return true
    }

    /// A full-screen app in front: its window covers the whole screen,
    /// menu bar area included (a maximised window stops below the menu bar).
    private func checkFullScreen() {
        guard let screen = Notch.locate()?.screen, let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        let full = list.contains { w in
            guard w[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier, w[kCGWindowLayer as String] as? Int == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: b) else { return false }
            return rect.size == screen.frame.size
        }
        if Notch.shared.fullScreen != full { Notch.shared.fullScreen = full }
    }

    /// The wings were hidden because the Dock went away (a full-screen app).
    private var concealed = false

    private func layout() {
        guard let dock = DockGeometry.usableDock() else {
            for panel in [musicPanel, todoPanel, drawerPanel] { panel?.conceal() }
            buddy.place(on: nil)
            // Empty the wings while unseen, so coming back doesn't show the
            // old widgets and animate them out before they rise in.
            if !concealed { Presence.shared.shown = false }
            concealed = true
            return
        }
        // Back from a full-screen app: rise in again instead of just being
        // there. Plain desktop switches don't replay.
        if concealed {
            concealed = false
            Presence.shared.replay()
            DispatchQueue.main.async { self.updateClicks() }
        }
        // Buddies keep off the app icons. With the Dock bar that is only the
        // apps between the spacer runs: the widget parts are theirs to walk.
        let sides = Config.bar ? DockGeometry.spacerSides() : nil
        // Dock bar mid-restart (no spacers to read yet): keep the wings where
        // they are rather than jumping beside a guessed Dock.
        if Config.bar, sides == nil, musicPanel.isVisible, musicPanel.alphaValue > 0 { return }
        let apps = sides.map { $0.left.maxX...max($0.left.maxX, $0.right.minX) }
        buddy.dockIcons = apps ?? dock.rect.minX...dock.rect.maxX
        // Apps dragged in among the spacers: also not to be stood on.
        barHoles = sides.map { ($0.leftHoles + $0.rightHoles).map { $0.minX...$0.maxX } } ?? []
        buddy.place(on: dock.screen)
        // Magnification grows the Dock under the mouse; hold still meanwhile.
        if dock.rect.insetBy(dx: 0, dy: -60).contains(NSEvent.mouseLocation), musicPanel.isVisible { return }

        // The Dock's glass spans its icon list horizontally and runs from the
        // top of the space the Dock reserves down to 5pt above the screen edge
        // (measured on macOS 27; the icon list's own height varies). Panels
        // copy that box exactly.
        let list = dock.rect
        let bottom = dock.screen.frame.minY + 5
        let d = NSRect(x: list.minX, y: bottom, width: list.width, height: dock.screen.visibleFrame.minY - bottom)
        let screen = dock.screen.frame
        // Room above the Dock box for magnified widgets to grow into.
        pointer.update(box: d)
        let height = d.height + pointer.headroom
        // Bar mode: the Dock is stretched with spacer tiles and the wings sit
        // inside it, over the spacers. Otherwise they sit beside the Dock.
        let leftRegion: NSRect, rightRegion: NSRect
        var holes: [Side: [ClosedRange<CGFloat>]] = [:]
        if let gaps = sides {
            leftRegion = NSRect(x: gaps.left.minX, y: d.minY, width: gaps.left.width, height: height)
            rightRegion = NSRect(x: gaps.right.minX, y: d.minY, width: gaps.right.width, height: height)
            holes[.left] = gaps.leftHoles.map { ($0.minX - leftRegion.minX)...($0.maxX - leftRegion.minX) }
            holes[.right] = gaps.rightHoles.map { ($0.minX - rightRegion.minX)...($0.maxX - rightRegion.minX) }
            rightWing = gaps.rightHoles.isEmpty ? rightRegion : nil
        } else {
            rightWing = nil
            let leftWidth = d.minX - screen.minX - 2 * gap
            let rightWidth = screen.maxX - d.maxX - 2 * gap
            leftRegion = NSRect(x: d.minX - gap - leftWidth, y: d.minY, width: leftWidth, height: height)
            rightRegion = NSRect(x: d.maxX + gap, y: d.minY, width: rightWidth, height: height)
        }
        plan.setSpace(left: leftRegion.width, right: rightRegion.width, holes: holes)
        musicPanel.setRegion(leftRegion)
        todoPanel.setRegion(rightRegion)
        // Each widget's own area too: one wing can sit over light and dark at once.
        var inkRegions = [Ink.key(.left): leftRegion, Ink.key(.right): rightRegion]
        for (side, wing, region) in [(Side.left, pointer.left, leftRegion), (.right, pointer.right, rightRegion)] {
            for (id, f) in wing.frames where plan.side(of: id) == side {
                inkRegions[id] = NSRect(x: region.minX + f.minX, y: region.maxY - f.maxY, width: f.width, height: f.height)
            }
        }
        Ink.shared.update(regions: inkRegions, screen: dock.screen)
        // Up to the menu bar: the WaniKani drawer sits at the top of the screen.
        drawerPanel.setRegion(NSRect(x: screen.minX, y: d.maxY + gap, width: screen.width,
                                     height: dock.screen.visibleFrame.maxY - d.maxY - gap))
        buddy.order(below: drawerPanel)
        Drawers.shared.dockCenter = d.midX - screen.minX
    }

    /// Panels take clicks only where they show something.
    private func updateClicks() {
        // Wings sit in the space the Dock reserves, so they may always take clicks.
        musicPanel.passThrough = false
        todoPanel.passThrough = Presence.shared.screenshotThumbnail && !Config.bar
        updateDrawerClicks()
        if Drawers.shared.open != nil { drawerPanel.makeKey() }
    }

    /// The drawer window is wide; it takes clicks only on the drawer itself,
    /// so the rest of the screen stays usable (and a click there closes it).
    private func updateDrawerClicks() {
        let frame = Drawers.shared.frame
        let rect = NSRect(x: drawerPanel.frame.minX + frame.minX, y: drawerPanel.frame.maxY - frame.maxY,
                          width: frame.width, height: frame.height)
        drawerPanel.passThrough = Drawers.shared.open == nil || !rect.contains(NSEvent.mouseLocation)
    }

    /// Centre of a widget, in the drawer window's coordinates.
    private func drawerAnchor(_ id: String) -> CGFloat? {
        guard let side = plan.side(of: id) else { return nil }
        let (wing, panel) = side == .left ? (pointer.left, musicPanel!) : (pointer.right, todoPanel!)
        guard let frame = wing.frames[id] else { return nil }
        return panel.frame.minX + frame.midX - drawerPanel.frame.minX
    }

        private var swipeStart = Date()
    private var swipeDistance: CGFloat = 0
    private var swipeFrom = 0.0

    private var swipeAxisVertical: Bool?
    private var swipeFlipped = false
    /// Up/down over the music drawer's search field or bottom row: volume.
    private var swipeVolume = false

    /// Two-finger swipes. Up or down over a wing flips its page of widgets.
    /// Left or right over the music widget scrubs through the song (shown
    /// live, seeks on release); a quick flick skips.
    private func swipe(_ event: NSEvent) -> Bool {
        if event.momentumPhase != [] { return swipeAxisVertical != nil }  // ignore the coast after a swipe
        let mouse = NSEvent.mouseLocation
        let side: Side? = musicPanel.frame.contains(mouse) ? .left : todoPanel.frame.contains(mouse) ? .right : nil
        // Over the open music drawer, sideways swipes seek and skip like in
        // Tide; up and down still scroll its lyrics and queue.
        let inDrawer = Drawers.shared.open == "music" && !drawerPanel.passThrough
        // The notch's music card (Dock bar) seeks and skips like the widget.
        let inNotchCard = Notch.shared.showsCard && Notch.shared.alert?.id == "music" && notchPanel.frame.contains(mouse)
        guard side != nil || inDrawer || inNotchCard || swipeAxisVertical != nil else { return false }
        let musicSwipe = music.hovering || inDrawer
        // In the drawer the lyrics and queue scroll; above and below them
        // (search field, button row) up and down sets the volume, as on
        // Tide's player bar.
        let drawer = Drawers.shared.frame
        let drawerRect = NSRect(x: drawerPanel.frame.minX + drawer.minX, y: drawerPanel.frame.maxY - drawer.maxY,
                                width: drawer.width, height: drawer.height)
        let volumeZone = inDrawer && (mouse.y < drawerRect.minY + 52 || mouse.y > drawerRect.maxY - 48)
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY  // + = fingers up
        switch event.phase {
        case .began:
            swipeStart = Date()
            swipeDistance = 0
            swipeAxisVertical = nil
            swipeFlipped = false
            swipeFrom = music.progress(at: Date())
            swipeVolume = volumeZone
        case .changed:
            if swipeAxisVertical == nil, abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 2 {
                swipeAxisVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
                swipeStart = Date()  // time the flick from the first movement, not the finger landing
            }
            if swipeAxisVertical == true, side == nil {
                guard swipeVolume else { return false }
                music.setVolume(min(1, max(0, music.volume + Double(dy) * (event.hasPreciseScrollingDeltas ? 0.004 : 0.05))))
            } else if swipeAxisVertical == true {
                swipeDistance += dy
                if !swipeFlipped, abs(swipeDistance) > 30, let side {
                    plan.flip(side, by: swipeDistance > 0 ? 1 : -1)
                    swipeFlipped = true
                }
            } else if swipeAxisVertical == false, musicSwipe, music.duration > 0 {
                swipeDistance += dx
                if abs(swipeDistance) > 12 {
                    music.scrub = min(max(swipeFrom + Double(swipeDistance) * 0.25 / music.duration, 0), 1)
                }
            } else {
                return false
            }
        case .ended, .cancelled:
            if swipeAxisVertical == true, side == nil {
                swipeAxisVertical = nil
                return swipeVolume
            }
            if swipeAxisVertical == false, musicSwipe {
                // A flick is a short burst; anything longer is a seek, however fast,
                // so a quick seek never skips (or restarts) the song.
                let elapsed = Date().timeIntervalSince(swipeStart)
                let quick = abs(swipeDistance) > 60 && elapsed < 0.25
                if quick {
                    swipeDistance > 0 ? music.previous() : music.next()  // owner's preferred direction
                } else if let target = music.scrub {
                    music.seek(to: target)
                }
                withAnimation(.smooth) { music.scrub = nil }
            }
            swipeAxisVertical = nil
        default:
            return false
        }
        return true
    }

    /// Feeds the pointer's x, in each wing's own coordinates, to the
    /// magnification while it is over the Dock's band.
    private var awake = true

    private func updateVisible() {
        let seen = awake && [musicPanel!, todoPanel!].contains { $0.occlusionState.contains(.visible) }
        if Presence.shared.visible != seen { Presence.shared.visible = seen }
    }

    private var screenshotTimer: Timer?

    private func updateScreenshotWatch() {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.screencaptureui").isEmpty
        if running, screenshotTimer == nil {
            screenshotTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [unowned self] _ in
                MainActor.assumeIsolated { self.watchScreenshotThumbnail() }
            }
        } else if !running {
            screenshotTimer?.invalidate()
            screenshotTimer = nil
            watchScreenshotThumbnail()
        }
    }

    private var dragTimer: Timer?

    /// File drags are only checked while the mouse button is down.
    private func watchDragWhilePressed() {
        guard dragTimer == nil else { return }
        dragCount = NSPasteboard(name: .drag).changeCount
        // A buddy hangs from the middle of the dragged item's bottom edge.
        // The screenshot thumbnail's drag image is 0.85 of the thumbnail, with
        // the pointer about 0.66 of the way in from where it was pressed past
        // the first fifth (measured); a Finder icon is about 64 pt around it.
        let down = NSEvent.mouseLocation
        watchScreenshotThumbnail()
        if let t = thumbnailFrame, t.contains(down) {
            let left = 0.66 * max(0, down.x - t.minX - 0.15 * t.width)
            let top = 0.66 * max(0, t.maxY - down.y - 0.2 * t.height)
            buddy.dragHang = CGPoint(x: 0.85 * t.width / 2 - left, y: 0.85 * t.height - top)
        } else {
            buddy.dragHang = CGPoint(x: 0, y: 32)
        }
        dragTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { self.watchDrag() }
        }
    }

    private func trackPointer() {
        let mouse = NSEvent.mouseLocation
        buddy.track(mouse)
        // Music shows its controls while the pointer is over it, on either
        // side, or over the notch's music card (Dock bar).
        let notchCard = Notch.shared.showsCard && Notch.shared.alert?.id == "music"
        let hovering = notchCard || plan.side(of: "music") != nil && [(pointer.left, musicPanel!), (pointer.right, todoPanel!)].contains { wing, panel in
            guard let f = wing.frames["music"], panel.frame.contains(mouse) else { return false }
            let x = mouse.x - panel.frame.minX
            return x > f.minX - 30 && x < f.maxX + 30
        }
        if Config.demo == nil, hovering != music.hovering { music.hovering = hovering }
        // Only touch the models when something changes: each change redraws a wing.
        let inBand = pointer.inBand(mouse)
        let left = inBand ? mouse.x - musicPanel.frame.minX : nil, right = inBand ? mouse.x - todoPanel.frame.minX : nil
        if pointer.left.x != left { pointer.left.x = left }
        if pointer.right.x != right { pointer.right.x = right }
        updateDrawerClicks()
        trackNotch(mouse)
    }

    /// A file drag is in progress when the drag pasteboard changed since the
    /// mouse button went down and it carries file URLs.
    private func watchDrag() {
        guard Config.demo == nil else { return }
        let board = NSPasteboard(name: .drag)
        var dragging = shelf.dragging
        if NSEvent.pressedMouseButtons & 1 == 0 {
            dragging = false
            dragTimer?.invalidate()
            dragTimer = nil
        } else if !dragging, board.changeCount != dragCount, board.types?.contains(.fileURL) == true {
            dragging = true
        }
        // The buddies follow any file drag, screenshot thumbnails (file
        // promises, images) included; the shelf and notch take real files only.
        let promised: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .init("com.apple.pasteboard.promised-file-url"),
                                                        .init("com.apple.NSFilePromiseItemMetaData")]
        let anyDrag = NSEvent.pressedMouseButtons & 1 != 0 && board.changeCount != dragCount
            && board.types?.contains(where: promised.contains) == true
        if anyDrag != buddy.fileDrag { buddy.fileDrag = anyDrag }
        if dragging != shelf.dragging { shelf.dragging = dragging }
        if dragging != Notch.shared.dragging { Notch.shared.dragging = dragging }
        if dragging { trackNotch(NSEvent.mouseLocation) }
    }

    /// The floating thumbnail after a screenshot is a small Accessibility
    /// window of com.apple.screencaptureui (holding a "Markup" button), present
    /// exactly while the thumbnail is on screen. Its drawing lives in a
    /// full-screen window the app keeps open all the time, so window lists
    /// can't tell; the Accessibility tree can (DockWings has that permission).
    /// Where the screenshot thumbnail is (screen coordinates), while it shows.
    private var thumbnailFrame: CGRect?
    private var appsWatch: NSKeyValueObservation?

    private func watchScreenshotThumbnail() {
        var frame: CGRect?
        let showing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.screencaptureui").contains { app in
            var value: CFTypeRef?
            let element = AXUIElementCreateApplication(app.processIdentifier)
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return false }
            return windows.contains { window in
                var size = CGSize.zero
                var sizeValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success {
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                }
                guard size.width > 40 && size.width < 600 && size.height > 30 && size.height < 400 else { return false }
                var origin = CGPoint.zero
                var originValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &originValue) == .success {
                    AXValueGetValue(originValue as! AXValue, .cgPoint, &origin)
                }
                // Accessibility counts y down from the top of the main screen.
                let top = NSScreen.screens.first?.frame.height ?? 0
                frame = CGRect(x: origin.x, y: top - origin.y - size.height, width: size.width, height: size.height)
                return true
            }
        }
        thumbnailFrame = frame
        if showing != Presence.shared.screenshotThumbnail {
            withAnimation(.spring(duration: 0.45, bounce: 0.1)) { Presence.shared.screenshotThumbnail = showing }
            // Let clicks reach the thumbnail right away, even mid-animation.
            todoPanel.passThrough = showing
        }
    }

    /// Test aid: an image behind the panels, standing in for a wallpaper.
    private static func makeBackdrop(_ path: String) -> NSWindow? {
        guard let image = NSImage(contentsOfFile: path), let screen = NSScreen.main else { return nil }
        let frame = NSRect(x: 0, y: 0, width: screen.frame.width, height: 260)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.ignoresMouseEvents = true
        let view = NSImageView(frame: frame)
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("DockWingsOpenSettings")
}
