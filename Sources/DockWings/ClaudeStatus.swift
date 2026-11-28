// Claude Code widget: shows what Claude Code sessions (terminal or the Claude
// desktop app) are doing right now: thinking, running a command, editing a
// file, waiting for your permission, or done. Claude Code hooks in
// ~/.claude/settings.json run `DockWings --claude`, which main.swift turns
// into a `local.dockwings.claude` notification carrying the hook event,
// session, project folder, tool and its target, Claude's message and your
// prompt. Clicking opens a drawer with every session; clicking a session
// jumps to its chat in the Claude app.
import AppKit
import SwiftUI

enum ClaudeNotice {
    static let name = Notification.Name("local.dockwings.claude")
    /// DockWings' answer to a permission prompt, back to the waiting hook.
    static let answer = Notification.Name("local.dockwings.claude.answer")
}

@MainActor
final class ClaudeStatus: ObservableObject {
    enum State: Equatable { case working, waiting, done }

    struct Session: Equatable {
        let project: String
        var state: State
        /// What it is doing now, e.g. "Editing Wings.swift".
        var activity: String
        /// Your last prompt.
        var prompt: String
        /// When the current turn started.
        var started: Date
        var updated: Date
        /// A permission prompt DockWings can answer (its hook is waiting).
        var request: String?
    }

    /// Answers a waiting permission prompt: the `--claude` hook process that
    /// asked prints Claude Code's allow or deny and exits.
    func answer(session id: String, allow: Bool) {
        guard var s = sessions[id], let request = s.request else { return }
        DistributedNotificationCenter.default().postNotificationName(
            ClaudeNotice.answer, object: nil, userInfo: ["request": request, "allow": allow ? "1" : "0"], deliverImmediately: true)
        s.request = nil
        s.state = .working
        s.activity = allow ? "Allowed" : "Denied"
        s.updated = Date()
        sessions[id] = s
    }

    @Published private(set) var sessions: [String: Session] = [:]

