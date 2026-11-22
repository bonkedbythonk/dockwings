// WaniKani reviews inside the WaniKani drawer. Loads every assignment that is
// available now, works through them in shuffled batches of 10, asks meaning
// and (kanji, vocabulary) reading in random order, and sends each item to
// POST /v2/reviews once both parts are right, with the wrong-answer counts.
// A wrong part comes back later in the batch and opens the item's info
// (meanings, readings with audio, mnemonics with WaniKani's markup coloured,
// component radicals or kanji, context sentences, your synonyms and notes);
// after a right answer Tab opens it. Sending needs a token with the
// reviews:create permission; a failed send stays queued and is retried.
// The session lives in its own object, so typing never redraws the wings,
// and survives closing the drawer. `Demo a` uses fixed items and sends nothing;
// test key `Review <answer>` (demo only) answers the first question.
import AppKit
import AVFoundation
import SwiftUI

/// A subject with everything the review screen shows.
struct WKSubject {
    let id: Int
    /// radical, kanji, vocabulary or kana_vocabulary.
    let type: String
    let characters: String?
    /// Radicals without characters come as an SVG.
    var image: URL?
    let meanings: [(meaning: String, primary: Bool, accepted: Bool)]
    let whitelist: [String]
    let blacklist: [String]
    let readings: [WKReading]
    let meaningMnemonic: String
    let readingMnemonic: String?
    let meaningHint: String?
    let readingHint: String?
    let components: [Int]
    let sentences: [(ja: String, en: String)]
    /// Voice actor and mp3 address.
    let audios: [(voice: String, url: URL)]
    var synonyms: [String] = []
    var meaningNote: String?
    var readingNote: String?

    var hasReading: Bool { type == "kanji" || type == "vocabulary" }
    var primaryMeaning: String { meanings.first { $0.primary }?.meaning ?? meanings.first?.meaning ?? "" }
    var color: Color { type == "radical" ? WK.blue : type == "kanji" ? WK.pink : WK.purple }
    var kindName: String { type == "radical" ? "Radical" : type == "kanji" ? "Kanji" : "Vocabulary" }
    var acceptedMeanings: [String] { meanings.filter(\.accepted).map(\.meaning) + whitelist + synonyms }

    init(id: Int, type: String, characters: String?, image: URL? = nil,
         meanings: [(meaning: String, primary: Bool, accepted: Bool)], whitelist: [String] = [], blacklist: [String] = [],
         readings: [WKReading] = [], meaningMnemonic: String, readingMnemonic: String? = nil, meaningHint: String? = nil,
         readingHint: String? = nil, components: [Int] = [], sentences: [(ja: String, en: String)] = [],
         audios: [(voice: String, url: URL)] = []) {
        self.id = id; self.type = type; self.characters = characters; self.image = image; self.meanings = meanings
        self.whitelist = whitelist; self.blacklist = blacklist; self.readings = readings
        self.meaningMnemonic = meaningMnemonic; self.readingMnemonic = readingMnemonic
        self.meaningHint = meaningHint; self.readingHint = readingHint; self.components = components
        self.sentences = sentences; self.audios = audios
    }

    /// From a /subjects API object.
    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? Int, let type = json["object"] as? String, let d = json["data"] as? [String: Any] else { return nil }
        let auxList = d["auxiliary_meanings"] as? [[String: Any]] ?? []
        func aux(_ kind: String) -> [String] { auxList.filter { $0["type"] as? String == kind }.compactMap { $0["meaning"] as? String } }
        let images = d["character_images"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        self.init(
            id: id, type: type, characters: d["characters"] as? String,
            image: (images.first { $0["content_type"] as? String == "image/svg+xml" }?["url"] as? String).flatMap(URL.init(string:)),
            meanings: (d["meanings"] as? [[String: Any]] ?? []).compactMap { m in
                (m["meaning"] as? String).map { ($0, m["primary"] as? Bool ?? false, m["accepted_answer"] as? Bool ?? false) }
            },
            whitelist: aux("whitelist"), blacklist: aux("blacklist"),
            readings: (d["readings"] as? [[String: Any]] ?? []).compactMap { r in
                (r["reading"] as? String).map {
                    WKReading(reading: $0, primary: r["primary"] as? Bool ?? false, accepted: r["accepted_answer"] as? Bool ?? false,
                              type: r["type"] as? String)
                }
            },
            meaningMnemonic: d["meaning_mnemonic"] as? String ?? "", readingMnemonic: d["reading_mnemonic"] as? String,
            meaningHint: d["meaning_hint"] as? String, readingHint: d["reading_hint"] as? String,
            components: d["component_subject_ids"] as? [Int] ?? [],
            sentences: (d["context_sentences"] as? [[String: Any]] ?? []).compactMap { s in
                guard let ja = s["ja"] as? String, let en = s["en"] as? String else { return nil }
                return (ja, en)
            },
            audios: (d["pronunciation_audios"] as? [[String: Any]] ?? []).compactMap { a in
                guard a["content_type"] as? String == "audio/mpeg", let url = (a["url"] as? String).flatMap(URL.init(string:)),
                      let voice = (a["metadata"] as? [String: Any])?["voice_actor_name"] as? String,
                      seen.insert(voice).inserted else { return nil }
                return (voice, url)
            })
    }
}

