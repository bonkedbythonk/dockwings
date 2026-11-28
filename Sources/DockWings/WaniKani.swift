// WaniKani widget: shows while there is work for today: every review that is
// waiting, and lessons up to your daily lesson amount (Settings, default 15,
// the same as WaniKani's standard). The ring is today's lessons. Reads the official WaniKani API v2 (/summary and /user)
// with a read-only personal access token you paste into Settings; the token
// lives in the macOS Keychain. Refreshes every minute, when you switch apps,
// and right after each full hour (reviews unlock on the hour). With nothing to do it stays
// as a quiet widget: a known kanji or word (Guru or higher, sampled daily) and the next
// wave of reviews. A level-up flashes the tile gold for a minute. Clicking opens a drawer
// with level progress (90% of the level's kanji passed), the review forecast, your worst
// leeches and buttons to start studying. Reviews run inside the drawer
// (WaniKaniReview.swift); lessons open the site, and while you do them the
// notch shows a WaniKani tile and today's lessons (also over a full-screen
// browser; until none are left, or 20 minutes without a new one). Reviews in
// the drawer show the tile with their progress the same way. Meanwhile the
// wing leaves the widget out; a click on the notch opens the drawer.
import AppKit
import Combine
import Security
import SwiftUI

/// The WaniKani token in the login Keychain.
enum WaniKaniToken {
    private static let service = "DockWings WaniKani"

    static func load() -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
final class WaniKani: ObservableObject {
    static let shared = WaniKani()

    @Published private(set) var reviews = 0
    @Published private(set) var lessons = 0
    @Published private(set) var level = 0
    @Published private(set) var nextReviews: Date?
    /// Reviews unlocking in each of the next hours (hour start, count).
    @Published private(set) var forecast: [(hour: Date, count: Int)] = []
    @Published private(set) var connected = false
    /// Reviews finished today (items reviewed since midnight, not counting
    /// today's new lessons).
    @Published private(set) var doneToday = 0
    /// Lessons finished today (items started since midnight).
    @Published private(set) var lessonsToday = 0
    /// Lessons per day, set in Settings (WaniKani's API doesn't share the
    /// daily limit set on the site).
    var goal: Int { max(0, UserDefaults.standard.object(forKey: "wkGoal") as? Int ?? 15) }
    /// Lessons still to do today: up to the daily amount, if available.
    var lessonsLeft: Int { max(0, min(goal - lessonsToday, lessons)) }
    /// Anything to do today: all waiting reviews, or lessons left.
    var hasWork: Bool { reviews > 0 || lessonsLeft > 0 }
    @Published private(set) var failed = false
    /// Kanji of the current level passed (Guru once) and how many there are;
    /// leveling up needs 90% of them.
    @Published private(set) var levelPassed = 0
    @Published private(set) var levelTotal = 0
    var levelNeed: Int { Int((Double(levelTotal) * 0.9).rounded(.up)) }
    /// Items you get wrong most, for the drawer.
    @Published private(set) var leeches: [WKLeech] = []
    /// A known item shown while there is nothing to do, changed every 5 min.
    @Published private(set) var idleWord: WKItem?
    /// For a minute after a level-up the widget shows it with a gold burst.
    @Published private(set) var celebrating = false
    /// A review session is open in the drawer: the widget stays on the first page.
    @Published private(set) var reviewing = false
    func setReviewing(_ on: Bool) {
        if reviewing != on { reviewing = on }
        if !on, reviewsShown != nil { reviewsShown = nil; Notch.shared.clear("wk-reviews") }
    }
    private var reviewsShown: String? { didSet { syncInNotch() } }
    /// The notch shows the tile (reviews or lessons): the wing leaves it out.
    /// Only while it is the notch's current alert: queued behind the music,
    /// it would be in neither place.
    @Published private(set) var inNotch = false
    private var notchFeed: AnyCancellable?
    private func syncInNotch() {
        let on = (reviewsShown != nil || lessonsShown != nil) && Notch.alertsOn && Notch.locate() != nil
            && Notch.shared.alert?.id.hasPrefix("wk-") == true
        if inNotch != on { inNotch = on }
    }

