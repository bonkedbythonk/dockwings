// Now-playing state and controls for Tide, Music and Spotify. Tide (the
// owner's YouTube Music app) talks over distributed notifications
// (`local.tide.nowPlaying` in, `local.tide.command` out, see Tide's
// NowPlayingCenter.swift); Music and Spotify go through AppleScript. Polls
// only apps that are already running, so it never launches a player by
// itself; pressing play with nothing running starts Music.
import AppKit
import SwiftUI

@MainActor
final class Music: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            restartIdle()
            if !isPlaying { NotificationCenter.default.post(name: .breakMoment, object: nil) }
        }
    }
    /// Paused for a while: the widget steps away until music plays again or
    /// headphones connect.
    @Published private(set) var idle = false
    private static let idleAfter: TimeInterval = 5 * 60
    private var idleTimer: Timer?
    /// Paused for 20 s: the widget narrows and ranks lower. Waiting keeps a quick
    /// pause from moving the widgets around it.
    @Published private(set) var settled = false
    private var settleTimer: Timer?

    private func restartIdle() {
        idleTimer?.invalidate()
        settleTimer?.invalidate()
        if idle { idle = false }
        if settled { withAnimation(.spring(duration: 0.5, bounce: 0.15)) { settled = false } }
        guard !isPlaying else { return }
        settleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == false { withAnimation(.spring(duration: 0.5, bounce: 0.15)) { self?.settled = true } } }
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == false { self?.idle = true } }
        }
    }
    @Published var art: NSImage? {
        didSet { artColor = art.flatMap(Self.mainColor) }
    }
    /// Mouse is over the music area (set by AppDelegate); shows the controls.
    @Published var hovering = false

    /// Changes with every new track; views key their crossfade on it.
    @Published private(set) var trackKey = ""
    /// Current synced lyric line (Tide), empty when there is none.
    @Published var lyric = ""
    /// "Title · Artist" of the next song (Tide).
    @Published var upNext = ""
    @Published var liked = false
    /// Tide extras for the drawer: the next lyric line, the next few songs,
    /// volume (0...1) and shuffle.
    @Published var lyricNext = ""
    @Published var queue: [String] = []
    /// Cover of each queued song, when Tide knows it.
    @Published var queueArt: [URL?] = []
    @Published var volume = 0.0
    @Published var shuffle = false
    /// Tide's smart transitions: where the next song mixes in (seconds into
    /// this one), and when the mix under way began (epoch seconds) and lasts.
    @Published var mixAt: Double?
    @Published var mixBegan: Double = 0
    @Published var mixSeconds: Double = 0
    /// Where a two-finger swipe is scrubbing to (0...1), while it lasts.
    @Published var scrub: Double?
    @Published private(set) var duration: Double = 0
    /// Tide extras: the whole synced lyrics, search results, your playlists,
    /// and live audio levels (5 bands, 0...1) for the visualizer.
    @Published private(set) var lyrics: [(time: Double, text: String)] = []
    @Published private(set) var results: [(id: String, title: String, artist: String, art: URL?)] = []
    @Published private(set) var playlists: [(id: String, name: String)] = []
    /// Kept apart so 15 updates a second redraw only the bars, not the wings.
    let live = LiveLevels()
    /// The cover's main colour, for the glow behind the widget.
    @Published private(set) var artColor: Color?
    /// Position at `positionDate`; progress is interpolated from here.
    private(set) var position: Double = 0
    private(set) var positionDate = Date()

    var isTide: Bool { player == "Tide" }

    /// Playback position now, 0...1.
    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        let now = position + (isPlaying ? date.timeIntervalSince(positionDate) : 0)
        return min(max(now / duration, 0), 1)
    }

    private var player: String?
    private var scripts: [String: NSAppleScript] = [:]
    private var tide: [AnyHashable: Any] = [:]

    private static let tideID = "local.music-sample"
    private static let tideState = Notification.Name("local.tide.nowPlaying")
    private static let tideCommand = Notification.Name("local.tide.command")

    init() {
        if let demo = Config.demo {
            demo == "cycle" ? runDemoCycle() : setDemo(demo == "a" ? 0 : 1, playing: demo == "a")
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.tideState, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated {
                self?.tide = info
                self?.poll()
            }
        }
        listen("local.tide.lyrics") { m, info in
            let times = info["times"] as? [Double] ?? [], lines = info["lines"] as? [String] ?? []
            m.lyrics = zip(times, lines).map { (time: $0, text: $1) }
        }
        listen("local.tide.results") { m, info in
            let ids = info["ids"] as? [String] ?? [], titles = info["titles"] as? [String] ?? [], artists = info["artists"] as? [String] ?? []
            let arts = info["artworks"] as? [String] ?? []
            m.results = ids.indices.map { (id: ids[$0], title: titles.indices.contains($0) ? titles[$0] : "",
                                           artist: artists.indices.contains($0) ? artists[$0] : "",
                                           art: arts.indices.contains($0) ? URL(string: arts[$0]) : nil) }
        }
        listen("local.tide.playlists") { m, info in
            let ids = info["ids"] as? [String] ?? [], names = info["names"] as? [String] ?? []
            m.playlists = zip(ids, names).map { (id: $0, name: $1) }
        }
        listen("local.tide.levels") { m, info in
            // Nothing to draw while the wings can't be seen.
            guard Presence.shared.visible else { return }
            m.live.levels = info["levels"] as? [Double] ?? []
            m.live.date = Date()
        }
        NotificationCenter.default.addObserver(forName: .audioConnected, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIdle() }
        }
        restartIdle()
        postToTide("state")
        postToTide("lyrics")
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private static let demoTracks: [(String, String, String?)] = [
        ("Bounce with me", "Nightcore", "Big Sur Graphic Light"),
        ("In my dreams (Extended Club Mix) - Remastered 2024", "Dj Shog", nil),
        ("Midnight drive", "Neon Coast", "Catalina"),
    ]

    private func setDemo(_ index: Int, playing: Bool) {
        let track = Self.demoTracks[index]
        title = track.0
        artist = track.1
        duration = 214
        position = 61
        positionDate = Date()
        lyric = index == 0 ? "So bounce with me, bounce with me" : ""
        lyricNext = index == 0 ? "Let the music take control" : ""
        upNext = "Midnight drive · Neon Coast"
        queue = ["Midnight drive · Neon Coast", "Afterglow · Lumen", "Static hearts · Orbit Club", "Low tide · Marrow"]
        volume = 0.7
        player = "Tide"
        art = track.2.flatMap { NSImage(contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/\($0).heic") }
        isPlaying = playing
        trackKey = "demo\(index)"
    }

    /// Steps through every state every 2.5 s, for recording the animations.
    private func runDemoCycle() {
        let steps: [(Music) -> Void] = [
            { $0.setDemo(0, playing: true) },
            { $0.hovering = true },
            { $0.hovering = false; $0.setDemo(2, playing: true) },
            { $0.isPlaying = false },
            { $0.setDemo(1, playing: false) },
            { $0.title = ""; $0.trackKey = "" },
        ]
        var step = 0
        steps[0](self)
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                step = (step + 1) % steps.count
                steps[step](self)
            }
        }
    }

    /// Brings the playing app to the front (and closes any drawer).
    func openPlayer() {
        Drawers.shared.open = nil
        let ids = ["Tide": Self.tideID, "Music": "com.apple.Music", "Spotify": "com.spotify.client"]
        guard let id = ids[player ?? "Music"], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func listen(_ name: String, _ apply: @escaping @MainActor (Music, [AnyHashable: Any]) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { if let self { apply(self, info) } }
        }
    }

    // Tide-only commands (see Tide's NowPlayingCenter.swift for the protocol).
    func playQueued(_ index: Int) { postToTide("play:\(index)") }
    func moveQueued(from: Int, to: Int) { postToTide("move:\(from):\(to)") }
    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { results = [] } else { postToTide("search:" + q) }
    }
    func play(id: String) { postToTide("playid:" + id); results = [] }
    func startRadio() { postToTide("radio") }
    func loadPlaylists() { postToTide("playlists") }
    func add(to playlist: String) { postToTide("addto:" + playlist) }
    /// Jump to a lyric line.
    func seek(seconds: Double) { if duration > 0 { seek(to: seconds / duration) } }

    /// Live bars while Tide sends levels; nil falls back to the loop.

    func playPause() { send("playpause", tide: "playpause") }
    func toggleLike() { if isTide { postToTide("like"); liked.toggle() } }
    func toggleShuffle() { if isTide { postToTide("shuffle"); shuffle.toggle() } }
    func setVolume(_ level: Double) {
        volume = level
        if isTide { postToTide("volume:\(level)") }
    }

    /// Jumps to a fraction of the song.
    func seek(to fraction: Double) {
        if isTide {
            postToTide("seek:\(fraction)")
        } else if let player {
            run("tell application \"\(player)\" to set player position to \(fraction * duration)")
        }
        position = fraction * duration
        positionDate = Date()
        objectWillChange.send()
    }
    func next() { send("next track", tide: "next") }
    func previous() { send("previous track", tide: "previous") }

    private func send(_ command: String, tide tideCommand: String) {
        if player == "Tide" {
            postToTide(tideCommand)
            return
        }
        run("tell application \"\(player ?? "Music")\" to \(command)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.poll() }
    }

    private func postToTide(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.tideCommand, object: command, userInfo: nil, deliverImmediately: true)
    }

    private var tideTimingSent = 0.0

    private func poll() {
        let apple = applePlayer()
        // Tide pushes its state, so it needs no polling. It wins unless it is
        // paused while Music or Spotify is playing.
        let tideTitle = tide["title"] as? String ?? ""
        let tidePlaying = tide["playing"] as? Bool ?? false
        if isRunning(Self.tideID), !tideTitle.isEmpty, tidePlaying || apple?.parts[0] != "playing" {
            let artwork = URL(string: tide["artwork"] as? String ?? "")
            show(app: "Tide", playing: tidePlaying, title: tideTitle, artist: tide["artist"] as? String ?? "") {
                if let artwork, artwork.scheme != nil { self.fetchArt(artwork) }
            }
            // Only a new broadcast moves the clock: re-reading the last one would
            // undo a seek that Tide didn't broadcast.
            let sentAt = tide["sentAt"] as? Double ?? Date().timeIntervalSince1970
            if sentAt != tideTimingSent {
                tideTimingSent = sentAt
                timing(position: tide["position"] as? Double ?? 0, duration: tide["duration"] as? Double ?? 0,
                       at: Date(timeIntervalSince1970: sentAt))
            }
            set(\.lyric, tide["lyric"] as? String ?? "")
            set(\.upNext, tide["next"] as? String ?? "")
            set(\.liked, tide["liked"] as? Bool ?? false)
            set(\.lyricNext, tide["lyricNext"] as? String ?? "")
            set(\.queue, (tide["queue"] as? String ?? "").split(separator: "\n").map(String.init))
            set(\.queueArt, (tide["queueArt"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { URL(string: String($0)) })
            set(\.shuffle, tide["shuffle"] as? Bool ?? false)
            set(\.mixAt, (tide["mixAt"] as? Double).flatMap { $0 >= 0 ? $0 : nil })
            set(\.mixBegan, tide["mixBegan"] as? Double ?? 0)
            set(\.mixSeconds, tide["mixSeconds"] as? Double ?? 0)
            if abs(volume - (tide["volume"] as? Double ?? volume)) > 0.01 { volume = tide["volume"] as? Double ?? volume }
            return
        }
        guard let apple else {
            player = nil
            if !trackKey.isEmpty { trackKey = ""; title = ""; artist = ""; art = nil }
            if isPlaying { isPlaying = false }
            return
        }
        show(app: apple.app, playing: apple.parts[0] == "playing", title: apple.parts[1], artist: apple.parts[2]) {
            self.loadArt(from: apple.app)
        }
        if apple.parts.count >= 5, let pos = Double(apple.parts[3].replacingOccurrences(of: ",", with: ".")),
           var length = Double(apple.parts[4].replacingOccurrences(of: ",", with: ".")) {
            if apple.app == "Spotify" { length /= 1000 }  // Spotify reports milliseconds
            timing(position: pos, duration: length, at: Date())
            tideTimingSent = 0  // back on Tide, take its clock again
        }
        set(\.lyric, "")
        set(\.upNext, "")
    }

    private func timing(position: Double, duration: Double, at date: Date) {
        // Only correct the clock when it drifted, so the bar doesn't jitter.
        let expected = self.position + (isPlaying ? date.timeIntervalSince(positionDate) : 0)
        if abs(expected - position) > 1.5 || self.duration != duration {
            self.position = position
            positionDate = date
            if self.duration != duration { self.duration = duration } else { objectWillChange.send() }
        }
    }

    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<Music, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    private func show(app: String, playing: Bool, title newTitle: String, artist newArtist: String, newTrack: () -> Void) {
        player = app
        if isPlaying != playing { isPlaying = playing }
        if title != newTitle { title = newTitle }
        if artist != newArtist { artist = newArtist }
        let key = app + "|" + newTitle + "|" + newArtist
        if key != trackKey {
            trackKey = key
            art = nil
            artColor = nil
            lyrics = []
            newTrack()
            if app == "Tide" { postToTide("lyrics") }
        }
    }

    /// The running Music or Spotify, preferring one that is playing.
    private func applePlayer() -> (app: String, parts: [String])? {
        var best: (app: String, parts: [String])?
        for (app, id) in [("Spotify", "com.spotify.client"), ("Music", "com.apple.Music")] where isRunning(id) {
            let source = """
            tell application "\(app)"
                if player state is stopped then return ""
                set t to current track
                return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (player position as text) & linefeed & (duration of t as text)
            end tell
            """
            guard let parts = run(source)?.stringValue?.components(separatedBy: "\n"), parts.count >= 3 else { continue }
            if best == nil || parts[0] == "playing" { best = (app, parts) }
            if parts[0] == "playing" { break }
        }
        return best
    }

    private func loadArt(from app: String) {
        if app == "Music" {
            if let data = run("tell application \"Music\" to get raw data of artwork 1 of current track")?.data {
                art = NSImage(data: data)
            }
        } else if let link = run("tell application \"Spotify\" to get artwork url of current track")?.stringValue,
                  let url = URL(string: link) {
            fetchArt(url)
        }
    }

    private func fetchArt(_ url: URL) {
        let key = trackKey
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            if self.trackKey == key { self.art = NSImage(data: data) }
        }
    }

    /// The cover's colour for buttons: light on dark backgrounds, deep on
    /// light ones, so it always reads.
    func tint(onLight: Bool) -> Color? {
        guard let artColor else { return nil }
        let c = NSColor(artColor).usingColorSpace(.deviceRGB) ?? .white
        return Color(nsColor: NSColor(hue: c.hueComponent, saturation: min(c.saturationComponent, onLight ? 0.8 : 0.55),
                                      brightness: onLight ? 0.42 : 0.92, alpha: 1))
    }

    /// Average colour of the cover, made a bit more vivid for the glow.
    private static func mainColor(_ image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        return Color(nsColor: NSColor(hue: c.hueComponent, saturation: min(1, c.saturationComponent * 1.4 + 0.1),
                                      brightness: max(0.55, c.brightnessComponent), alpha: 1))
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        let script = scripts[source] ?? NSAppleScript(source: source)!
        scripts[source] = script
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

struct MusicView: View {
    @ObservedObject var music: Music
    let height: CGFloat
    /// Spare room on this side the widget may grow into (lyrics, title).
    var extra: CGFloat = 0

    /// Settings switch: the current lyric line instead of the artist.
    @AppStorage("musicLyrics") private var lyricsOn = true
    /// While playing it grows into spare room: all of it (up to 190) for
    /// lyrics, else only as far as the title needs. Paused it is a bit
    /// narrower so it can share a page with another widget.
    private var textWidth: CGFloat {
        guard !music.settled else { return 155 }
        let wanted = lyricsOn && !music.lyrics.isEmpty ? 190 : max(0, titleWidth - 170)
        return 170 + min(extra, wanted, 190)
    }
    private var titleWidth: CGFloat {
        ceil((music.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]).width)
    }
    /// A title too long to fit slides across once when the song starts and
    /// when the pointer arrives, then rests truncated again.
    @State private var titleShift: CGFloat = 0
    @State private var titleScrolling = false
    @State private var titleTask: Task<Void, Never>?

    private func scrollTitle() {
        titleTask?.cancel()
        titleTask = nil
        titleShift = 0
        titleScrolling = false
        let overflow = titleWidth - textWidth
        guard overflow > 4 else { return }
        titleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(0.8))
                titleScrolling = true
                let duration = Double(overflow) / 30
                withAnimation(.linear(duration: duration)) { titleShift = -overflow }
                try await Task.sleep(for: .seconds(duration + 1.2))
                withAnimation(.easeInOut(duration: 0.4)) { titleShift = 0 }
                try await Task.sleep(for: .seconds(0.4))
                titleScrolling = false
                titleTask = nil
            } catch {}
        }
    }
    private var lineText: String {
        if !music.isPlaying, music.duration > 0 { return "Paused · " + MusicDrawer.clock(music.position) }
        return lyricsOn && !music.lyric.isEmpty ? music.lyric : music.artist
    }

    var body: some View {
        HStack(spacing: 12) {
            cover
                .tapAction { Drawers.shared.toggle("music") }
                .id(music.trackKey)
                .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                        removal: .scale(scale: 1.15).combined(with: .opacity)))

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if titleScrolling {
                            Text(music.title).fixedSize().offset(x: titleShift)
                                .frame(width: textWidth, alignment: .leading).clipped()
                        } else {
                            Text(music.title)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    // The lyric line when there is one, else the artist.
                    HStack(spacing: 6) {
                        EqualizerBars(playing: music.isPlaying, live: music.live)
                        Text(music.scrub.map { "Seek to " + MusicDrawer.clock($0 * music.duration) + " / " + MusicDrawer.clock(music.duration) }
                             ?? lineText)
                            .font(.system(size: 12))
                            .foregroundStyle(ink(lineText == music.artist || !music.isPlaying ? 0.6 : 0.8))
                            .id(lineText)
                            .transition(.asymmetric(insertion: .offset(y: 8).combined(with: .opacity),
                                                    removal: .offset(y: -8).combined(with: .opacity)))
                    }
                }
                .frame(width: textWidth, alignment: .leading)
                .clipped()
                .tapAction { Drawers.shared.toggle("music") }
                // Not clipped: the mix glow spills past the bar.
                if music.duration > 0 { ProgressBar(music: music) }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: textWidth, alignment: .leading)
            .id(music.trackKey)
            .transition(.blurReplace)
        }
        .padding(.horizontal, 4)
        .frame(height: height)
        .animation(.spring(duration: 0.55, bounce: 0.2), value: music.trackKey)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: music.isPlaying)
        .animation(.spring(duration: 0.45, bounce: 0.1), value: music.lyric)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: textWidth)
        .onChange(of: music.trackKey) { scrollTitle() }
        // A scroll already under way finishes instead of starting over.
        .onChange(of: music.hovering) { _, hovering in if hovering, titleTask == nil { scrollTitle() } }
    }

    /// The cover, sized and rounded like a Dock icon; shrinks a little while
    /// paused.
    private var cover: some View {
        let side = height - 26
        return ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(Color(white: 0.2))
            Image(systemName: "music.note").font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            if let art = music.art {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        // Soft glow in the cover's own colour, changing with each song.
        .background {
            if let glow = music.artColor {
                Circle().fill(glow).frame(width: side * 1.4, height: side * 1.4)
                    .blur(radius: 20).opacity(music.isPlaying ? 0.28 : 0.1)
                    .animation(.smooth(duration: 0.8), value: music.trackKey)
            }
        }
        .scaleEffect(music.isPlaying ? 1 : 0.9)
    }
}

