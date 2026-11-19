// The buddy's character library: Shimeji packs kept in
// ~/Library/Application Support/DockWings/Buddies/<Name>/, and the drawer
// that opens when you click the buddy: characters standing on a shelf, by
// series, with search; click one to download or switch). Packs come from the
// bundled catalog (shimejis.xyz packs, and complete packs bundled in
// art/Buddies), from itch.io (BuddyItch.swift),
// or by dropping a .zip/.rar/.7z or folder on the drawer; only shime<N>.png
// files are kept, never anything else a download carries (.jar, .exe, scripts).
// Packs are stored by catalog id: many characters share a name.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShimejiEntry: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let anime: String
    var img: String?

    var previewURL: URL {
        if let img, let url = URL(string: img) {
            return url
        }
        return URL(string: "https://sprites.shimejis.xyz/directory/\(id)/img/shime1.png")!
    }
}

@MainActor
final class ShimejiCache {
    static let shared = ShimejiCache()
    private let memory = NSCache<NSString, NSImage>()
    private let disk: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockWings/ShimejiThumbs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func image(for id: String) -> NSImage? {
        if let img = memory.object(forKey: id as NSString) { return img }
        let file = disk.appendingPathComponent("\(id).png")
        if let img = NSImage(contentsOf: file) {
            memory.setObject(img, forKey: id as NSString)
            return img
        }
        return nil
    }

    func store(_ image: NSImage, for id: String, data: Data?) {
        memory.setObject(image, forKey: id as NSString)
        if let data {
            let file = disk.appendingPathComponent("\(id).png")
            try? data.write(to: file)
        }
    }
}

@MainActor
final class BuddyCatalog: ObservableObject {
    static let shared = BuddyCatalog()

    @Published var entries: [ShimejiEntry] = []
    @Published var categories: [String] = ["All", "Installed"]
    /// Catalog entries by id; downloaded packs are stored under their id.
    private(set) var byID: [String: ShimejiEntry] = [:]

    private static let popularOrder = [
        "Code Geass",
        "Re:Zero",
        "Darling in the Franxx",
        "86 Eighty-Six",
        "Date A Live",
        "My Dress-Up Darling",
        "Rascal Does Not Dream of Bunny Girl Senpai",
        "Demon Slayer",
        "Spy x Family",
        "Jujutsu Kaisen",
        "Chainsaw Man",
        "Attack on Titan",
        "Naruto",
        "One Piece",
        "Dragon Ball Z",
        "Pokémon",
        "Genshin Impact",
        "Bleach",
        "Hunter x Hunter",
        "My Hero Academia",
        "Death Note",
        "JoJo's Bizarre Adventure",
        "Tokyo Ghoul",
        "One-Punch Man",
        "Vocaloid",
        "Haikyuu",
        "Bungo Stray Dogs",
        "Deltarune",
        "Undertale",
        "Doki Doki Literature Club"
    ]

    init() {
        BuddyLibrary.seedBundledPacks()
        load()
    }