    /// The notch during a review in the drawer: the tile left of the camera,
    /// reviews done right of it; gone once the finished screen shows (the
    /// last right answer still waits for Return).
    func showReviews(done: Int, of total: Int, over: Bool) {
        guard reviewing, total > 0, !over else {
            if reviewsShown != nil { reviewsShown = nil; Notch.shared.clear("wk-reviews") }
            return
        }
        let count = "\(done)/\(total)"
        guard count != reviewsShown else { return }
        let first = reviewsShown == nil
        reviewsShown = count
        Notch.shared.post(NotchAlert(id: "wk-reviews", icon: .image(Self.tile), trailing: .text(count, .white.opacity(0.7)),
                                     title: "WaniKani reviews", subtitle: "\(total - done) left", duration: 0,
                                     tapOpens: !Config.bar, action: { Drawers.shared.toggle("wanikani") }))
        // Dock bar: reviews happen at the top of the screen, in the notch
        // grown into the WaniKani panel (easier on the eyes than the Dock).
        if Config.bar, first {
            if Drawers.shared.open == "wanikani" { Drawers.shared.open = nil }
            withAnimation(.smooth(duration: 0.34)) { Notch.shared.expanded = true }
        }
    }
    @Published private(set) var reviewTile = WKReviewTile(characters: nil, type: "", progress: 0)
    func setReviewTile(_ tile: WKReviewTile) { if reviewTile != tile { reviewTile = tile } }
    /// The next hour with reviews coming.
    var nextWave: (hour: Date, count: Int)? { forecast.first { $0.count > 0 } }
    /// Sample of Guru-or-higher kanji and vocabulary, refreshed daily on disk.
    private var pool: [WKItem] = []
    private var detailsAt = Date.distantPast
    private static let poolFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DockWings/wanikani-known.json")
    /// For a short while after a natural pause (a Claude chat finished, music
    /// paused, new reviews unlocked) the widget moves up to the first page.
    @Published private(set) var nudging = false
    private var nudgeTimer: Timer?