/// Drawer content: what the widget can't show. Search YouTube Music (Tide),
/// the whole synced lyrics (click a line to jump) or the queue (click to
/// play, drag to reorder), and like, shuffle, radio, add to playlist, volume.
struct MusicDrawer: View {
    @ObservedObject var music: Music
    /// Inside the notch (Dock bar): no card of its own, the notch's width.
    var bare = false
    @State private var query = ""
    @State private var tab = 0
    /// Tide's accent: the cover's colour, only on things switched on.
    private var tint: Color { music.tint(onLight: false) ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if music.isTide {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search YouTube Music", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { music.search(query) }
                    if !query.isEmpty {
                        Button { query = ""; music.search("") } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            }

            if !query.isEmpty && !music.results.isEmpty {
                list(music.results.map { ($0.id, $0.title, $0.artist, $0.art) }) { music.play(id: $0); query = "" }
            } else {
                if music.isTide {
                    PillSwitch(options: ["Lyrics", "Up next"], selection: $tab)
                }
                Group {
                    if tab == 0 { LyricsView(music: music) } else { QueueView(music: music) }
                }
                // Lyrics first when the song has them, else straight to Up next.
                .onAppear { tab = music.lyrics.isEmpty ? 1 : 0 }
                .onChange(of: music.lyrics.isEmpty) { _, empty in tab = empty ? 1 : 0 }
            }

            HStack(spacing: 10) {
                if music.isTide {
                    IconButton(symbol: music.liked ? "heart.fill" : "heart", size: 13, action: music.toggleLike)
                        .foregroundStyle(music.liked ? tint : Color.secondary)
                        .help(music.liked ? "Unlike" : "Like")
                    IconButton(symbol: "shuffle", size: 13, action: music.toggleShuffle)
                        .foregroundStyle(music.shuffle ? tint : Color.secondary)
                        .help("Shuffle")
                    IconButton(symbol: "dot.radiowaves.left.and.right", size: 13, action: music.startRadio)
                        .help("Song radio: similar songs next")
                    Menu {
                        if music.playlists.isEmpty { Text("Loading playlists…") }
                        ForEach(music.playlists, id: \.id) { list in
                            Button(list.name) { music.add(to: list.id) }
                        }
                    } label: { Image(systemName: "text.badge.plus") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add to playlist")
                    .onAppear(perform: music.loadPlaylists)
                    Slider(value: Binding(get: { music.volume }, set: { music.setVolume($0) }), in: 0...1)
                        .controlSize(.mini)
                        .tint(tint)
                        .frame(width: 70)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "arrow.up.forward.app", size: 13, action: music.openPlayer).help("Open the player")
            }
            .foregroundStyle(.secondary)
            .animation(.smooth(duration: 0.8), value: music.trackKey)
        }
        .padding(bare ? 0 : 16)
        .frame(width: bare ? nil : 360)
        .modifier(CardUnless(bare: bare))
        .animation(.spring(duration: 0.4, bounce: 0.12), value: tab)
        .animation(.smooth(duration: 0.3), value: music.results.count)
    }

    private func list(_ rows: [(String, String, String, URL?)], tap: @escaping (String) -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.0) { row in
                    Button { tap(row.0) } label: {
                        HStack(spacing: 10) {
                            SongArt(url: row.3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.1).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(row.2).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRow())
                }
            }
        }
        .frame(height: 230)
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Thin progress bar; click or drag anywhere on it to seek. Thickens on hover.
struct ProgressBar: View {
    @ObservedObject var music: Music
    @Environment(\.ambient) private var ambient
    @State private var hovering = false
    @State private var dragFraction: Double?