    init() {
        if Config.demo == "a" {
            sessions = [
                "demo": Session(project: "my-website", state: .waiting, activity: "Wants to run: swift build",
                                prompt: "Fix the bell menu and rebuild", started: Date().addingTimeInterval(-260), updated: Date()),
                "demo2": Session(project: "dockwings", state: .working, activity: "Editing Wings.swift",
                                 prompt: "Make the widgets interactive", started: Date().addingTimeInterval(-95), updated: Date()),
            ]
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: ClaudeNotice.name, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        }
        // Finished chats you've since opened in Claude leave the widget.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropSeen() }
        }
    }

    /// Removes finished chats that were opened in the Claude app after they
    /// finished, and chats archived there. Reads the app's own session file
    /// (`lastFocusedAt`, `isArchived`); only runs while a chat is finished.
    private func dropSeen() {
        for (id, session) in sessions where session.state == .done && !notInApp.contains(id) {
            guard desktopID(for: id) != nil else { notInApp.insert(id); continue }  // a terminal chat
            // Only read a session file again once it has changed.
            guard let file = desktopFiles[id],
                  let changed = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  changed != seenDates[id] else { continue }
            seenDates[id] = changed
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let focused = (json["lastFocusedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            if focused > session.updated || json["isArchived"] as? Bool == true { sessions[id] = nil }
        }
    }

    /// The session to show: waiting beats working beats done, newest first.
    var focus: (id: String, session: Session)? {
        ordered.first.map { ($0.key, $0.value) }
    }

    var ordered: [(key: String, value: Session)] {
        let rank: (State) -> Int = { $0 == .waiting ? 2 : $0 == .working ? 1 : 0 }
        // Among running chats, the one that started first stays in front, so
        // the widget doesn't flip between chats on every step.
        return sessions.sorted { a, b in
            if rank(a.value.state) != rank(b.value.state) { return rank(a.value.state) > rank(b.value.state) }
            return a.value.state == .working ? a.value.started < b.value.started : a.value.updated > b.value.updated
        }
    }

    private func handle(_ info: [AnyHashable: Any]) {
        guard let id = info["session"] as? String, let event = info["event"] as? String else { return }
        let text = { (key: String) in info[key] as? String ?? "" }
        var session = sessions[id] ?? Session(project: text("project").isEmpty ? "Claude" : text("project"), state: .working,
                                              activity: "Thinking", prompt: "", started: Date(), updated: Date())
        if event != "Notification" { session.request = nil }
        switch event {
        case "PermissionRequest":
            session.state = .waiting
            session.activity = Self.asks(tool: text("tool"), detail: text("detail"))
            session.request = text("request").isEmpty ? nil : text("request")
            // The hook stops waiting after a while; Allow / Deny go with it.
            let request = session.request
            DispatchQueue.main.asyncAfter(deadline: .now() + ClaudeHooks.permissionWait) {
                if let request, self.sessions[id]?.request == request { self.sessions[id]?.request = nil }
            }
        case "UserPromptSubmit":
            session.state = .working
            session.activity = "Thinking"
            session.prompt = text("prompt")
            session.started = Date()
        case "PreToolUse":
            session.state = .working
            session.activity = Self.describe(tool: text("tool"), detail: text("detail"))
        case "Notification":
            session.state = .waiting
            session.activity = text("message").isEmpty ? "Needs you" : text("message")
        case "Stop":
            session.state = .done
            NotificationCenter.default.post(name: .breakMoment, object: nil)
            session.activity = "Done in " + Self.duration(Date().timeIntervalSince(session.started))
        case "SessionEnd":
            sessions[id] = nil
            return
        default:
            return
        }
        session.updated = Date()
        sessions[id] = session
        if session.state == .done {
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                if self.sessions[id]?.state == .done { self.sessions[id] = nil }
            }
        }
    }

    /// What a permission prompt asks, e.g. "Wants to run: swift build".
    private static func asks(tool: String, detail: String) -> String {
        let target = detail.split(separator: "\n").first.map(String.init) ?? ""
        switch tool {
        case "AskUserQuestion": return target.isEmpty ? "Has a question" : "Asks: " + target
        case "ExitPlanMode": return "Wants you to review a plan"
        case "Bash": return "Wants to run: " + target
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Wants to edit " + target
        case "WebFetch": return "Wants to open " + target
        default: return "Wants to use " + (tool.hasPrefix("mcp__") ? String(tool.split(separator: "_").last ?? "") : tool)
        }
    }

    private static func describe(tool: String, detail: String) -> String {
        let target = detail.split(separator: "\n").first.map(String.init) ?? ""
        switch tool {
        case "Bash": return "Running " + target
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing " + target
        case "Read": return "Reading " + target
        case "Grep", "Glob": return "Searching " + target
        case "WebFetch", "WebSearch": return "Looking online"
        case "Task", "Agent": return "Running a helper"
        case "TodoWrite": return "Planning"
        default: return tool.hasPrefix("mcp__") ? "Using " + (tool.split(separator: "__").dropFirst().first.map(String.init) ?? "a tool") : tool
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    func clear() { sessions = [:] }

    func open() {
        Drawers.shared.open = nil
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// Jumps to that session's chat in the Claude app with its own deep link,
    /// `claude://code/continue?session=local_…`. Hooks report the Claude Code
    /// id; the app keeps a JSON file per session (under Application
    /// Support/Claude/claude-code-sessions) holding both ids. Sessions the app
    /// doesn't know (plain terminal ones) just open Claude.
    func open(session id: String) {
        Drawers.shared.open = nil
        guard let local = desktopID(for: id), let url = URL(string: "claude://code/continue?session=\(local)") else { return open() }
        NSWorkspace.shared.open(url)
    }

    private var desktopIDs: [String: String] = [:]
    private var desktopFiles: [String: URL] = [:]
    private var seenDates: [String: Date] = [:]
    private var notInApp: Set<String> = []

    private func desktopID(for cliID: String) -> String? {
        if let known = desktopIDs[cliID] { return known }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        // Newest first: the session you're asking about is usually recent.
        let candidates = files.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        let needle = Data(cliID.utf8)
        for file in candidates {
            guard let data = try? Data(contentsOf: file), data.range(of: needle) != nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["cliSessionId"] as? String == cliID,
                  let local = json["sessionId"] as? String else { continue }
            desktopIDs[cliID] = local
            desktopFiles[cliID] = file
            return local
        }
        return nil
    }
}

struct ClaudeView: View {
    @ObservedObject var claude: ClaudeStatus
    /// Mark only, when the wing is short of room.
    var compact = false
    /// Width of the text: grows at once for longer text, shrinks only after
    /// the text has stayed shorter for a while, so the widget neither jumps
    /// on every step nor keeps a big gap.
    @State private var textWidth: CGFloat = 0
    @State private var shrinkAt: Date?
    @State private var natural: CGFloat = 0

    var body: some View {
        if let (id, session) = claude.focus {
            // Waiting for you: go straight to that chat. Otherwise the drawer.
            Button {
                if session.state == .waiting { claude.open(session: id) } else { Drawers.shared.toggle("claude") }
            } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        ClaudeMark(state: session.state, activity: session.activity, seed: id)
                        if claude.sessions.count > 1 {
                            Text("\(claude.sessions.count)")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 15, height: 15).background(Circle().fill(Color(white: 0.3)))
                                .offset(x: 5, y: -3)
                                .transition(.scale)
                        }
                    }
                    if !compact {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.project).font(.system(size: 14, weight: .semibold))
                            Text(session.activity).font(.system(size: 12))
                                .foregroundStyle(session.state == .waiting ? AnyShapeStyle(Color(red: 1, green: 0.72, blue: 0.55)) : AnyShapeStyle(ink(0.6)))
                                .modifier(Shimmer(on: session.state == .working))
                                .id(session.activity)
                                .transition(.blurReplace)
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: textWidth > 0 ? textWidth : nil, alignment: .leading)
                        .background(alignment: .leading) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.project).font(.system(size: 14, weight: .semibold))
                                Text(session.activity).font(.system(size: 12))
                            }
                            .fixedSize()
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { ceil(min($0.size.width, 170)) } action: { fit($0) }
                        }
                    }
                }
            }
            .buttonStyle(WidgetPress())
            .contextMenu {
                Button("Open Chat") { claude.open(session: id) }
                Button("All Sessions") { Drawers.shared.toggle("claude") }
                Button("Open Claude") { claude.open() }
                Button("Clear") { claude.clear() }
            }
            .id(id)
            .animation(.spring(duration: 0.4, bounce: 0.15), value: session.activity)
            .animation(.spring(duration: 0.4, bounce: 0.2), value: claude.sessions.count)
        }
    }

    private func fit(_ width: CGFloat) {
        natural = width
        if width >= textWidth {
            shrinkAt = nil
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { textWidth = width }
        } else if shrinkAt == nil {
            let due = Date().addingTimeInterval(20)
            shrinkAt = due
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                guard shrinkAt == due else { return }
                shrinkAt = nil
                withAnimation(.spring(duration: 0.5, bounce: 0.1)) { textWidth = natural }
            }
        }
    }
}