    func nudge() {
        guard hasWork else { return }
        nudging = true
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudging = false }
        }
    }

    init() {
        DispatchQueue.main.async {
            self.notchFeed = Notch.shared.$alert.sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncInNotch() }
            }
        }
        if Config.demo == "a" {
            reviews = 42; lessons = 5; level = 7; connected = true; doneToday = 6
            let hour = Calendar.current.dateInterval(of: .hour, for: Date())!.start
            forecast = [3, 0, 12, 7, 0, 0, 18, 4].enumerated().map { (hour.addingTimeInterval(Double($0.offset + 1) * 3600), $0.element) }
            levelPassed = 23; levelTotal = 31
            leeches = [WKLeech(item: WKItem(characters: "未", meaning: "Not Yet", reading: "み", kanji: true), incorrect: 14, percent: 58),
                       WKLeech(item: WKItem(characters: "末", meaning: "End", reading: "まつ", kanji: true), incorrect: 11, percent: 61),
                       WKLeech(item: WKItem(characters: "大人", meaning: "Adult", reading: "おとな", kanji: false), incorrect: 9, percent: 66)]
            return
        }
        if Config.demo == "b" {
            level = 8; connected = true; doneToday = 54; lessonsToday = goal
            let hour = Calendar.current.dateInterval(of: .hour, for: Date())!.start
            forecast = [0, 0, 18, 7].enumerated().map { (hour.addingTimeInterval(Double($0.offset + 1) * 3600), $0.element) }
            pool = [WKItem(characters: "火", meaning: "Fire", reading: "ひ", kanji: true),
                    WKItem(characters: "火山", meaning: "Volcano", reading: "かざん", kanji: false),
                    WKItem(characters: "一人", meaning: "Alone, One Person", reading: "ひとり", kanji: false)]
            rotate()
            celebrate()
            startRotation()
            return
        }
        pool = (try? JSONDecoder().decode([WKItem].self, from: Data(contentsOf: Self.poolFile))) ?? []
        rotate()
        startRotation()
        refresh()
        NotificationCenter.default.addObserver(forName: .wanikaniToken, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Switching apps (e.g. leaving the browser after a review session)
        // refreshes right away, at most every 10 s.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastRefresh) > 10 else { return }
                self.refresh()
            }
        }
        scheduleOnTheHour()
        NotificationCenter.default.addObserver(forName: .breakMoment, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudge() }
        }
    }

    /// Reviews unlock at :00, so refresh a few seconds after each hour too.
    private func scheduleOnTheHour() {
        let next = Calendar.current.dateInterval(of: .hour, for: Date())!.end.addingTimeInterval(5)
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSinceNow) { [weak self] in
            self?.refresh()
            self?.scheduleOnTheHour()
        }
    }

    private var lastRefresh = Date.distantPast

    func refresh() {
        lastRefresh = Date()
        guard let token = WaniKaniToken.load() else {
            connected = false
            return
        }
        Task {
            async let summary = Self.get("summary", token)
            async let user = Self.get("user", token)
            guard let s = await summary?["data"] as? [String: Any] else {
                failed = true
                connected = false
                return
            }
            failed = false
            connected = true
            let now = Date()
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func date(_ any: Any?) -> Date? {
                guard let text = any as? String else { return nil }
                return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            }
            let reviewGroups = (s["reviews"] as? [[String: Any]] ?? []).compactMap { group -> (Date, Int)? in
                guard let at = date(group["available_at"]) else { return nil }
                return (at, (group["subject_ids"] as? [Any])?.count ?? 0)
            }
            let waiting = reviewGroups.filter { $0.0 <= now }.reduce(0) { $0 + $1.1 }
            let unlocked = waiting > reviews
            reviews = waiting
            forecast = reviewGroups.filter { $0.0 > now }.prefix(12).map { (hour: $0.0, count: $0.1) }
            lessons = (s["lessons"] as? [[String: Any]] ?? []).filter { (date($0["available_at"]) ?? now) <= now }
                .reduce(0) { $0 + ((($1["subject_ids"] as? [Any])?.count) ?? 0) }
            nextReviews = date(s["next_reviews_at"])
            if let u = await user?["data"] as? [String: Any], let lvl = u["level"] as? Int, lvl != level {
                let stored = UserDefaults.standard.integer(forKey: "wkLastLevel")
                if stored > 0 && lvl > stored { celebrate() }
                UserDefaults.standard.set(lvl, forKey: "wkLastLevel")
                level = lvl
                detailsAt = .distantPast
            }
            refreshDetails()
            // Every finished review updates its assignment, so count today's
            // updates, leaving out items you started (lessons) today.
            let midnight = Calendar.current.startOfDay(for: now)
            let since = ISO8601DateFormatter().string(from: midnight)
            var done = 0, learned = 0
            var path: String? = "assignments?updated_after=\(since)"
            while let page = path, let json = await Self.get(page, token) {
                for item in json["data"] as? [[String: Any]] ?? [] {
                    let d = item["data"] as? [String: Any] ?? [:]
                    if let started = date(d["started_at"]) {
                        if started < midnight { done += 1 } else { learned += 1 }
                    }
                }
                let next = (json["pages"] as? [String: Any])?["next_url"] as? String
                path = next.map { $0.replacingOccurrences(of: "https://api.wanikani.com/v2/", with: "") }
            }
            doneToday = done
            if learned > lessonsToday { lessonsActive = lessonsActive.map { _ in now } }
            lessonsToday = learned
            showLessons()
            if unlocked { nudge() }
        }
    }

    static func get(_ path: String, _ token: String) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://api.wanikani.com/v2/\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("20170710", forHTTPHeaderField: "Wanikani-Revision")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Last lesson progress while doing lessons on the site; nil otherwise.
    private var lessonsActive: Date?
    private var lessonsShown: String? { didSet { syncInNotch() } }

    func startLessons() {
        // Lessons happen on the website: the notch's panel folds away.
        if Config.bar { withAnimation(.smooth(duration: 0.34)) { Notch.shared.expanded = false } }
        open("subject-lessons/start")
        lessonsActive = Date()
        showLessons()
    }

    /// The notch while doing lessons: the tile left of the camera, today's
    /// count right of it.
    private func showLessons() {
        guard let since = lessonsActive, lessons > 0, Date().timeIntervalSince(since) < 20 * 60 else {
            if lessonsActive != nil || lessonsShown != nil { Notch.shared.clear("wk-lessons") }
            lessonsActive = nil
            lessonsShown = nil
            return
        }
        let count = "\(lessonsToday)/\(goal)"
        guard count != lessonsShown else { return }
        lessonsShown = count
        Notch.shared.post(NotchAlert(id: "wk-lessons", icon: .image(Self.tile), trailing: .text(count, .white.opacity(0.7)),
                                     title: "WaniKani lessons", subtitle: lessonsLeft > 0 ? "\(lessonsLeft) left today" : "\(lessons) available", duration: 0,
                                     tapOpens: !Config.bar, action: { Drawers.shared.toggle("wanikani") }))
    }

    /// Dock bar: the widget's click opens the WaniKani panel straight in the
    /// notch (summary, then reviews there), not above the widget first.
    func openInNotch() {
        Notch.shared.post(NotchAlert(id: "wk-open", icon: .image(Self.tile), trailing: .text("\(reviews)", .white.opacity(0.7)),
                                     title: "WaniKani", subtitle: "\(reviews) reviews · \(lessonsLeft) lessons left", duration: 0))
        withAnimation(.smooth(duration: 0.34)) { Notch.shared.expanded = true }
    }

    /// The widget's pink tile with 鰐, for the notch.
    private static let tile: NSImage = {
        let view = ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WK.pink)
            Text("鰐").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 40, height: 40)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }()

    func open(_ path: String) {
        Drawers.shared.open = nil
        NSWorkspace.shared.open(URL(string: "https://www.wanikani.com/\(path)")!)
    }

    /// Every item of a paged collection.
    static func all(_ path: String, _ token: String) async -> [[String: Any]] {
        var items: [[String: Any]] = []
        var next: String? = path
        while let page = next, let json = await get(page, token) {
            items += json["data"] as? [[String: Any]] ?? []
            next = ((json["pages"] as? [String: Any])?["next_url"] as? String)?
                .replacingOccurrences(of: "https://api.wanikani.com/v2/", with: "")
        }
        return items
    }

    /// Subjects by id, as compact items (primary meaning and reading).
    private static func subjects(_ ids: [Int], _ token: String) async -> [Int: WKItem] {
        guard !ids.isEmpty else { return [:] }
        var found: [Int: WKItem] = [:]
        for subject in await all("subjects?ids=" + ids.map(String.init).joined(separator: ","), token) {
            guard let id = subject["id"] as? Int, let d = subject["data"] as? [String: Any],
                  let characters = d["characters"] as? String else { continue }
            func primary(_ key: String, _ field: String) -> String {
                let list = d[key] as? [[String: Any]] ?? []
                return (list.first { $0["primary"] as? Bool == true } ?? list.first)?[field] as? String ?? ""
            }
            found[id] = WKItem(characters: characters, meaning: primary("meanings", "meaning"),
                               reading: primary("readings", "reading"), kanji: subject["object"] as? String == "kanji")
        }
        return found
    }

    /// Level progress and leeches (every 30 min, on level-up, when the drawer
    /// opens) and the known-items pool (daily).
    func refreshDetails() {
        guard Config.demo == nil, Date().timeIntervalSince(detailsAt) > 1800, let token = WaniKaniToken.load() else { return }
        Task { await refreshDetails(token) }
    }

    private func refreshDetails(_ token: String) async {
        detailsAt = Date()
        let lvl = level
        async let kanji = Self.get("subjects?types=kanji&levels=\(lvl)&hidden=false", token)
        async let assigned = Self.all("assignments?subject_types=kanji&levels=\(lvl)", token)
        async let stats = Self.all("review_statistics?subject_types=kanji,vocabulary&percentages_less_than=80&hidden=false", token)
        if let total = await kanji?["total_count"] as? Int, total > 0 {
            let passed = await assigned.filter { ($0["data"] as? [String: Any])?["passed_at"] is String }.count
            if total != levelTotal { levelTotal = total }
            if passed != levelPassed { levelPassed = passed }
        }
        // Leech score: wrong answers weighed against the current streak, so an
        // item missed once early on doesn't top the list.
        let ranked = await stats.compactMap { stat -> (id: Int, incorrect: Int, percent: Int, score: Double)? in
            guard let d = stat["data"] as? [String: Any], let id = d["subject_id"] as? Int else { return nil }
            let incorrect = (d["meaning_incorrect"] as? Int ?? 0) + (d["reading_incorrect"] as? Int ?? 0)
            let streak = max(1, min(d["meaning_current_streak"] as? Int ?? 1, d["reading_current_streak"] as? Int ?? 1))
            guard incorrect >= 3 else { return nil }
            return (id, incorrect, d["percentage_correct"] as? Int ?? 0, Double(incorrect) / pow(Double(streak), 1.5))
        }.sorted { $0.score > $1.score }.prefix(5)
        let found = await Self.subjects(ranked.map(\.id), token)
        let top = ranked.compactMap { r in found[r.id].map { WKLeech(item: $0, incorrect: r.incorrect, percent: r.percent) } }
        if top != leeches { leeches = top }
        let age = (try? Self.poolFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard Date().timeIntervalSince(age) > 86400 else { return }
        let known = await Self.all("assignments?srs_stages=5,6,7,8,9&subject_types=kanji,vocabulary&hidden=false", token)
            .compactMap { ($0["data"] as? [String: Any])?["subject_id"] as? Int }
        let sample = await Self.subjects(Array(known.shuffled().prefix(120)), token).values.filter { $0.characters.count <= 3 }
        guard !sample.isEmpty else { return }
        pool = Array(sample)
        try? FileManager.default.createDirectory(at: Self.poolFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pool).write(to: Self.poolFile)
        if idleWord == nil { rotate() }
    }

    /// Picks another known item; only while the idle widget shows.
    private func rotate() {
        guard let pick = pool.filter({ $0 != idleWord }).randomElement() ?? pool.first, pick != idleWord else { return }
        idleWord = pick
    }

    private func startRotation() {
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.connected, !self.hasWork { self.rotate() } }
        }
    }

    private func celebrate() {
        celebrating = true
        Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.celebrating = false }
        }
    }
}