    /// Like Tide: the mix point as a small mark in the cover's colour, and
    /// during a mix a glowing trail behind the head.
    private var glow: Color { music.artColor ?? .white }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            GeometryReader { g in
                let fraction = music.scrub ?? dragFraction ?? music.progress(at: context.date)
                // Tide's bar: a thin track, a softer fill and a solid round head.
                let big = hovering || dragFraction != nil || music.scrub != nil
                let head: CGFloat = big ? 9 : 7
                let headX = min(max(g.size.width * fraction - head / 2, 0), g.size.width - head)
                let mixEnd = music.mixBegan + music.mixSeconds
                ZStack(alignment: .leading) {
                    Capsule().fill(ink(0.18)).frame(height: 3)
                    Capsule().fill(ink(0.55)).frame(width: max(g.size.width * fraction, 3), height: 3)
                    if let at = music.mixAt, music.duration > 0 {
                        Capsule().fill(glow).frame(width: 2, height: 7)
                            .shadow(color: glow.opacity(0.8), radius: 3)
                            .offset(x: g.size.width * min(max(at / music.duration, 0), 1) - 1)
                    }
                    if ambient, music.mixBegan > 0, context.date.timeIntervalSince1970 < mixEnd {
                        let trail = max(min(60, headX + head / 2), head)
                        MixGlowLayer(began: music.mixBegan, seconds: music.mixSeconds, color: NSColor(glow))
                            .frame(width: trail, height: 16)
                            .offset(x: headX + head / 2 - trail + head / 2)
                            .allowsHitTesting(false)
                    }
                    Circle().fill(ink(1)).frame(width: head, height: head)
                        .offset(x: headX)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = min(max($0.location.x / g.size.width, 0), 1) }
                    .onEnded { _ in
                        if let f = dragFraction { music.seek(to: f) }
                        dragFraction = nil
                    })
            }
        }
        .frame(height: 9)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: hovering)
    }
}

