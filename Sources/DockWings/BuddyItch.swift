// itch.io as a second source for the buddy library. Searches
// itch.io for "<query> shimeji" (its search page; there is no API) and keeps
// results whose title mentions Shimeji, a desktop pet or a mascot. Installing reads the pack's page:
// free packs list their files there, and a POST to the file endpoint with the
// page's csrf token returns a signed download link. The archive (.zip, .rar
// or .7z; bsdtar opens all three) goes through BuddyLibrary.add, which copies
// only shime<N>.png. Paid and name-your-price packs list no files: those open
// in the browser instead. Breaks if itch.io changes its page markup.
import Foundation

struct ItchHit: Identifiable, Hashable {
    let page: URL
    let title: String
    let cover: URL?
    var id: String { page.absoluteString }

    /// The title without "[Shimeji]" tags and the word itself.
    var name: String {
        var s = title.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*shime[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\b(shimejis?|shimeiji|shimeji-ee)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -|:+").union(.whitespaces))
        return s.isEmpty ? title : s
    }

    /// Stable key for the thumbnail cache.
    var cacheKey: String {
        "itch-" + (page.host ?? "") + page.path.replacingOccurrences(of: "/", with: "-")
    }
}

enum ItchSource {
    enum Outcome { case installed(URL), browser, failed }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        r.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        return r
    }

    private static func text(_ url: URL) async -> String? {
        guard let (data, res) = try? await URLSession.shared.data(for: request(url)),
              (res as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Capture groups of every match.
    private static func matches(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
        }
    }

    private static func unescape(_ s: String) -> String {
        [("&amp;", "&"), ("&#039;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">")]
            .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    static func search(_ query: String) async -> [ItchHit] {
        var c = URLComponents(string: "https://itch.io/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query + " shimeji")]
        guard let url = c.url, let html = await text(url) else { return [] }
        var hits: [ItchHit] = []
        for cell in html.components(separatedBy: "class=\"game_cell ").dropFirst() {
            guard let link = matches(#"<a href="(https://[a-z0-9-]+\.itch\.io/[^"]+)"[^>]*class="title game_link"[^>]*>([^<]*)<"#, cell).first,
                  let page = URL(string: link[0]) else { continue }
            let title = unescape(link[1])
            // itch.io's search barely weighs "shimeji"; keep pet-like titles.
            guard ["shime", "desktop pet", "desktop buddy", "mascot"].contains(where: title.lowercased().contains) else { continue }
            let cover = matches(#"data-lazy_src="([^"]+)""#, cell).first.flatMap { URL(string: $0[0]) }
            if !hits.contains(where: { $0.page == page }) { hits.append(ItchHit(page: page, title: title, cover: cover)) }
        }
        return hits
    }

    static func install(_ hit: ItchHit, progress: @escaping @Sendable (Double) -> Void) async -> Outcome {
        guard let html = await text(hit.page),
              let token = matches(#"<meta name="csrf_token" value="([^"]+)""#, html).first?[0] else { return .failed }
        var uploads: [String] = []
        for m in matches(#"data-upload_id="(\d+)""#, html) where !uploads.contains(m[0]) { uploads.append(m[0]) }
        guard !uploads.isEmpty else { return .browser }
        let fm = FileManager.default
        for upload in uploads {
            guard let endpoint = URL(string: hit.page.absoluteString + "/file/\(upload)?source=view_game&as_props=1&after_download_lightbox=true")
            else { continue }
            var post = request(endpoint)
            post.httpMethod = "POST"
            post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            post.httpBody = "csrf_token=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
            guard let (data, _) = try? await URLSession.shared.data(for: post),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let link = (json["url"] as? String).flatMap(URL.init(string:)) else { continue }
            progress(0.3)
            guard let (file, res) = try? await URLSession.shared.download(for: request(link)),
                  (res as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: dir) }
            // Packs are a few MB; anything huge is not one.
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            guard size < 300_000_000, (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
            let archive = dir.appendingPathComponent(res.suggestedFilename ?? "pack.zip")
            guard (try? fm.moveItem(at: file, to: archive)) != nil else { continue }
            progress(0.8)
            if let pack = await Task.detached(operation: { BuddyLibrary.add(archive) }).value { return .installed(pack) }
        }
        return .failed
    }
}