struct WKReviewTile: Equatable {
    let characters: String?
    let type: String
    let progress: Double
}

struct WKItem: Codable, Equatable {
    let characters: String
    let meaning: String
    let reading: String
    let kanji: Bool
}

struct WKLeech: Equatable {
    let item: WKItem
    let incorrect: Int
    let percent: Int
}

/// WaniKani's own colours: radical blue, kanji pink, vocabulary purple.
enum WK {
    static let pink = Color(red: 1, green: 0, blue: 0.67)
    static let blue = Color(red: 0, green: 0.67, blue: 1)
    static let purple = Color(red: 0.67, green: 0, blue: 1)
}

struct WaniKaniView: View {
    @ObservedObject var wk: WaniKani
    /// Tile only, when the wing is short of room.
    var compact = false

    /// Nothing to do: the tile shows a known item instead.
    private var idle: WKItem? { wk.connected && !wk.hasWork ? wk.idleWord : nil }
    /// Mid-review: the current question's item, in its type's colour.
    private var current: WKReviewTile? { wk.reviewing && wk.reviewTile.characters != nil ? wk.reviewTile : nil }

    private var tileColor: Color {
        if let current { return current.type == "radical" ? WK.blue : current.type == "kanji" ? WK.pink : WK.purple }
        return idle.map { $0.kanji ? WK.pink : WK.purple } ?? (wk.reviews > 0 ? WK.pink : Color(white: 0.2))
    }