/// The glow during a Tide mix: a trail in the cover's colour ending in a
/// halo at the head, rising and fading over the mix (Core Animation, once).
private struct MixGlowLayer: NSViewRepresentable {
    let began: Double
    let seconds: Double
    let color: NSColor

    final class GlowView: NSView {
        let trail = CAGradientLayer()
        let halo = CALayer()
        var began = 0.0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            trail.startPoint = CGPoint(x: 0, y: 0.5)
            trail.endPoint = CGPoint(x: 1, y: 0.5)
            for l in [trail, halo] {
                l.shadowOffset = .zero
                l.shadowOpacity = 1
                layer?.addSublayer(l)
            }
            trail.shadowRadius = 5
            halo.shadowRadius = 8
            layer?.opacity = 0
        }
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let mid = bounds.midY
            trail.frame = CGRect(x: 0, y: mid - 2, width: bounds.width, height: 4)
            trail.cornerRadius = 2
            halo.frame = CGRect(x: bounds.width - 9, y: mid - 4.5, width: 9, height: 9)
            halo.cornerRadius = 4.5
            CATransaction.commit()
        }

        func apply(color: NSColor) {
            trail.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.95).cgColor]
            trail.shadowColor = color.cgColor
            halo.backgroundColor = color.cgColor
            halo.shadowColor = color.cgColor
        }

        /// Rises and falls like sin(pi * t) over the mix, joined part-way through.
        func swell(began: Double, seconds: Double) {
            guard let layer, seconds > 0 else { return }
            self.began = began
            let steps = 12
            let swell = CAKeyframeAnimation(keyPath: "opacity")
            swell.values = (0...steps).map { sin(Double.pi * Double($0) / Double(steps)) }
            swell.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
            swell.duration = seconds
            let elapsed = min(max(Date().timeIntervalSince1970 - began, 0), seconds)
            swell.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - elapsed
            swell.isRemovedOnCompletion = false
            swell.fillMode = .both
            layer.add(fullRate(swell), forKey: "swell")
        }
    }

    func makeNSView(context: Context) -> GlowView {
        let view = GlowView(frame: .zero)
        view.apply(color: color)
        view.swell(began: began, seconds: seconds)
        return view
    }

    func updateNSView(_ view: GlowView, context: Context) {
        view.apply(color: color)
        if view.began != began { view.swell(began: began, seconds: seconds) }
    }
}