    func load() {
        let bundleURL = Bundle.main.url(forResource: "shimeji_catalog", withExtension: "json")
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockWings/shimeji_catalog.json")
        let artURL = URL(fileURLWithPath: "art/shimeji_catalog.json")

        let candidates = [bundleURL, appSupportURL, artURL].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([ShimejiEntry].self, from: data),
               !decoded.isEmpty {
                self.setup(decoded)
                return
            }
        }
        self.setup(Self.fallback)
    }

    private func setup(_ list: [ShimejiEntry]) {
        entries = list
        byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let animeSet = Set(list.map(\.anime)).filter { $0 != "Community" }
        let prioritized = Self.popularOrder.filter { animeSet.contains($0) }
        let remaining = animeSet.subtracting(Self.popularOrder).sorted()
        categories = ["All", "Installed"] + prioritized + remaining + ["Community"]
    }

    private static let fallback: [ShimejiEntry] = [
        ShimejiEntry(id: "code-geass-cc-school", name: "C.C. (School Outfit)", anime: "Code Geass"),
        ShimejiEntry(id: "sw-zero-two-100094", name: "Zero Two", anime: "Darling in the Franxx"),
        ShimejiEntry(id: "marin-kitagawa-shimeji-c0b774", name: "Marin Kitagawa (School Outfit)", anime: "My Dress-Up Darling"),
        ShimejiEntry(id: "attack-on-titan-eren-jaeger", name: "Eren Jaeger", anime: "Attack on Titan"),
        ShimejiEntry(id: "attack-on-titan-mikasa-ackerman", name: "Mikasa Ackerman", anime: "Attack on Titan"),
        ShimejiEntry(id: "attack-on-titan-levi-ackerman-by-斬夜-bk", name: "Levi Ackerman", anime: "Attack on Titan"),
        ShimejiEntry(id: "naruto-naruto-uzumaki", name: "Naruto Uzumaki", anime: "Naruto"),
        ShimejiEntry(id: "naruto-kakashi", name: "Kakashi Hatake", anime: "Naruto"),
        ShimejiEntry(id: "naruto-gaara", name: "Gaara", anime: "Naruto"),
        ShimejiEntry(id: "dragon-ball-z-goku-by-aki-1-iniriki", name: "Goku", anime: "Dragon Ball Z"),
        ShimejiEntry(id: "dragon-ball-z-vegeta-by-aki-1-iniriki", name: "Vegeta", anime: "Dragon Ball Z"),
        ShimejiEntry(id: "one-piece-ace-01", name: "Ace", anime: "One Piece"),
        ShimejiEntry(id: "gojo-273993", name: "Satoru Gojo", anime: "Jujutsu Kaisen"),
        ShimejiEntry(id: "megumi-fushiguro-cdea95", name: "Megumi Fushiguro", anime: "Jujutsu Kaisen"),
        ShimejiEntry(id: "pokemon-charmander-by-cachomon", name: "Charmander", anime: "Pokémon"),
        ShimejiEntry(id: "pokemon-ampharos-by-krokus-00", name: "Ampharos", anime: "Pokémon"),
        ShimejiEntry(id: "hatsune-miku-alt-ver-1-a6764d", name: "Hatsune Miku", anime: "Vocaloid"),
        ShimejiEntry(id: "nahida-0004a7", name: "Nahida", anime: "Genshin Impact")
    ]
}

enum BuddyLibrary {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DockWings/Buddies")