    /// The ring: review progress during a review, else today's lessons.
    private var ring: Double {
        if wk.reviewing { return wk.reviewTile.progress }
        return wk.goal == 0 ? 1 : min(Double(wk.lessonsToday) / Double(wk.goal), 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tileColor)
                Text(current?.characters ?? idle?.characters ?? "鰐").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    .minimumScaleFactor(0.5).padding(.horizontal, 3)
            }
            .frame(width: 40, height: 40)
            .background { if wk.celebrating { GoldBurst() } }
            // Ring around the tile: review progress mid-review, else today's lessons.
            .overlay {
                TopStartRing(radius: 12)
                    .trim(from: 0, to: ring)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(-4)
                    .animation(.spring(duration: 0.6, bounce: 0.2), value: ring)
            }
            .modifier(Pulse(on: wk.reviews > 0, color: NSColor(tileColor)))
            // The ring sits outside the tile; count it in the width so it never
            // spills into the gap beside the Dock.
            .padding(.horizontal, 5)
            // During a review (or when room is short) only the tile shows, so
            // music keeps its room.
            if !wk.reviewing && !compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).contentTransition(.numericText())
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(ink(0.6))
                }
                .lineLimit(1)
                // The idle item changes every few minutes; a fixed width keeps
                // the wing from re-flowing.
                .frame(width: idle == nil ? nil : 150, alignment: .leading)
            }
        }
        .tapAction { if Config.bar { WaniKani.shared.openInNotch() } else { Drawers.shared.toggle("wanikani") } }
        .contextMenu {
            Button("Start Reviews") { wk.open("subjects/review") }
            Button("Start Lessons") { wk.startLessons() }
            Button("Refresh") { wk.refresh() }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: wk.reviews)
    }

    private var title: String {
        if !wk.connected { return "WaniKani" }
        if wk.celebrating { return "Level \(wk.level)" }
        if let idle { return idle.meaning + " · " + idle.reading }
        if !wk.hasWork { return "All done" }
        if wk.reviews > 0 { return "\(wk.reviews) review\(wk.reviews == 1 ? "" : "s")" }
        return "\(wk.lessonsLeft) lesson\(wk.lessonsLeft == 1 ? "" : "s") to go"
    }

    private var subtitle: String {
        if !wk.connected { return "Add your token in Settings" }
        if !wk.hasWork {
            guard let wave = wk.nextWave else { return "No reviews in the next hours" }
            return "Next: \(wave.count) at " + wave.hour.formatted(date: .omitted, time: .shortened)
        }
        let lessons = "Lessons \(wk.lessonsToday) of \(wk.goal) today"
        return wk.reviews > 0 && wk.lessonsLeft > 0 ? lessons + " · \(wk.lessonsLeft) left" : lessons
    }
}