/// Three small bars: follow Tide's live audio levels when it sends them,
/// otherwise bounce on a loop while playing; settle when paused.
/// Live levels from Tide. Not observed by SwiftUI: the bars read them
/// directly, so 15 updates a second never redraw the wings. Several bars can
/// listen at once (the music widget and the notch).
@MainActor
final class LiveLevels {
    var levels: [Double] = [] {
        didSet {
            for view in listeners.allObjects { view.show(levels) }
            for listener in others { listener(levels) }
        }
    }
    /// Other listeners outside SwiftUI (the buddy dancing to the beat).
    var others: [([Double]) -> Void] = []
    var date = Date.distantPast
    fileprivate let listeners = NSHashTable<BarsLayer.BarsView>.weakObjects()
}

/// Three small bars: they follow Tide's live levels when it sends them, and
/// bounce on a loop otherwise while playing; while paused they lie low and
/// breathe, with small "z"s drifting up now and then. Drawn as
/// Core Animation layers, so the motion costs the app almost nothing.
struct EqualizerBars: View {
    let playing: Bool
    let live: LiveLevels
    @Environment(\.ambient) private var ambient
    @Environment(\.inkDark) private var inkDark

    var body: some View {
        // Lays out as 9 x 9; the layer view is larger, up and to the right,
        // so the sleeping z's have room to drift without being cut off.
        Color.clear.frame(width: 9, height: 9).overlay(alignment: .bottomLeading) {
            BarsLayer(playing: playing && ambient, sleeping: !playing && ambient, live: live,
                      color: NSColor(white: inkDark ? 0.08 : 1, alpha: 0.6))
                .frame(width: 28, height: 30)
                .allowsHitTesting(false)
        }
    }
}