@MainActor
final class WKReview: ObservableObject {
    static let shared = WKReview()

    enum Phase: Equatable { case idle, loading, asking, answered, finished, failed(String) }

    /// One item in the current batch.
    struct Card {
        let assignment: Int
        var subject: WKSubject
        var meaningDone = false
        var readingDone: Bool
        var wrongMeaning = 0
        var wrongReading = 0
    }

    @Published private(set) var phase = Phase.idle
    @Published var input = ""
    @Published private(set) var card: Card? { didSet { syncTile() } }
    @Published private(set) var askingReading = false
    @Published private(set) var verdict: WKVerdict?
    @Published var showInfo = false
    /// Message under the field when an answer is asked again.
    @Published private(set) var message: String?
    /// Bumped to shake the field.
    @Published private(set) var shakes = 0
    @Published private(set) var finished = 0 { didSet { syncTile() } }
    @Published private(set) var total = 0 { didSet { syncTile() } }
    @Published private(set) var answers = 0
    @Published private(set) var rightAnswers = 0
    /// Why sending failed, shown until a send works.
    @Published private(set) var notice: String?
    /// Component radicals and kanji, for the info chips.
    @Published private(set) var parts: [Int: WKSubject] = [:]

    private var waiting: [Int: Int] = [:]
    private var order: [Int] = []
    private var batch: [Card] = []
    private var unsent: [(assignment: Int, meaning: Int, reading: Int)] = []
    private var filling = false
    private var player: AVPlayer?
    /// The answer given, kept while its result shows.
    private(set) var locked = ""

    var percent: Int { answers == 0 ? 100 : Int((Double(rightAnswers) / Double(answers) * 100).rounded()) }

    /// The wing's tile shows the current item and progress while the drawer
    /// is closed mid-review.
    private func syncTile() {
        WaniKani.shared.setReviewTile(WKReviewTile(characters: card?.subject.characters, type: card?.subject.type ?? "",
                                                   progress: total == 0 ? 0 : Double(finished) / Double(total)))
    }

    func start() {
        send()
        WaniKani.shared.setReviewing(true)
        phase = .loading
        finished = 0; answers = 0; rightAnswers = 0; batch = []; card = nil; input = ""
        if Config.demo != nil {
            let demo = Self.demoItems
            parts = demo.parts
            batch = demo.items.enumerated().map { Card(assignment: $0.offset, subject: $0.element, readingDone: !$0.element.hasReading) }
            total = batch.count
            next()
            if let answer = UserDefaults.standard.string(forKey: "Review") { input = answer; submit() }
            return
        }
        guard let token = WaniKaniToken.load() else { phase = .failed("Add your token in Settings"); return }
        Task {
            let found = await WaniKani.all("assignments?immediately_available_for_review=true&hidden=false", token)
            waiting = [:]
            for a in found {
                if let id = a["id"] as? Int, let subject = (a["data"] as? [String: Any])?["subject_id"] as? Int { waiting[id] = subject }
            }
            order = waiting.keys.shuffled()
            total = order.count
            guard total > 0 else { phase = .finished; return }
            await fill(token)
            if card == nil, !batch.isEmpty { next() }
        }
    }