/// Rounded square traced clockwise from the top centre, so a trimmed ring
/// fills like a progress circle (RoundedRectangle starts mid-right).
private struct TopStartRing: Shape {
    let radius: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: radius)
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        return p
    }
}

/// Soft breathing glow while reviews are waiting (Core Animation), in the
/// tile's colour (mid-review: the current item's type).
private struct Pulse: ViewModifier {
    let on: Bool
    let color: NSColor
    @Environment(\.ambient) private var ambient

    func body(content: Content) -> some View {
        content.background { if on && ambient { PulseLayer(color: color) } }
    }
}

private struct PulseLayer: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        view.wantsLayer = true
        let glow = CALayer()
        glow.frame = view.bounds
        glow.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glow.cornerRadius = 9
        glow.backgroundColor = color.cgColor
        glow.shadowColor = glow.backgroundColor
        glow.shadowRadius = 8
        glow.shadowOffset = .zero
        let breathe = CABasicAnimation(keyPath: "shadowOpacity")
        breathe.fromValue = 0.1
        breathe.toValue = 0.6
        breathe.duration = 1.25
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(fullRate(breathe), forKey: "breathe")
        view.layer?.addSublayer(glow)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let glow = view.layer?.sublayers?.first, glow.backgroundColor != color.cgColor else { return }
        glow.backgroundColor = color.cgColor
        glow.shadowColor = color.cgColor
    }
}