private struct BarsLayer: NSViewRepresentable {
    let playing: Bool
    let sleeping: Bool
    let live: LiveLevels
    let color: NSColor

    final class BarsView: NSView {
        let bars = (0..<3).map { _ in CALayer() }
        /// Three "z"s, each its own drift, size and period; the periods don't
        /// divide each other, so the pattern hardly ever repeats.
        let zees = (0..<3).map { _ in CATextLayer() }
        static let drifts: [(dx: CGFloat, dy: CGFloat, turn: CGFloat, size: CGFloat, period: Double, start: Double)] = [
            (7, 8, -0.25, 8, 5.3, 0), (-2, 7, 0.2, 7, 6.9, 2.1), (12, 5, -0.4, 9, 8.6, 4.4)]
        var playing = false
        var sleeping = false
        var looping = false
        var lastLive = Date.distantPast
        var fallback: Timer?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for (i, bar) in bars.enumerated() {
                bar.anchorPoint = CGPoint(x: 0.5, y: 0)
                bar.frame = CGRect(x: CGFloat(i) * 3.5, y: 0, width: 2, height: 3)
                bar.cornerRadius = 1
                layer?.addSublayer(bar)
            }
            for (zee, drift) in zip(zees, Self.drifts) {
                zee.string = "z"
                zee.fontSize = drift.size
                zee.contentsScale = 2
                zee.frame = CGRect(x: 6, y: 2, width: 10, height: 12)
                zee.opacity = 0
                layer?.addSublayer(zee)
            }
        }

