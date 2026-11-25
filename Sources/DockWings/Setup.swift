// First-time setup and the Settings window. Setup runs once (until
// `SetUpDone` is set) and walks through what DockWings shows, the macOS
// permissions, and the optional extras. Settings opens whenever DockWings is
// launched again (Spotlight, Finder) and lets you switch widgets on or off,
// check permissions, install the Claude Code and terminal hooks, and set
// launch at login.
import AppKit
import CoreLocation
import EventKit
import ServiceManagement
import SwiftUI

/// The widgets you can switch off, in display order.
enum WidgetPrefs {
    static let all: [(id: String, name: String, symbol: String)] = [
        ("music", "Music", "music.note"),
        ("weather", "Weather", "cloud.sun"),
        ("wanikani", "WaniKani", "character.book.closed.ja"),
        ("claude", "Claude Code", "asterisk"),
        ("job", "Finished commands", "terminal"),
        ("latest", "Latest screenshot or download", "photo"),
        ("todo", "Reminders", "checklist"),
        ("clipboard", "Clipboard history", "doc.on.clipboard"),
        ("batteries", "Batteries", "battery.75percent"),
        ("mac", "Battery time and temperature", "laptopcomputer"),
        ("health", "Mac health warnings", "cpu"),
        ("inuse", "Microphone and camera in use", "mic"),
        ("phone", "Phone apps about to expire", "iphone.gen3"),
    ]

    static func key(_ id: String) -> String { "off.\(id)" }
}

/// Adds or removes DockWings in Claude Code's hooks (~/.claude/settings.json),
/// leaving every other setting as it is.
enum ClaudeHooks {
    private static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    private static let events = ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]
    /// How long a permission prompt waits for Allow or Deny in DockWings.
    static let permissionWait: TimeInterval = 20
    private static var command: String { "\"\(Bundle.main.executablePath ?? "")\" --claude" }

    static var installed: Bool {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("DockWings") && text.contains("--claude")
    }

    static func set(_ on: Bool) {
        var json = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { group in
                !((group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains("--claude") && ($0["command"] as? String ?? "").contains("DockWings") })
            }
            let timeout = event == "PermissionRequest" ? Int(permissionWait) + 10 : 5
            if on { groups.append(["hooks": [["type": "command", "command": command, "timeout": timeout]]]) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        json["hooks"] = hooks.isEmpty ? nil : hooks
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
        }
    }
}

/// Live permission states, refreshed when a window appears.
@MainActor
final class Permissions: ObservableObject {
    @Published var accessibility = false
    @Published var screen = false
    @Published var reminders = false
    @Published var location = false
    @Published var claude = false
    @Published var loginItem = false

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screen = CGPreflightScreenCaptureAccess()
        reminders = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        let status = CLLocationManager().authorizationStatus
        location = status == .authorizedAlways || status == .authorized
        claude = ClaudeHooks.installed
        loginItem = Launcher.isOn
    }

    func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    func setLogin(_ on: Bool) {
        Launcher.set(on)
        refresh()
        // launchd now runs its own copy: this one steps aside.
        if on, !Launcher.underLaunchd { NSApp.terminate(nil) }
    }

    func setClaude(_ on: Bool) {
        ClaudeHooks.set(on)
        refresh()
    }
}

/// One permission or extra: icon, text, and a status or switch.
private struct Row<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 4)
    }
}

private struct Status: View {
    let ok: Bool
    let fix: () -> Void

    var body: some View {
        if ok {
            Label("On", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green).font(.system(size: 12))
        } else {
            Button("Allow", action: fix).controlSize(.small)
        }
    }
}

/// Permissions and extras, shared by setup and Settings.
private struct PermissionRows: View {
    @ObservedObject var p: Permissions