    /// Pre-seeds bundled complete character packs from the app bundle or local art into Application Support.
    static func seedBundledPacks() {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Buddies"),
            URL(fileURLWithPath: "art/Buddies")
        ].compactMap { $0 }
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let packs = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for pack in packs where fm.fileExists(atPath: pack.appendingPathComponent("shime1.png").path) {
            let target = folder.appendingPathComponent(pack.lastPathComponent)
            let targetCount = (try? fm.contentsOfDirectory(atPath: target.path).count) ?? 0
            let sourceCount = (try? fm.contentsOfDirectory(atPath: pack.path).count) ?? 0
            if targetCount < sourceCount {
                try? fm.removeItem(at: target)
                try? fm.copyItem(at: pack, to: target)
            }
        }
    }

    /// Installed packs, by name.
    static func packs() -> [URL] {
        seedBundledPacks()
        // Hidden: downloads in progress.
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("shime1.png").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Where a catalog entry's pack lives. By id: many characters share a name.
    static func folder(for entry: ShimejiEntry) -> URL {
        folder.appendingPathComponent(entry.id.replacingOccurrences(of: "/", with: "-"))
    }

    private static func isImage(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
    }

    /// Downloads a Shimeji character pack from online sources.
    static func download(_ entry: ShimejiEntry, progress: @escaping (Double) -> Void) async -> URL? {
        let fm = FileManager.default
        let dest = folder(for: entry)

        // If a bundled pack is available, copy it immediately
        let bundled = [
            Bundle.main.resourceURL?.appendingPathComponent("Buddies/\(entry.id)"),
            URL(fileURLWithPath: "art/Buddies/\(entry.id)")
        ].compactMap { $0 }
        if let source = bundled.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("shime1.png").path) }) {
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: source, to: dest)) != nil {
                progress(1.0)
                return dest
            }
        }

        // Into a hidden folder first, so a failed or half download never
        // shows up as a pack or mixes with an older copy.
        let partial = folder.appendingPathComponent("." + dest.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        try? fm.createDirectory(at: partial, withIntermediateDirectories: true)
        func finish() -> URL? {
            guard fm.fileExists(atPath: partial.appendingPathComponent("shime1.png").path) else {
                try? fm.removeItem(at: partial)
                return nil
            }
            try? fm.removeItem(at: dest)
            guard (try? fm.moveItem(at: partial, to: dest)) != nil else {
                try? fm.removeItem(at: partial)
                return nil
            }
            return dest
        }

        let total = 46
        var completed = 0

        await withTaskGroup(of: (Int, Data?).self) { group in
            for n in 1...total {
                group.addTask {
                    guard let url = URL(string: "https://sprites.shimejis.xyz/directory/\(entry.id)/img/shime\(n).png") else {
                        return (n, nil)
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 12
                    // An error page served with 200 is not a frame.
                    guard let (data, res) = try? await URLSession.shared.data(for: req),
                          (res as? HTTPURLResponse)?.statusCode == 200, isImage(data) else {
                        return (n, nil)
                    }
                    return (n, data)
                }
            }
            for await (n, data) in group {
                completed += 1
                progress(Double(completed) / Double(total))
                if let data {
                    try? data.write(to: partial.appendingPathComponent("shime\(n).png"))
                }
            }
        }
        return finish()
    }

    /// Copies a pack's frames from an archive (.zip, .rar, .7z) or folder into the library;
    /// returns the new pack, or nil when it holds no shime1.png.
    static func add(_ source: URL) -> URL? {
        let fm = FileManager.default
        var root = source
        var temp: URL?
        defer { if let temp { try? fm.removeItem(at: temp) } }
        // bsdtar reads .zip, .rar and .7z, and refuses paths outside the target.
        if ["zip", "rar", "7z"].contains(source.pathExtension.lowercased()) {
            let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            temp = dir
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
            unzip.arguments = ["-xf", source.path, "-C", dir.path]
            guard (try? unzip.run()) != nil else { return nil }
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { return nil }
            root = dir
        }
        // The first folder (shallowest) holding shime1.png.
        let found = (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent == "shime1.png" }
            .min { $0.pathComponents.count < $1.pathComponents.count }
        guard let frames = found?.deletingLastPathComponent() else { return nil }
        let generic = ["img", root.lastPathComponent]
        let name = generic.contains(frames.lastPathComponent) ? source.deletingPathExtension().lastPathComponent : frames.lastPathComponent
        let dest = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        try? fm.removeItem(at: dest)
        guard (try? fm.createDirectory(at: dest, withIntermediateDirectories: true)) != nil else { return nil }
        for file in (try? fm.contentsOfDirectory(at: frames, includingPropertiesForKeys: nil)) ?? []
        where isFrame(file.lastPathComponent) {
            try? fm.copyItem(at: file, to: dest.appendingPathComponent(file.lastPathComponent))
        }
        // The pack's own moves: actions.xml (next to the frames or in a conf
        // folder above them, inside the pack) and only the .png files it names.
        let inside = root.standardizedFileURL.path
        let xml = ["conf/actions.xml", "../conf/actions.xml", "../../conf/actions.xml", "actions.xml"]
            .map { frames.appendingPathComponent($0).standardizedFileURL }
            .first { $0.path.hasPrefix(inside) && fm.fileExists(atPath: $0.path) }
        if let xml, (try? fm.copyItem(at: xml, to: dest.appendingPathComponent("actions.xml"))) != nil {
            for key in Set(ShimejiActions.parse(xml).flatMap { $0.frames.map(\.image) }) where !isFrame(key) {
                let from = frames.appendingPathComponent(key).standardizedFileURL
                let to = dest.appendingPathComponent(key).standardizedFileURL
                guard from.path.hasPrefix(frames.standardizedFileURL.path), to.path.hasPrefix(dest.standardizedFileURL.path),
                      fm.fileExists(atPath: from.path) else { continue }
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: from, to: to)
            }
        }
        return dest
    }

    /// shime<N>.png
    private static func isFrame(_ name: String) -> Bool {
        guard name.hasPrefix("shime"), name.hasSuffix(".png") else { return false }
        let n = name.dropFirst(5).dropLast(4)
        return !n.isEmpty && n.allSatisfy(\.isASCII) && n.allSatisfy(\.isNumber)
    }
}