        func setSleeping(_ on: Bool) {
            guard on != sleeping else { return }
            sleeping = on
            guard on else {
                for bar in bars { bar.removeAnimation(forKey: "sleep") }
                for zee in zees { zee.removeAnimation(forKey: "sleep") }
                return
            }
            for (i, bar) in bars.enumerated() {
                let a = CABasicAnimation(keyPath: "bounds.size.height")
                a.fromValue = 2
                a.toValue = 4
                a.duration = 1.5
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.beginTime = CACurrentMediaTime() + Double(i) * 0.25
                a.fillMode = .backwards
                bar.add(fullRate(a), forKey: "sleep")
            }
            // Each "z" floats up and fades over 3.5 s, then rests until its next turn.
            for (zee, drift) in zip(zees, Self.drifts) {
                let rise = CAKeyframeAnimation(keyPath: "transform")
                let end = 3.5 / drift.period
                rise.values = [CATransform3DIdentity,
                               CATransform3DRotate(CATransform3DMakeTranslation(drift.dx, drift.dy, 0), drift.turn, 0, 0, 1),
                               CATransform3DIdentity]
                rise.keyTimes = [0, NSNumber(value: end), 1]
                rise.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 0.8, 0, 0]
                fade.keyTimes = [0, NSNumber(value: end * 0.25), NSNumber(value: end), 1]
                let z = CAAnimationGroup()
                z.animations = [rise, fade]
                z.duration = drift.period
                z.repeatCount = .infinity
                z.beginTime = CACurrentMediaTime() + drift.start
                zee.add(fullRate(z), forKey: "sleep")
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(_ levels: [Double]) {
            // Tide sometimes sends only NaN: no real levels, keep the loop.
            guard playing, levels.contains(where: \.isFinite) else { return }
            lastLive = Date()
            stopLoop()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.08)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            for (i, bar) in bars.enumerated() {
                let raw = levels.indices.contains(i + 1) ? levels[i + 1] : (levels.first ?? 0)
                // Silence can arrive as -inf or NaN; a NaN height crashes Core Animation.
                let v = raw.isFinite ? min(max(raw, 0), 1) : 0
                bar.bounds.size.height = 3 + 6 * v
            }
            CATransaction.commit()
        }