    func quit() {
        phase = .idle
        card = nil; batch = []; order = []; input = ""; player = nil
        send()
        WaniKani.shared.setReviewing(false)
        WaniKani.shared.refresh()
    }

    /// Tops the batch up to 10 items, loading their subjects and notes.
    private func fill(_ token: String) async {
        guard !filling, batch.count < 10, !order.isEmpty else { return }
        filling = true
        defer { filling = false }
        let take = Array(order.prefix(10 - batch.count))
        let ids = take.compactMap { waiting[$0] }
        async let subjects = WaniKani.all("subjects?ids=" + ids.map(String.init).joined(separator: ","), token)
        async let notes = WaniKani.all("study_materials?subject_ids=" + ids.map(String.init).joined(separator: ","), token)
        var byId: [Int: WKSubject] = [:]
        for s in await subjects { if let subject = WKSubject(s) { byId[subject.id] = subject } }
        guard !byId.isEmpty else {
            if batch.isEmpty { phase = .failed("WaniKani didn't answer. Try again.") }
            return
        }
        for n in await notes {
            guard let d = n["data"] as? [String: Any], let id = d["subject_id"] as? Int else { continue }
            byId[id]?.synonyms = d["meaning_synonyms"] as? [String] ?? []
            byId[id]?.meaningNote = d["meaning_note"] as? String
            byId[id]?.readingNote = d["reading_note"] as? String
        }
        let missing = Set(byId.values.flatMap(\.components)).subtracting(parts.keys)
        if !missing.isEmpty {
            for s in await WaniKani.all("subjects?ids=" + missing.map(String.init).joined(separator: ","), token) {
                if let subject = WKSubject(s) { parts[subject.id] = subject }
            }
        }
        order.removeFirst(take.count)
        for a in take {
            guard let id = waiting[a], let subject = byId[id] else { total -= 1; continue }
            batch.append(Card(assignment: a, subject: subject, readingDone: !subject.hasReading))
        }
    }

    /// Picks the next question, not the same item twice in a row if avoidable.
    private func next() {
        input = ""; verdict = nil; message = nil; showInfo = false
        guard !batch.isEmpty else {
            if order.isEmpty { phase = .finished; card = nil; send(); WaniKani.shared.refresh() } else { phase = .loading; card = nil }
            return
        }
        let others = batch.indices.filter { batch[$0].assignment != card?.assignment }
        let i = others.randomElement() ?? batch.indices.randomElement()!
        let c = batch[i]
        askingReading = c.meaningDone ? true : c.readingDone ? false : Bool.random()
        card = c
        phase = .asking
        if batch.count < 5, Config.demo == nil, let token = WaniKaniToken.load() {
            Task { await fill(token); if phase == .loading { next() } }
        }
    }

    /// Return: checks the answer, or goes on after one.
    func submit() {
        if phase == .answered { next(); return }
        guard phase == .asking, let c = card, let i = batch.firstIndex(where: { $0.assignment == c.assignment }) else { return }
        let result = askingReading
            ? WKCheck.reading(input, readings: c.subject.readings, kanji: c.subject.type == "kanji")
            : WKCheck.meaning(input, accepted: c.subject.acceptedMeanings, blacklist: c.subject.blacklist)
        if case .again(let text) = result {
            message = text
            withAnimation(.linear(duration: 0.35)) { shakes += 1 }
            return
        }
        if askingReading { input = Kana.hiragana(input, final: true) }
        locked = input
        answers += 1
        let right = result != .wrong
        if right { rightAnswers += 1 }
        if askingReading {
            if right { batch[i].readingDone = true } else { batch[i].wrongReading += 1 }
        } else {
            if right { batch[i].meaningDone = true } else { batch[i].wrongMeaning += 1 }
        }
        card = batch[i]
        verdict = result
        message = result == .close ? "Close enough: \(c.subject.primaryMeaning)" : nil
        showInfo = !right
        phase = .answered
        if batch[i].meaningDone, batch[i].readingDone {
            let done = batch.remove(at: i)
            finished += 1
            unsent.append((done.assignment, done.wrongMeaning, done.wrongReading))
            send()
        }
    }