/// Drawer content: every session with its state, activity, your last prompt
/// and how long the turn has been running.
struct ClaudeSessions: View {
    @ObservedObject var claude: ClaudeStatus

    private var list: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                    ForEach(claude.ordered, id: \.key) { id, s in
                        Button { claude.open(session: id) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            ClaudeMark(state: s.state, activity: s.activity, seed: id).scaleEffect(0.8).frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(s.project).font(.system(size: 13, weight: .semibold))
                                    Spacer(minLength: 12)
                                    Text(s.state == .done ? ago(s.updated) : ClaudeStatus.duration(Date().timeIntervalSince(s.started)))
                                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text(s.activity).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(s.state == .waiting ? Color(red: 1, green: 0.72, blue: 0.55) : .primary.opacity(0.85))
                                    .lineLimit(2)
                                if !s.prompt.isEmpty {
                                    Text("\u{201C}\(s.prompt)\u{201D}").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRow())
                        .help("Open this chat")
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        if s.request != nil {
                            ApprovalButtons(allow: { claude.answer(session: id, allow: true) }, deny: { claude.answer(session: id, allow: false) })
                                .padding(.leading, 52).padding(.bottom, 6)
                        }
                    }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Too many sessions for the drawer's room: the list scrolls.
            ViewThatFits(in: .vertical) {
                list
                ScrollView { list }.frame(height: 320).scrollIndicators(.never)
            }
            .frame(maxHeight: 320)
            Divider().padding(.horizontal, 10)
            HStack {
                Button("Clear") { claude.clear(); Drawers.shared.open = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Open Claude") { claude.open() }.buttonStyle(.plain).fontWeight(.semibold)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .padding(6)
        .frame(width: 340)
        .card()
        .animation(.spring(duration: 0.4, bounce: 0.15), value: claude.sessions)
    }
}

/// Claude's mark, animated by what Claude is doing, the way the Claude app
/// does. Each activity has several animations (reading: dots in a few
/// styles; running: glyph morph, chasing dashes, sonar rings, a turning
/// spark; editing: lines, a typing caret, a squiggle, a filling grid;
/// thinking: the spark in five moods), and every chat switches between them
/// every 10 to 16 seconds on its own clock, so no two look the same for long.
/// Waiting for you: the spark breathes or sways with a warm glow. Done: a
/// small pop and a check. The motion runs as Core Animation in the system's
/// render server, so it stays smooth and costs the app next to nothing.
struct ClaudeMark: View {
    let state: ClaudeStatus.State
    var activity = ""
    var seed = ""
    /// The green check badge when done (the notch draws its own).
    var badge = true
    static let orange = Color(red: 0.85, green: 0.47, blue: 0.34)

    enum Kind { case spark, dots, spinner, writing, waiting, done }

    private var kind: Kind {
        switch state {
        case .waiting: return .waiting
        case .done: return .done
        case .working:
            switch activity.split(separator: " ").first.map(String.init) ?? "" {
            case "Reading", "Searching", "Looking": return .dots
            case "Running", "Using": return .spinner
            case "Editing", "Planning": return .writing
            default: return .spark
            }
        }
    }

    /// Which of the kind's animations shows now: changes every 10 to 16 s,
    /// on a different clock for every chat.
    private func variant(at date: Date) -> Int {
        let count = MarkLayer.variants(kind)
        guard count > 1 else { return 0 }
        let h = abs(seed.hashValue)
        let period = Double(10 + h % 7)
        let slot = Int((date.timeIntervalSinceReferenceDate + Double(h % 97)) / period)
        return (h / 7 + slot) % count
    }

    /// Ticks only when the variant can change (every 10 to 16 s), not every
    /// second: each tick redraws the wing.
    private var schedule: PeriodicTimelineSchedule {
        let h = abs(seed.hashValue)
        let period = Double(10 + h % 7), offset = Double(h % 97)
        let now = Date().timeIntervalSinceReferenceDate
        let start = ((now + offset) / period).rounded(.down) * period - offset
        return .periodic(from: Date(timeIntervalSinceReferenceDate: start), by: period)
    }

    var body: some View {
        TimelineView(schedule) { context in
            let v = variant(at: context.date.addingTimeInterval(0.01))
            ZStack {
                MarkLayer(kind: kind, variant: v, seed: seed)
                    .frame(width: 34, height: 34)
                    .id("\(kind)\(v)")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                if state == .done && badge {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, Color(red: 0.2, green: 0.7, blue: 0.4))
                        .offset(x: 12, y: 11)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 34, height: 34)
            .animation(.spring(duration: 0.4, bounce: 0.2), value: "\(kind)\(v)")
        }
        .keyframeAnimator(initialValue: 1.0, trigger: state) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(0.85, duration: 0.12)
            SpringKeyframe(1, duration: 0.5, spring: .bouncy)
        }
    }
}

/// The layers behind ClaudeMark. Built once per kind and variant; the
/// animations then loop on their own without the app redrawing anything.
private struct MarkLayer: NSViewRepresentable {
    let kind: ClaudeMark.Kind
    let variant: Int
    let seed: String