        func setPlaying(_ on: Bool) {
            guard on != playing else { return }
            playing = on
            fallback?.invalidate()
            if on {
                // Without live levels for a moment (Music, Spotify), loop.
                fallback = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, Date().timeIntervalSince(self.lastLive) > 0.6 else { return }
                        self.startLoop()
                    }
                }
                startLoop()
            } else {
                stopLoop()
                for bar in bars { bar.bounds.size.height = 3 }
            }
        }

        private func startLoop() {
            guard !looping else { return }
            looping = true
            for (i, bar) in bars.enumerated() {
                let a = CABasicAnimation(keyPath: "bounds.size.height")
                a.fromValue = 3
                a.toValue = 9
                a.duration = 0.6 / (1 + Double(i) * 0.33)
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.timeOffset = Double(i) * 0.2
                bar.add(fullRate(a), forKey: "loop")
            }
        }

        private func stopLoop() {
            guard looping else { return }
            looping = false
            for bar in bars { bar.removeAnimation(forKey: "loop") }
        }
    }

    func makeNSView(context: Context) -> BarsView {
        BarsView(frame: NSRect(x: 0, y: 0, width: 28, height: 30))
    }

    func updateNSView(_ view: BarsView, context: Context) {
        for bar in view.bars { bar.backgroundColor = color.cgColor }
        for zee in view.zees { zee.foregroundColor = color.cgColor }
        // Only the visible bars listen (not the invisible measuring copy).
        if playing { live.listeners.add(view) } else { live.listeners.remove(view) }
        view.setPlaying(playing)
        view.setSleeping(sleeping)
    }
}

/// The whole synced lyrics, scrolling with the song, current line lit;
/// click a line to jump there.
private struct LyricsView: View {
    @ObservedObject var music: Music

    var body: some View {
        if music.lyrics.isEmpty {
            Text(music.isTide ? "No synced lyrics for this song." : "Lyrics come from Tide.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let now = music.progress(at: context.date) * music.duration + 0.2
                let current = music.lyrics.lastIndex { $0.time <= now } ?? -1
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(music.lyrics.enumerated()), id: \.offset) { index, line in
                                Button { music.seek(seconds: line.time) } label: {
                                    Text(line.text.isEmpty ? "\u{266A}" : line.text)
                                        .font(.system(size: index == current ? 15 : 13, weight: index == current ? .bold : .medium))
                                        .foregroundStyle(index == current ? .primary : index < current ? .tertiary : .secondary)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                        // Little room above the first line (it used to start a
                        // third of the way down); the current line sits near
                        // the top third, more of what comes next below it.
                        .padding(.top, 24)
                        .padding(.bottom, 120)
                    }
                    .onChange(of: current) { _, line in
                        withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(max(line, 0), anchor: UnitPoint(x: 0.5, y: 0.3)) }
                    }
                    .onAppear { proxy.scrollTo(max(current, 0), anchor: UnitPoint(x: 0.5, y: 0.3)) }
                    .animation(.smooth(duration: 0.3), value: current)
                }
            }
            .frame(height: 230)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                         .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }
}

/// Up next: click a song to play it now, drag to reorder.
private struct QueueView: View {
    @ObservedObject var music: Music

    var body: some View {
        if music.queue.isEmpty {
            Text("Nothing up next.").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
        } else {
            List {
                ForEach(Array(music.queue.prefix(30).enumerated()), id: \.offset) { index, song in
                    Button { music.playQueued(index) } label: {
                        HStack(spacing: 10) {
                            SongArt(url: music.queueArt.indices.contains(index) ? music.queueArt[index] : nil)
                            let parts = song.components(separatedBy: " \u{00B7} ")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(parts[0]).font(.system(size: 12, weight: index == 0 ? .semibold : .medium)).lineLimit(1)
                                if parts.count > 1 {
                                    Text(parts.dropFirst().joined(separator: " \u{00B7} ")).font(.system(size: 11))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    guard let first = from.first else { return }
                    music.moveQueued(from: first, to: to > first ? to - 1 : to)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 230)
        }
    }
}

/// Tide's tab switch: the chosen tab sits on a soft white pill that slides.
private struct PillSwitch: View {
    let options: [String]
    @Binding var selection: Int
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) { selection = i }
                } label: {
                    Text(options[i])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == i ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background {
                            if selection == i {
                                Capsule().fill(.white.opacity(0.18)).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

/// A song's cover in the drawer lists; a quiet note while it loads or when
/// there is none.
private struct SongArt: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.08))
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A drawer's own card, except inside the notch.
struct CardUnless: ViewModifier {
    let bare: Bool
    func body(content: Content) -> some View {
        if bare { content } else { content.card(radius: 18) }
    }
}