/// Level-up: a gold glow flashes three times around the tile, then stays off
/// (Core Animation, runs once).
private struct GoldBurst: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        view.wantsLayer = true
        let glow = CALayer()
        glow.frame = view.bounds
        glow.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glow.cornerRadius = 9
        glow.backgroundColor = NSColor(red: 1, green: 0.8, blue: 0.2, alpha: 1).cgColor
        glow.shadowColor = glow.backgroundColor
        glow.shadowRadius = 14
        glow.shadowOffset = .zero
        glow.shadowOpacity = 0
        let flash = CABasicAnimation(keyPath: "shadowOpacity")
        flash.fromValue = 0
        flash.toValue = 1
        flash.duration = 0.45
        flash.autoreverses = true
        flash.repeatCount = 3
        flash.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(fullRate(flash), forKey: "flash")
        view.layer?.addSublayer(glow)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Drawer content: reviews per hour ahead, and buttons to study.
struct WaniKaniDrawer: View {
    @ObservedObject var wk: WaniKani
    @ObservedObject var review = WKReview.shared
    /// Inside the notch (Dock bar): no card of its own, the notch's width.
    var bare = false

    var body: some View {
        Group {
            if review.phase == .idle { summary.transition(.opacity) } else { WaniKaniReviewView(review: review).transition(.opacity) }
        }
        .animation(.smooth(duration: 0.3), value: review.phase == .idle)
        .padding(bare ? 0 : 16)
        .frame(width: bare ? nil : review.phase == .idle ? 330 : 400)
        .modifier(CardUnless(bare: bare))
        .onAppear {
            wk.refreshDetails()
            if Config.demo != nil, UserDefaults.standard.string(forKey: "Review") != nil, review.phase == .idle { review.start() }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Level \(wk.level)").font(.system(size: 17, weight: .bold))
                Spacer()
                Text("\(wk.doneToday) reviewed · lessons \(wk.lessonsToday)/\(wk.goal) today").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            if wk.levelTotal > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(WK.pink)
                                .frame(width: geo.size.width * min(Double(wk.levelPassed) / Double(max(wk.levelNeed, 1)), 1))
                        }
                    }
                    .frame(height: 6)
                    Text("\(wk.levelPassed) / \(wk.levelNeed) kanji to level \(wk.level + 1)")
                        .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !wk.forecast.isEmpty {
                let peak = max(wk.forecast.map(\.count).max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(wk.forecast.prefix(8), id: \.hour) { slot in
                        VStack(spacing: 4) {
                            Text("\(slot.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(slot.count > 0 ? .primary : .tertiary)
                            RoundedRectangle(cornerRadius: 3).fill(slot.count > 0 ? WK.pink : Color.white.opacity(0.12))
                                .frame(width: 26, height: max(4, 62 * CGFloat(slot.count) / CGFloat(peak)))
                            Text(slot.hour.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !wk.leeches.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Leeches").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(wk.leeches, id: \.item.characters) { leech in
                        HStack(spacing: 8) {
                            Text(leech.item.characters).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).frame(minWidth: 26, minHeight: 24)
                                .background(RoundedRectangle(cornerRadius: 5).fill(leech.item.kanji ? WK.pink : WK.purple))
                            Text(leech.item.meaning).font(.system(size: 14))
                            Text(leech.item.reading).font(.system(size: 14)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(leech.percent)%").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .lineLimit(1)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { wk.startLessons() } label: {
                    Text("Lessons").frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(WK.blue.opacity(wk.lessonsLeft > 0 ? 0.9 : 0.25)))
                }
                Button { if wk.reviews > 0 || Config.demo != nil { review.start() } else { wk.open("subjects/review") } } label: {
                    Text("Reviews").frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(WK.pink.opacity(wk.reviews > 0 ? 0.9 : 0.25)))
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
        }
    }
}