/// Thumbnail for a Shimeji entry or local pack.
private struct ShimejiThumb: View {
    let entry: ShimejiEntry?
    let localPack: URL?
    /// Any other picture (an itch.io cover), with its cache key.
    var remote: (key: String, url: URL)? = nil

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: entry?.id ?? localPack?.path ?? remote?.key ?? "") {
            loadImage()
        }
    }

    private func loadImage() {
        if let localPack {
            let file = localPack.appendingPathComponent("shime1.png")
            if let img = NSImage(contentsOf: file) {
                self.image = img
                return
            }
        }
        if let entry {
            let bundled = [
                BuddyLibrary.folder(for: entry).appendingPathComponent("shime1.png"),
                Bundle.main.resourceURL?.appendingPathComponent("Buddies/\(entry.id)/shime1.png"),
                URL(fileURLWithPath: "art/Buddies/\(entry.id)/shime1.png")
            ].compactMap { $0 }
            if let path = bundled.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
               let img = NSImage(contentsOf: path) {
                self.image = img
                return
            }
        }
        guard let (key, url) = entry.map({ ($0.id, $0.previewURL) }) ?? remote else { return }
        if let cached = ShimejiCache.shared.image(for: key) {
            self.image = cached
            return
        }
        Task {
            guard let (data, res) = try? await URLSession.shared.data(from: url),
                  (res as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data) else { return }
            ShimejiCache.shared.store(img, for: key, data: data)
            await MainActor.run {
                self.image = img
            }
        }
    }
}

/// One character on the shelf: the sprite standing on a hairline, its name
/// below (white when installed, dimmed when not), and a thin line filling
/// under the name while it downloads. The current character's stretch of
/// the hairline is bright.
private struct ShelfCell: View {
    let name: String
    let help: String
    let installed: Bool
    let current: Bool
    let progress: Double?
    let thumb: ShimejiThumb
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                thumb.frame(width: 56, height: 56, alignment: .bottom)
                Rectangle().fill(.white.opacity(current ? 0.8 : 0.14)).frame(height: 1)
                Text(name)
                    .font(.system(size: 10, weight: current ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(installed ? 1 : 0.45))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 4)
                GeometryReader { g in
                    Rectangle().fill(.white.opacity(0.8)).frame(width: g.size.width * min(max(progress ?? 0, 0), 1))
                }
                .frame(width: 40, height: 1)
                .opacity(progress == nil ? 0 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(WidgetPress())
        .help(help)
    }
}

/// The drawer above the buddy: the character shelf, by series, with search.
struct BuddyDrawer: View {
    /// Packs out on the Dock.
    @State private var out = Set(BuddyRoster.paths)
    @ObservedObject private var catalog = BuddyCatalog.shared
    @State private var packs = BuddyLibrary.packs()
    @State private var query = ""
    @State private var selectedCategory = "All"
    @State private var downloading: [String: Double] = [:]
    @State private var note: String?
    @State private var targeted = false
    @State private var itchHits: [ItchHit] = []
    @State private var itchBusy: [String: Double] = [:]
    /// itch.io page -> installed pack path.
    @AppStorage("itchPacks") private var itchPacksJSON = "{}"