    /// Sends finished items; a failure keeps them for the next try.
    private func send() {
        guard Config.demo == nil else { unsent = []; return }
        guard !unsent.isEmpty, let token = WaniKaniToken.load() else { return }
        let items = unsent
        unsent = []
        Task {
            for item in items {
                var request = URLRequest(url: URL(string: "https://api.wanikani.com/v2/reviews")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("20170710", forHTTPHeaderField: "Wanikani-Revision")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["review": [
                    "assignment_id": item.assignment, "incorrect_meaning_answers": item.meaning, "incorrect_reading_answers": item.reading,
                ]])
                let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200, 201: notice = nil
                case 422: break // Already reviewed elsewhere or no longer available.
                case 401, 403:
                    // A read-only token: stop instead of answering into nothing.
                    notice = nil
                    unsent.append(item)
                    if phase != .idle { phase = .failed("This token can't submit reviews. In Settings, replace it with one made with reviews:create.") }
                default:
                    notice = "Couldn't send a review; will retry"
                    unsent.append(item)
                }
            }
        }
    }

    func play(_ url: URL) {
        player = AVPlayer(url: url)
        player?.play()
    }

    private static var demoItems: (items: [WKSubject], parts: [Int: WKSubject]) {
        let parts = [
            1: WKSubject(id: 1, type: "radical", characters: "木", meanings: [("Tree", true, true)], meaningMnemonic: ""),
            2: WKSubject(id: 2, type: "radical", characters: "一", meanings: [("Ground", true, true)], meaningMnemonic: ""),
            3: WKSubject(id: 3, type: "kanji", characters: "大", meanings: [("Big", true, true)], meaningMnemonic: ""),
            4: WKSubject(id: 4, type: "kanji", characters: "人", meanings: [("Person", true, true)], meaningMnemonic: ""),
        ]
        var adult = WKSubject(
            id: 11, type: "vocabulary", characters: "大人", meanings: [("Adult", true, true), ("Grown Up", false, true)],
            readings: [WKReading(reading: "おとな", primary: true, accepted: true, type: nil)],
            meaningMnemonic: "A <kanji>big</kanji> <kanji>person</kanji> is an <vocabulary>adult</vocabulary>.",
            readingMnemonic: "An exception: not だいじん. An <vocabulary>adult</vocabulary> says <reading>おとな</reading>, \"oh, tona...\"",
            components: [3, 4], sentences: [("大人になったら何になりたい？", "What do you want to be when you grow up?")])
        adult.synonyms = ["grown-up"]
        var notYet = WKSubject(
            id: 12, type: "kanji", characters: "未", meanings: [("Not Yet", true, true)], blacklist: ["end"],
            readings: [WKReading(reading: "み", primary: true, accepted: true, type: "onyomi"),
                       WKReading(reading: "いま", primary: false, accepted: false, type: "kunyomi")],
            meaningMnemonic: "The <radical>tree</radical> has one more branch on top than the <kanji>end</kanji>: it is <kanji>not yet</kanji> finished.",
            readingMnemonic: "\"<reading>Mi</reading>... me? <kanji>Not yet</kanji>!\"",
            meaningHint: "Compare with <kanji>末</kanji>, whose top line is longer.", components: [1, 2])
        notYet.readingNote = "Not 末: short top line."
        return ([
            notYet, adult,
            WKSubject(id: 13, type: "radical", characters: "木", meanings: [("Tree", true, true)],
                      meaningMnemonic: "A <radical>tree</radical>, with branches and roots."),
            WKSubject(id: 14, type: "kana_vocabulary", characters: "ありがとう", meanings: [("Thank You", true, true), ("Thanks", false, true)],
                      meaningMnemonic: "What you say to <vocabulary>thank you</vocabulary>.",
                      sentences: [("ありがとう、助かった。", "Thanks, that helped.")]),
        ], parts)
    }
}

/// WaniKani mnemonic markup as coloured text.
func wkMarkup(_ text: String) -> AttributedString {
    var out = AttributedString()
    var rest = Substring(text)
    while let open = rest.range(of: #"<(\w+)>"#, options: .regularExpression) {
        out += AttributedString(String(rest[..<open.lowerBound]))
        let tag = rest[open].dropFirst().dropLast()
        guard let close = rest.range(of: "</\(tag)>", range: open.upperBound..<rest.endIndex) else {
            rest = rest[open.upperBound...]; continue
        }
        var run = AttributedString(String(rest[open.upperBound..<close.lowerBound]))
        switch tag {
        case "radical": run.backgroundColor = WK.blue.opacity(0.35)
        case "kanji": run.backgroundColor = WK.pink.opacity(0.35)
        case "vocabulary": run.backgroundColor = WK.purple.opacity(0.4)
        case "meaning": run.font = .system(size: 14, weight: .bold)
        case "reading": run.font = .system(size: 14, weight: .bold); run.foregroundColor = Color(red: 1, green: 0.82, blue: 0.48)
        default: break
        }
        out += run
        rest = rest[close.upperBound...]
    }
    return out + AttributedString(String(rest))
}