    static func variants(_ kind: ClaudeMark.Kind) -> Int {
        switch kind {
        case .spark: return 5
        case .dots, .spinner, .writing: return 4
        case .waiting: return 2
        case .done: return 1
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        view.wantsLayer = true
        let root = CALayer()
        root.frame = view.bounds
        view.layer?.addSublayer(root)
        // Same chat, same timing; different chats, different moments.
        root.timeOffset = Double(abs(seed.hashValue % 1000)) / 137
        build(in: root)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private static let orange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor
    private static let faint = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 0.2).cgColor
    private static let lengths: [CGFloat] = [1, 0.82, 0.95, 0.78, 0.9, 0.85, 1, 0.8, 0.92, 0.76, 0.88, 0.84]
    private static let angles: [CGFloat] = [0, 4, -3, 2, -5, 3, -2, 5, -4, 1, -3, 4]
    private let c = CGPoint(x: 17, y: 17)

    private static func loop(_ path: String, from: Any, to: Any, duration: Double, offset: Double = 0,
                             reverses: Bool = true) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: path)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.autoreverses = reverses
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: reverses ? .easeInEaseOut : .linear)
        a.timeOffset = offset
        return fullRate(a)
    }

    private static func keyframes(_ path: String, _ values: [Any], _ times: [Double], duration: Double,
                                  offset: Double = 0) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: path)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.duration = duration
        a.repeatCount = .infinity
        a.timeOffset = offset
        return fullRate(a)
    }

    private func spin(_ layer: CALayer, seconds: Double) {
        layer.add(Self.loop("transform.rotation.z", from: 0, to: -2 * Double.pi, duration: seconds, reverses: false), forKey: "spin")
    }

    private func circle(_ d: CGFloat, at p: CGPoint, color: CGColor = MarkLayer.orange) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
        l.fillColor = color
        l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        l.position = p
        return l
    }

    private func bar(_ rect: CGRect, color: CGColor = MarkLayer.orange) -> CALayer {
        let l = CALayer()
        l.frame = rect
        l.cornerRadius = min(rect.width, rect.height) / 2
        l.backgroundColor = color
        return l
    }

    /// Claude's spark: twelve tapered rays of uneven length round a hub.
    /// Returns the spark layer and its rays (each scales along its length).
    private func spark(in root: CALayer, radius r: CGFloat = 14) -> (CALayer, [CAShapeLayer]) {
        let spark = CALayer()
        spark.frame = root.bounds
        root.addSublayer(spark)
        var rays: [CAShapeLayer] = []
        for i in Self.lengths.indices {
            let holder = CALayer()
            holder.frame = spark.bounds
            holder.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(i) / 12 * 2 * .pi + Self.angles[i] * .pi / 180))
            spark.addSublayer(holder)
            let len = r * Self.lengths[i], base = r * 0.12, tip = r * 0.07
            let ray = CAShapeLayer()
            ray.anchorPoint = CGPoint(x: 0, y: 0.5)
            ray.bounds = CGRect(x: 0, y: -base, width: len, height: base * 2)
            ray.position = c
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: base))
            path.addLine(to: CGPoint(x: len - tip, y: tip))
            path.addArc(center: CGPoint(x: len - tip, y: 0), radius: tip, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
            path.addLine(to: CGPoint(x: 0, y: -base))
            path.closeSubpath()
            ray.path = path
            ray.fillColor = Self.orange
            holder.addSublayer(ray)
            rays.append(ray)
        }
        spark.addSublayer(circle(r * 0.32, at: c))
        return (spark, rays)
    }

    private static let glyphs = ["\u{00B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}", "\u{273B}", "\u{2736}", "\u{2733}", "\u{2722}"]

    private func glyph(_ text: String, size: CGFloat = 26) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold),
                                                         .foregroundColor: NSColor(cgColor: Self.orange)!]
        return NSImage(size: NSSize(width: 34, height: 34), flipped: false) { rect in
            let s = NSAttributedString(string: text, attributes: attributes)
            let size = s.size()
            s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }

    private func build(in root: CALayer) {
        switch (kind, variant) {
        // Thinking: the spark in five moods.
        case (.spark, 0): // rays ripple, slow turn
            let (s, rays) = spark(in: root)
            for (i, ray) in rays.enumerated() {
                ray.add(Self.loop("transform.scale.x", from: 0.72, to: 1, duration: 0.78, offset: Double(i) * 0.53), forKey: "a")
            }
            spin(s, seconds: 18)
        case (.spark, 1): // a wave travels round the rays
            let (_, rays) = spark(in: root)
            for (i, ray) in rays.enumerated() {
                ray.add(Self.loop("transform.scale.x", from: 0.5, to: 1, duration: 0.6, offset: Double(i) / 12 * 1.2), forKey: "a")
            }
        case (.spark, 2): // rays light up in turn, like a chase
            let (s, rays) = spark(in: root)
            for (i, ray) in rays.enumerated() {
                ray.add(Self.loop("opacity", from: 1, to: 0.2, duration: 0.55, offset: Double(i) / 12 * 1.1), forKey: "a")
            }
            spin(s, seconds: 30)
        case (.spark, 3): // ticks round in steps, settling each time
            let (s, _) = spark(in: root)
            let steps = 12
            let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            turn.values = (0...steps).map { -Double($0) / Double(steps) * 2 * .pi }
            turn.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.6, 0, 0.2, 1), count: steps)
            turn.duration = Double(steps) * 0.5
            turn.repeatCount = .infinity
            s.add(fullRate(turn), forKey: "a")
        case (.spark, 4): // blooms open and closes with a twist
            let (s, _) = spark(in: root)
            s.add(Self.loop("transform.scale", from: 0.55, to: 1.05, duration: 0.9), forKey: "a")
            s.add(Self.loop("transform.rotation.z", from: 0, to: -Double.pi / 3, duration: 0.9), forKey: "b")

        // Reading and searching.
        case (.dots, 0): // dots hop in a wave
            for i in 0..<3 {
                let dot = circle(6, at: CGPoint(x: c.x - 10 + CGFloat(i) * 10, y: c.y))
                root.addSublayer(dot)
                let o = 1.05 - Double(i) * 0.15
                dot.add(Self.loop("position.y", from: c.y, to: c.y + 3, duration: 0.52, offset: o), forKey: "a")
                dot.add(Self.loop("opacity", from: 0.45, to: 1, duration: 0.52, offset: o), forKey: "b")
            }
        case (.dots, 1): // dots swell one after another
            for i in 0..<3 {
                let dot = circle(6, at: CGPoint(x: c.x - 10 + CGFloat(i) * 10, y: c.y))
                root.addSublayer(dot)
                dot.add(Self.loop("transform.scale", from: 0.5, to: 1.25, duration: 0.45, offset: 0.9 - Double(i) * 0.15), forKey: "a")
            }
        case (.dots, 2): // dots circle round each other
            let ring = CALayer()
            ring.frame = root.bounds
            root.addSublayer(ring)
            for i in 0..<3 {
                let a = Double(i) / 3 * 2 * .pi
                let dot = circle(5.5, at: CGPoint(x: c.x + 8 * cos(a), y: c.y + 8 * sin(a)))
                ring.addSublayer(dot)
                dot.add(Self.loop("transform.scale", from: 0.7, to: 1.15, duration: 0.5, offset: Double(i) * 0.33), forKey: "a")
            }
            spin(ring, seconds: 1.6)
        case (.dots, 3): // a dot reads along a line
            root.addSublayer(bar(CGRect(x: c.x - 12, y: c.y - 6, width: 24, height: 2), color: Self.faint))
            root.addSublayer(bar(CGRect(x: c.x - 12, y: c.y + 4, width: 16, height: 2), color: Self.faint))
            let dot = circle(6, at: CGPoint(x: c.x - 9, y: c.y - 1))
            root.addSublayer(dot)
            dot.add(Self.keyframes("position.x", [c.x - 9, c.x + 9, c.x + 9, c.x - 9, c.x - 9], [0, 0.4, 0.5, 0.9, 1], duration: 1.6), forKey: "a")

        // Running a command or a tool.
        case (.spinner, 0): // Claude Code's glyphs morphing into each other
            let images = Self.glyphs.map { glyph($0) }
            let layer = CALayer()
            layer.frame = root.bounds
            layer.contents = images[0]
            root.addSublayer(layer)
            let cycle = CAKeyframeAnimation(keyPath: "contents")
            cycle.values = images + [images[0]]
            cycle.calculationMode = .linear
            cycle.duration = Double(images.count) / 7
            cycle.repeatCount = .infinity
            layer.add(fullRate(cycle), forKey: "a")
            layer.add(Self.loop("transform.rotation.z", from: -0.14, to: 0.14, duration: 1.2), forKey: "b")
        case (.spinner, 1): // dashes round a circle, chasing
            for i in 0..<8 {
                let holder = CALayer()
                holder.frame = root.bounds
                holder.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(i) / 8 * 2 * .pi))
                root.addSublayer(holder)
                let dash = bar(CGRect(x: c.x + 5, y: c.y - 1.5, width: 7, height: 3))
                holder.addSublayer(dash)
                dash.add(Self.keyframes("opacity", [1, 0.15, 0.15], [0, 0.6, 1], duration: 0.8, offset: Double(8 - i) / 8 * 0.8), forKey: "a")
            }
        case (.spinner, 2): // sonar rings around a dot
            root.addSublayer(circle(7, at: c))
            for i in 0..<2 {
                let ring = CAShapeLayer()
                ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 28, height: 28), transform: nil)
                ring.fillColor = nil
                ring.strokeColor = Self.orange
                ring.lineWidth = 2
                ring.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
                ring.position = c
                root.addSublayer(ring)
                let group = CAAnimationGroup()
                group.animations = [Self.loop("transform.scale", from: 0.25, to: 1, duration: 1.4, reverses: false),
                                    Self.loop("opacity", from: 1, to: 0, duration: 1.4, reverses: false)]
                group.duration = 1.4
                group.repeatCount = .infinity
                group.timeOffset = Double(i) * 0.7
                ring.add(fullRate(group), forKey: "a")
            }
        case (.spinner, 3): // a spark glyph turning and pulsing
            let layer = CALayer()
            layer.frame = root.bounds
            layer.contents = glyph("\u{273B}", size: 28)
            root.addSublayer(layer)
            spin(layer, seconds: 2.4)
            let pulse = CALayer()
            pulse.frame = root.bounds
            root.addSublayer(pulse)
            layer.removeFromSuperlayer()
            pulse.addSublayer(layer)
            pulse.add(Self.loop("transform.scale", from: 0.8, to: 1.05, duration: 0.6), forKey: "b")

        // Editing and planning.
        case (.writing, 0): // three lines write themselves
            for i in 0..<3 {
                let width: CGFloat = i == 2 ? 13 : 20
                let frame = CGRect(x: c.x - 10, y: c.y + 7 - CGFloat(i) * 7 - 1.5, width: width, height: 3)
                root.addSublayer(bar(frame, color: Self.faint))
                let fill = bar(frame)
                fill.anchorPoint = CGPoint(x: 0, y: 0.5)
                fill.frame = frame
                root.addSublayer(fill)
                let start = Double(i) * 0.25
                fill.add(Self.keyframes("transform.scale.x", [0, 0, 1, 1, 0], [0, start, start + 0.25, 0.92, 1], duration: 1.8), forKey: "a")
            }
        case (.writing, 1): // a line types out behind a blinking caret
            let frame = CGRect(x: c.x - 11, y: c.y - 1.5, width: 18, height: 3)
            let fill = bar(frame)
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            fill.frame = frame
            root.addSublayer(fill)
            let times: [Double] = [0, 0.75, 0.9, 1]
            fill.add(Self.keyframes("transform.scale.x", [0.05, 1, 1, 0.05], times, duration: 2), forKey: "a")
            let caret = bar(CGRect(x: 0, y: 0, width: 2.5, height: 12))
            caret.position = CGPoint(x: frame.minX + 2, y: c.y)
            root.addSublayer(caret)
            caret.add(Self.keyframes("position.x", [frame.minX + 2, frame.maxX + 3, frame.maxX + 3, frame.minX + 2], times, duration: 2), forKey: "a")
            caret.add(Self.keyframes("opacity", [1, 1, 0, 0, 1], [0, 0.5, 0.51, 0.99, 1], duration: 0.5), forKey: "b")
        case (.writing, 2): // a pen squiggle drawn, then wiped
            let path = CGMutablePath()
            path.move(to: CGPoint(x: c.x - 12, y: c.y))
            for k in 0..<4 {
                let x = c.x - 12 + CGFloat(k) * 6
                path.addCurve(to: CGPoint(x: x + 6, y: c.y), control1: CGPoint(x: x + 2, y: c.y + (k % 2 == 0 ? 8 : -8)),
                              control2: CGPoint(x: x + 4, y: c.y + (k % 2 == 0 ? 8 : -8)))
            }
            let line = CAShapeLayer()
            line.path = path
            line.fillColor = nil
            line.strokeColor = Self.orange
            line.lineWidth = 2.5
            line.lineCap = .round
            line.frame = root.bounds
            root.addSublayer(line)
            line.add(Self.keyframes("strokeEnd", [0, 1, 1, 1], [0, 0.45, 0.55, 1], duration: 2), forKey: "a")
            line.add(Self.keyframes("strokeStart", [0, 0, 0, 1], [0, 0.45, 0.55, 1], duration: 2), forKey: "b")
        case (.writing, 3): // a little grid filling cell by cell
            for i in 0..<9 {
                let cell = bar(CGRect(x: c.x - 9.5 + CGFloat(i % 3) * 7, y: c.y + 4.5 - CGFloat(i / 3) * 7, width: 5, height: 5))
                cell.cornerRadius = 1.5
                root.addSublayer(cell)
                let t = Double(i) / 9 * 0.7
                cell.add(Self.keyframes("opacity", [0.15, 0.15, 1, 1, 0.15], [0, t, t + 0.05, 0.9, 1], duration: 2.2), forKey: "a")
            }

        // Waiting for you.
        case (.waiting, 0): // breathes with a glow
            let (s, _) = spark(in: root)
            glow(s)
            s.add(Self.loop("transform.scale", from: 0.88, to: 1.04, duration: 0.9), forKey: "a")
        case (.waiting, _): // sways side to side with a glow
            let (s, _) = spark(in: root)
            glow(s)
            s.add(Self.loop("transform.rotation.z", from: -0.3, to: 0.3, duration: 1.1), forKey: "a")
        default: // done
            _ = spark(in: root)
        }
    }

    private func glow(_ layer: CALayer) {
        layer.shadowColor = Self.orange
        layer.shadowRadius = 7
        layer.shadowOffset = .zero
        layer.add(Self.loop("shadowOpacity", from: 0.1, to: 0.7, duration: 0.9), forKey: "glow")
    }
}