    private var filteredEntries: [ShimejiEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return catalog.entries.filter { entry in
            let matchCat = selectedCategory == "All" || entry.anime == selectedCategory
            guard matchCat else { return false }
            if q.isEmpty { return true }
            return entry.name.localizedCaseInsensitiveContains(q) ||
                   entry.anime.localizedCaseInsensitiveContains(q) ||
                   entry.id.localizedCaseInsensitiveContains(q)
        }
    }

    private var installedMatching: [URL] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return packs }
        return packs.filter { pack in
            let l = label(pack)
            return [pack.lastPathComponent, l.name, l.anime].contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Characters").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 150)
                }
                Button("Add…", action: choose).buttonStyle(.borderless).font(.system(size: 11))
            }
            // Series as a plain line of names; Installed last.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(catalog.categories.filter { $0 != "Installed" } + ["Installed"], id: \.self) { cat in
                        Button(cat) { selectedCategory = cat }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: selectedCategory == cat ? .semibold : .regular))
                            .foregroundStyle(selectedCategory == cat ? Color.white : Color.white.opacity(0.45))
                    }
                }
                // Room inside the scroll view, so the first name isn't clipped
                // by its edge; the negative padding keeps it in line with the title.
                .padding(.horizontal, 8)
            }
            // The drawer is sized to fit (fixedSize), so a horizontal scroll
            // view asks for its whole content width; pin it to the card.
            .frame(width: 510 - 32 + 16)
            .padding(.horizontal, -8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if selectedCategory == "Installed" {
                        shelf(installedMatching, id: \.self) { installedCell($0) }
                    } else {
                        shelf(filteredEntries, id: \.id) { entryCell($0) }
                        if !itchHits.isEmpty {
                            Text("On itch.io").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                            shelf(itchHits, id: \.id) { itchCell($0) }
                        }
                    }
                    if (selectedCategory == "Installed" ? installedMatching.isEmpty : filteredEntries.isEmpty && itchHits.isEmpty) {
                        Text(query.isEmpty ? "Nothing here yet. Drop a Shimeji .zip or folder on this drawer." : "No characters matching \"\(query)\"")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
            }
            .frame(maxHeight: 330)
            // itch.io is searched once typing pauses.
            .task(id: query) {
                itchHits = []
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { return }
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                let hits = await ItchSource.search(q)
                if !Task.isCancelled { itchHits = hits }
            }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(16)
        .frame(width: 510, height: 450)
        .card()
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(targeted ? 0.5 : 0), lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { targeted = $0 }
    }

    /// Rows of six characters standing on a shared hairline.
    @ViewBuilder
    private func shelf<T, ID: Hashable, Cell: View>(_ items: [T], id: KeyPath<T, ID>, cell: @escaping (T) -> Cell) -> some View {
        if !items.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 6), spacing: 16) {
                ForEach(items, id: id) { cell($0) }
            }
        }
    }

    /// Installed packs by folder name.
    private var installed: [String: URL] {
        Dictionary(packs.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// A downloaded pack's catalog name (its folder is the id), else the folder name.
    private func label(_ pack: URL) -> (name: String, anime: String) {
        guard let e = catalog.byID[pack.lastPathComponent] else { return (pack.lastPathComponent, "Installed") }
        return (e.name, e.anime)
    }

    /// Puts a character out on the Dock, or away again.
    private func activate(_ pack: URL) {
        BuddyRoster.toggle(pack.path)
        out = Set(BuddyRoster.paths)
    }

    /// Puts a newly added character out (alongside the others).
    private func bringOut(_ pack: URL) {
        if !BuddyRoster.paths.contains(pack.path) { BuddyRoster.toggle(pack.path) }
        UserDefaults.standard.set(true, forKey: "buddy")
        out = Set(BuddyRoster.paths)
    }

    @ViewBuilder
    private func packMenu(_ pack: URL) -> some View {
        Button("Only this one") {
            BuddyRoster.paths = [pack.path]
            UserDefaults.standard.set(true, forKey: "buddy")
            out = Set(BuddyRoster.paths)
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([pack]) }
        Button("Move to Trash") {
            try? FileManager.default.trashItem(at: pack, resultingItemURL: nil)
            packs = BuddyLibrary.packs()
        }
    }

    private func installedCell(_ pack: URL) -> some View {
        let l = label(pack)
        return ShelfCell(name: l.name, help: "\(l.name) · \(l.anime)", installed: true, current: out.contains(pack.path), progress: nil,
                         thumb: ShimejiThumb(entry: nil, localPack: pack)) { activate(pack) }
            .contextMenu { packMenu(pack) }
    }

    private func entryCell(_ entry: ShimejiEntry) -> some View {
        // From the pack list the drawer already holds: no disk reads per tile.
        let pack = installed[BuddyLibrary.folder(for: entry).lastPathComponent]
        return ShelfCell(name: entry.name, help: "\(entry.name) · \(entry.anime)", installed: pack != nil,
                         current: pack.map { out.contains($0.path) } ?? false, progress: downloading[entry.id],
                         thumb: ShimejiThumb(entry: entry, localPack: pack)) {
            if let pack { activate(pack) } else if downloading[entry.id] == nil { triggerDownload(entry) }
        }
        .contextMenu { if let pack { packMenu(pack) } }
    }

    private var itchPacks: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(itchPacksJSON.utf8))) ?? [:] }
        nonmutating set { itchPacksJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }

    private func itchCell(_ hit: ItchHit) -> some View {
        let pack = itchPacks[hit.id].flatMap { path in packs.first { $0.path == path } }
        return ShelfCell(name: hit.name, help: "\(hit.title) · itch.io", installed: pack != nil, current: pack.map { out.contains($0.path) } ?? false,
                         progress: itchBusy[hit.id],
                         thumb: ShimejiThumb(entry: nil, localPack: pack, remote: hit.cover.map { (hit.cacheKey, $0) })) {
            if let pack { activate(pack) } else if itchBusy[hit.id] == nil { install(hit) }
        }
        .contextMenu {
            Button("Open on itch.io") { NSWorkspace.shared.open(hit.page) }
            if let pack { packMenu(pack) }
        }
    }

    private func install(_ hit: ItchHit) {
        itchBusy[hit.id] = 0.1
        Task {
            let outcome = await ItchSource.install(hit) { p in Task { @MainActor in if itchBusy[hit.id] != nil { itchBusy[hit.id] = p } } }
            itchBusy[hit.id] = nil
            switch outcome {
            case .installed(let pack):
                packs = BuddyLibrary.packs()
                itchPacks[hit.id] = pack.path
                bringOut(pack)
                note = nil
            case .browser:
                NSWorkspace.shared.open(hit.page)
                note = "\(hit.name) is paid or name-your-price: opened on itch.io"
            case .failed:
                note = "No Shimeji frames found in \(hit.name)'s download"
            }
        }
    }

    private func triggerDownload(_ entry: ShimejiEntry) {
        downloading[entry.id] = 0.01
        Task {
            let dest = await BuddyLibrary.download(entry) { p in
                Task { @MainActor in
                    self.downloading[entry.id] = p
                }
            }
            await MainActor.run {
                self.downloading[entry.id] = nil
                self.packs = BuddyLibrary.packs()
                if let dest {
                    self.bringOut(dest)
                } else {
                    self.note = "Failed to download \(entry.name)"
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .folder] + ["rar", "7z"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose Shimeji packs (.zip or folder)"
        NSApp.activate()
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        let added = urls.compactMap(BuddyLibrary.add)
        packs = BuddyLibrary.packs()
        if let last = added.last { bringOut(last) }
        let failed = urls.count - added.count
        note = failed > 0 ? "\(failed) had no shime1.png" : nil
    }
}