struct WaniKaniReviewView: View {
    @ObservedObject var review: WKReview
    @FocusState private var focused: Bool
    @State private var infoHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reviews · \(review.finished) / \(review.total)").monospacedDigit()
                Spacer()
                if review.answers > 0 { Text("\(review.percent)% right").monospacedDigit() }
                IconButton(symbol: "xmark", size: 11) { review.quit() }
            }
            .font(.system(size: 13)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(WK.pink).frame(width: geo.size.width * Double(review.finished) / Double(max(review.total, 1)))
                }
            }
            .frame(height: 4).padding(.top, 6).padding(.bottom, 12)
            switch review.phase {
            case .asking, .answered: if let card = review.card { question(card) }
            case .finished: finished
            case .failed(let text): Text(text).font(.system(size: 14)).padding(.vertical, 20)
            default: ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            if let notice = review.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.orange).padding(.top, 8)
            }
        }
    }

    private func question(_ card: WKReview.Card) -> some View {
        let s = card.subject
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(s.color)
                if let chars = s.characters {
                    Text(chars).font(.system(size: 64, weight: .bold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.4).padding(.horizontal, 12)
                } else if let url = s.image {
                    RadicalImage(url: url).frame(width: 56, height: 56)
                }
            }
            .frame(height: 120)
            HStack(spacing: 4) {
                Text(s.kindName)
                Text(review.askingReading ? "Reading" : "Meaning").fontWeight(.bold)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(review.askingReading ? Color(white: 0.16) : Color(white: 0.27)))
            .padding(.top, 10).padding(.bottom, 8)
            HStack {
                TextField(review.askingReading ? "答え" : "Your response", text: $review.input)
                    .textFieldStyle(.plain).font(.system(size: 17))
                    .focused($focused)
                    .onSubmit {
                        review.submit()
                        // Return makes the field select all its text; put the caret back at the end.
                        DispatchQueue.main.async {
                            for case let editor as NSTextView in NSApp.windows.compactMap(\.firstResponder) where editor.window?.isKeyWindow == true {
                                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                            }
                        }
                    }
                    .onKeyPress(.tab) {
                        guard review.phase == .answered else { return .ignored }
                        review.showInfo.toggle()
                        return .handled
                    }
                if let v = review.verdict { Text(v == .wrong ? "wrong" : v == .close ? "close" : "right").font(.system(size: 12)).opacity(0.85) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(fieldColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(review.verdict == nil ? 0.1 : 0), lineWidth: 1))
            .modifier(Shake(amount: CGFloat(review.shakes)))
            .onChange(of: review.input) { _, text in
                if review.phase == .answered { if text != review.locked { review.input = review.locked }; return }
                if review.askingReading {
                    let kana = Kana.hiragana(text)
                    if kana != text { review.input = kana }
                }
            }
            HStack {
                if let message = review.message { Text(message) }
                Spacer()
                if review.phase == .answered {
                    Button(review.showInfo ? "Hide info" : "Info (Tab)") { review.showInfo.toggle() }.buttonStyle(.plain)
                    Text("· Return: next")
                }
            }
            // Fixed height, so a result line never moves the drawer.
            .font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 16).padding(.top, 6)
            if review.showInfo {
                ScrollView {
                    info(card).padding(.top, 4)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { infoHeight = $0 }
                }
                .frame(height: min(max(infoHeight, 40), 240))
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: review.showInfo)
        .onAppear { focused = true }
        .onChange(of: review.phase) { focused = true }
    }

    private var fieldColor: Color {
        switch review.verdict {
        case .right, .close: Color(red: 0.53, green: 0.8, blue: 0).opacity(0.85)
        case .wrong: Color(red: 1, green: 0, blue: 0.2).opacity(0.8)
        default: Color.white.opacity(0.08)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.total == 0 ? "No reviews right now" : "Done: \(review.finished) reviewed, \(review.percent)% right")
                .font(.system(size: 14, weight: .semibold))
            Button { review.quit() } label: {
                Text("Back").frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(WK.pink.opacity(0.9)))
            }
            .buttonStyle(.plain).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        }
    }

    /// The part just asked first, then the other, parts, context.
    private func info(_ card: WKReview.Card) -> some View {
        let s = card.subject
        return VStack(alignment: .leading, spacing: 12) {
            if review.askingReading, s.hasReading { readingInfo(s); meaningInfo(s) } else { meaningInfo(s); if s.hasReading { readingInfo(s) } }
            let parts = s.components.compactMap { review.parts[$0] }
            if !parts.isEmpty {
                section(s.type == "kanji" ? "Radicals" : "Kanji") {
                    HStack(spacing: 6) {
                        ForEach(parts, id: \.id) { p in
                            Text("\(p.characters ?? "") \(p.primaryMeaning)").font(.system(size: 13)).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(p.color))
                        }
                    }
                }
            }
            if !s.sentences.isEmpty {
                section("Context") {
                    ForEach(Array(s.sentences.prefix(3).enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.ja).font(.system(size: 14))
                            Text(line.en).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func meaningInfo(_ s: WKSubject) -> some View {
        section("Meaning") {
            (Text(s.primaryMeaning).bold() + Text(s.meanings.filter { !$0.primary }.map { ", " + $0.meaning }.joined()))
                .font(.system(size: 14))
            if !s.synonyms.isEmpty {
                Text("Your synonyms: " + s.synonyms.joined(separator: ", ")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(wkMarkup(s.meaningMnemonic)).font(.system(size: 14))
            if let hint = s.meaningHint { Text(wkMarkup(hint)).font(.system(size: 13)).foregroundStyle(.secondary) }
            if let note = s.meaningNote, !note.isEmpty { Text("Your note: " + note).font(.system(size: 13)).italic() }
        }
    }

    private func readingInfo(_ s: WKSubject) -> some View {
        section("Reading") {
            if s.type == "kanji" {
                ForEach(["onyomi", "kunyomi", "nanori"], id: \.self) { kind in
                    let list = s.readings.filter { $0.type == kind }
                    if !list.isEmpty {
                        HStack(spacing: 6) {
                            Text(kind == "onyomi" ? "On'yomi" : kind == "kunyomi" ? "Kun'yomi" : "Nanori")
                                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                            ForEach(list, id: \.reading) { r in
                                Text(r.reading).font(.system(size: 14, weight: r.accepted ? .bold : .regular))
                                    .foregroundStyle(r.accepted ? .primary : .secondary)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Text(s.readings.map(\.reading).joined(separator: ", ")).font(.system(size: 14, weight: .bold))
                    ForEach(s.audios, id: \.voice) { a in
                        Button { review.play(a.url) } label: {
                            Label(a.voice, systemImage: "speaker.wave.2.fill").font(.system(size: 12))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let mnemonic = s.readingMnemonic { Text(wkMarkup(mnemonic)).font(.system(size: 14)) }
            if let hint = s.readingHint { Text(wkMarkup(hint)).font(.system(size: 13)).foregroundStyle(.secondary) }
            if let note = s.readingNote, !note.isEmpty { Text("Your note: " + note).font(.system(size: 13)).italic() }
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A one-shot sideways shake each time `amount` goes up.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(amount * .pi * 4), y: 0))
    }
}

/// A radical that has no character, drawn from WaniKani's SVG in white.
private struct RadicalImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        // Not a Group: an empty one never runs its task.
        ZStack {
            if let image { Image(nsImage: image).resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white) }
        }
        .task(id: url) {
            image = nil
            // The SVG strokes with CSS `var(--color-text, #000)`, which macOS doesn't draw; use plain black.
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let text = String(data: data, encoding: .utf8),
                  let svg = NSImage(data: Data(text.replacingOccurrences(of: #"var\(--[\w-]+,\s*([^)]+)\)"#, with: "$1",
                                                                        options: .regularExpression).utf8)) else { return }
            svg.isTemplate = true
            image = svg
        }
    }
}