    var body: some View {
        Row(symbol: "dock.rectangle", title: "Accessibility", detail: "To find exactly where the Dock is.") {
            Status(ok: p.accessibility) { p.openPrivacy("Privacy_Accessibility") }
        }
        Row(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
            detail: "To pick readable text colours from what is behind the wings. Nothing is saved.") {
            Status(ok: p.screen) {
                if !CGRequestScreenCaptureAccess() { p.openPrivacy("Privacy_ScreenCapture") }
            }
        }
        Row(symbol: "checklist", title: "Reminders", detail: "To show and add items from your default list.") {
            Status(ok: p.reminders) { p.openPrivacy("Privacy_Reminders") }
        }
        Row(symbol: "location", title: "Location", detail: "For the weather, rounded to about 10 km.") {
            Status(ok: p.location) { p.openPrivacy("Privacy_LocationServices") }
        }
        Text("Music, Desktop/Downloads and Bluetooth ask the first time they're used.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

private struct ExtraRows: View {
    @ObservedObject var p: Permissions
    @State private var copied = false

    var body: some View {
        Row(symbol: "asterisk", title: "Claude Code status", detail: "Adds hooks to ~/.claude/settings.json so sessions report working, waiting and done.") {
            Toggle("", isOn: Binding(get: { p.claude }, set: { p.setClaude($0) })).toggleStyle(.switch).labelsHidden()
        }
        Row(symbol: "terminal", title: "Finished commands", detail: "Add one line to ~/.zshrc to report terminal commands over 20 s.") {
            Button(copied ? "Copied" : "Copy line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("source \"\(Bundle.main.bundlePath)/Contents/Resources/zsh-hook.zsh\"", forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
        Row(symbol: "power", title: "Open at login", detail: "Start DockWings when you log in.") {
            Toggle("", isOn: Binding(get: { p.loginItem }, set: { p.setLogin($0) })).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// First-time setup: three short pages.
struct SetupView: View {
    @ObservedObject var p: Permissions
    let done: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0:
                    VStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                        Text("Welcome to DockWings").font(.system(size: 24, weight: .bold))
                        Text("Quiet widgets in the empty space beside your Dock: music, Claude Code, reminders, weather and more. They only show up when they have something to say.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Permissions").font(.system(size: 20, weight: .bold))
                        PermissionRows(p: p)
                    }
                default:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Extras").font(.system(size: 20, weight: .bold))
                        ExtraRows(p: p)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { Circle().fill($0 == page ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 6, height: 6) }
                }
                Spacer()
                if page > 0 { Button("Back") { withAnimation(.smooth) { page -= 1 } } }
                Button(page == 2 ? "Done" : "Continue") {
                    if page == 2 { done() } else { withAnimation(.smooth) { page += 1 } }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 420)
        .onAppear { p.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in p.refresh() }
    }
}

/// Settings: widgets, permissions, extras.
struct SettingsView: View {
    @ObservedObject var p: Permissions

    var body: some View {
        Form {
            Section("Widgets") {
                ForEach(WidgetPrefs.all, id: \.id) { widget in
                    WidgetToggle(id: widget.id, name: widget.name, symbol: widget.symbol)
                }
                LyricsToggle()
            }
            Section("Notch") { NotchToggles() }
            Section("Buddy") { BuddyRows() }
            Section("WaniKani") { WaniKaniTokenRow() }
            Section("Permissions") { PermissionRows(p: p) }
            Section("Extras") { ExtraRows(p: p) }
            Section {
                HStack {
                    Text("DockWings 0.1").foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit DockWings") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .onAppear { p.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in p.refresh() }
    }
}

private struct WidgetToggle: View {
    let id: String
    let name: String
    let symbol: String
    @AppStorage private var off: Bool

    init(id: String, name: String, symbol: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
        _off = AppStorage(wrappedValue: false, WidgetPrefs.key(id))
    }

    var body: some View {
        Toggle(isOn: Binding(get: { !off }, set: { off = !$0 })) {
            Label(name, systemImage: symbol)
        }
    }
}

/// Opens the setup or Settings window, one at a time, in front.
@MainActor
final class Windows {
    private let permissions = Permissions()
    private var window: NSWindow?

    func showSetup() {
        show(title: "Welcome", SetupView(p: permissions) { [weak self] in
            UserDefaults.standard.set(true, forKey: "SetUpDone")
            self?.window?.close()
        })
    }

    func showSettings() { show(title: "DockWings Settings", SettingsView(p: permissions)) }

    private func show<V: View>(title: String, _ view: V) {
        window?.close()
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // Size first, keep it inside the visible screen, then centre it, so it
        // never opens under the menu bar.
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var size = controller.view.fittingSize
        size.height = min(size.height, visible.height - 60)
        window.setContentSize(size)
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                      y: max(visible.minY, visible.midY - frame.height / 2)))
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Paste a WaniKani personal access token; doing reviews in the drawer needs
/// one made with the reviews:create permission. Kept in the Keychain, never
/// shown again; to replace it, remove it and paste the new one.
private struct WaniKaniTokenRow: View {
    @State private var token = ""
    @State private var saved = WaniKaniToken.load() != nil

    @ObservedObject private var wk = WaniKani.shared

    var body: some View {
        if saved {
            WaniKaniStatus(wk: wk)
            GoalStepper()
            HStack {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Remove token") {
                    WaniKaniToken.save(nil)
                    saved = false
                    NotificationCenter.default.post(name: .wanikaniToken, object: nil)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Personal access token", text: $token)
                Text("Tick \"reviews: create\" when making the token to do reviews in the drawer.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Link("Get a token", destination: URL(string: "https://www.wanikani.com/settings/personal_access_tokens")!)
                        .font(.system(size: 12))
                    Spacer()
                    Button("Save") {
                        WaniKaniToken.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
                        token = ""
                        saved = true
                        NotificationCenter.default.post(name: .wanikaniToken, object: nil)
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

extension Notification.Name {
    static let wanikaniToken = Notification.Name("DockWingsWaniKaniToken")
    static let audioConnected = Notification.Name("DockWingsAudioConnected")
    static let powerChanged = Notification.Name("DockWingsPowerChanged")
    /// A natural pause: a Claude chat finished or the music was paused.
    static let breakMoment = Notification.Name("DockWingsBreakMoment")
}

private struct GoalStepper: View {
    @AppStorage("wkGoal") private var goal = 15

    var body: some View {
        Stepper("Lessons per day: \(goal)", value: $goal, in: 0...100, step: 5)
            .onChange(of: goal) { NotificationCenter.default.post(name: .wanikaniToken, object: nil) }
    }
}

/// What WaniKani reports right now, so you can tell why the widget shows or not.
private struct WaniKaniStatus: View {
    @ObservedObject var wk: WaniKani

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12))
            Spacer()
            Button("Refresh") { wk.refresh() }.controlSize(.small)
        }
    }

    private var icon: String { wk.failed ? "exclamationmark.triangle.fill" : wk.connected ? "checkmark.circle.fill" : "clock" }
    private var color: Color { wk.failed ? .orange : wk.connected ? .green : .secondary }

    private var text: String {
        if wk.failed { return "Token rejected or WaniKani unreachable. Check the token." }
        if !wk.connected { return "Checking…" }
        let base = "Level \(wk.level) · \(wk.reviews) reviews waiting · lessons \(wk.lessonsToday) of \(wk.goal) today"
        return base + (wk.hasWork ? " · Showing" : " · All done, hidden")
    }
}

/// The notch's parts, each on unless turned off.
private struct NotchToggles: View {
    @AppStorage("notchAlerts") private var alerts = true
    @AppStorage("notchHUD") private var hud = true
    @AppStorage("claudeApprovals") private var approvals = true

    var body: some View {
        Toggle(isOn: $alerts) { Label("Alerts in the notch", systemImage: "rectangle.topthird.inset.filled") }
        Toggle(isOn: $hud) { Label("Volume and brightness in the notch", systemImage: "speaker.wave.2") }
        Toggle(isOn: $approvals) { Label("Allow or deny Claude Code from the notch", systemImage: "checkmark.shield") }
    }
}

/// The Shimeji characters on the Dock (Buddy.swift): on/off, which are out, their size.
private struct BuddyRows: View {
    @AppStorage("buddy") private var on = false
    @AppStorage("buddySize") private var size = 56.0
    @State private var out = BuddyRoster.paths

    var body: some View {
        Toggle(isOn: $on) { Label("Character on the Dock", systemImage: "figure.walk") }
        LabeledContent {
            HStack(spacing: 8) {
                Button("Library…") {
                    on = true
                    if Drawers.shared.anchorX == 0 { Drawers.shared.anchorX = Drawers.shared.dockCenter }
                    Drawers.shared.open = "buddy"
                }
                Button("Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.message = "Choose a Shimeji folder (the one with shime1.png, or the pack around it)"
                    if panel.runModal() == .OK, let url = panel.url, ShimejiPack.load(url.path) != nil {
                        if !BuddyRoster.paths.contains(url.path) { BuddyRoster.toggle(url.path) }
                        out = BuddyRoster.paths
                    }
                }
            }
        } label: {
            Label(out.isEmpty ? "No Shimeji character" : out.count == 1 ? (out[0] as NSString).lastPathComponent : "\(out.count) characters",
                  systemImage: "sparkles")
        }
        Slider(value: $size, in: 32...128, step: 4) { Label("Size", systemImage: "arrow.up.and.down") }
    }
}

/// Music shows the current lyric line instead of the artist (when Tide has
/// synced lyrics).
private struct LyricsToggle: View {
    @AppStorage("musicLyrics") private var on = true

    var body: some View {
        Toggle(isOn: $on) { Label("Lyrics in the music widget", systemImage: "quote.bubble") }
    }
}