/// The light sweep Claude Code runs across its status text while working.
/// The moving band is a Core Animation gradient, masked to the text.
struct Shimmer: ViewModifier {
    let on: Bool
    @Environment(\.ambient) private var ambient

    func body(content: Content) -> some View {
        if on && ambient {
            content.overlay { SweepLayer().mask(content) }
        } else {
            content
        }
    }
}

private struct SweepLayer: NSViewRepresentable {
    final class SweepView: NSView {
        let band = CAGradientLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let warm = NSColor(red: 1, green: 0.8, blue: 0.68, alpha: 1).cgColor
            band.colors = [NSColor.clear.cgColor, warm, NSColor.clear.cgColor]
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.addSublayer(band)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let width = max(bounds.width, 40), bandWidth = width * 0.5
            band.removeAllAnimations()
            band.frame = CGRect(x: -bandWidth, y: 0, width: bandWidth, height: bounds.height)
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -bandWidth / 2
            sweep.toValue = width + bandWidth * 1.5
            sweep.duration = 2.2
            sweep.repeatCount = .infinity
            band.add(fullRate(sweep), forKey: "sweep")
        }
    }

    func makeNSView(context: Context) -> SweepView { SweepView(frame: .zero) }
    func updateNSView(_ view: SweepView, context: Context) {}
}

/// Allow / Deny for a Claude permission prompt (the drawer and the notch).
struct ApprovalButtons: View {
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: deny) { Text("Deny").frame(minWidth: 52) }
                .buttonStyle(ApprovalStyle(prominent: false))
            Button(action: allow) { Text("Allow").frame(minWidth: 52) }
                .buttonStyle(ApprovalStyle(prominent: true))
        }
    }
}

private struct ApprovalStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.vertical, 5).padding(.horizontal, 10)
            .foregroundStyle(prominent ? .black : .white)
            .background(prominent ? Color(red: 0.85, green: 0.47, blue: 0.34) : .white.opacity(0.14), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
    }
}
