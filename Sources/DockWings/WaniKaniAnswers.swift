// WaniKani answer checking for reviews in the drawer: romaji turned into
// hiragana as you type a reading, katakana folded to hiragana, and the
// meaning check (blacklisted meanings wrong, accepted meanings, whitelist and
// your own synonyms right, small typos forgiven by a length-scaled edit
// distance, an approximation of WaniKani's own rule). A valid reading of the
// other kind for a kanji, or kana in a meaning, asks again instead of counting
// as wrong. No UI or networking here.
import Foundation

enum Kana {
    private static let table: [String: String] = {
        var t: [String: String] = ["a": "あ", "i": "い", "u": "う", "e": "え", "o": "お"]
        let rows: [(String, String)] = [
            ("k", "かきくけこ"), ("g", "がぎぐげご"), ("s", "さしすせそ"), ("z", "ざじずぜぞ"), ("t", "たちつてと"),
            ("d", "だぢづでど"), ("n", "なにぬねの"), ("h", "はひふへほ"), ("b", "ばびぶべぼ"), ("p", "ぱぴぷぺぽ"),
            ("m", "まみむめも"), ("r", "らりるれろ"), ("l", "らりるれろ"),
        ]
        for (c, kana) in rows { for (v, k) in zip("aiueo", kana) { t[c + String(v)] = String(k) } }
        for (c, base) in [("k", "き"), ("g", "ぎ"), ("n", "に"), ("h", "ひ"), ("b", "び"), ("p", "ぴ"), ("m", "み"), ("r", "り")] {
            for (v, small) in zip(["a", "u", "o"], ["ゃ", "ゅ", "ょ"]) { t[c + "y" + v] = base + small }
        }
        for (c, base) in [("sh", "し"), ("ch", "ち"), ("j", "じ"), ("sy", "し"), ("cy", "ち"), ("ty", "ち"), ("zy", "じ"),
                          ("jy", "じ"), ("dy", "ぢ"), ("chy", "ち"), ("shy", "し")] {
            for (v, small) in zip(["a", "u", "o", "e"], ["ゃ", "ゅ", "ょ", "ぇ"]) { t[c + v] = base + small }
        }
        t["shi"] = "し"; t["chi"] = "ち"; t["ji"] = "じ"; t["tsu"] = "つ"; t["fu"] = "ふ"
        t["ya"] = "や"; t["yu"] = "ゆ"; t["yo"] = "よ"; t["wa"] = "わ"; t["wo"] = "を"; t["wi"] = "うぃ"; t["we"] = "うぇ"
        t["fa"] = "ふぁ"; t["fi"] = "ふぃ"; t["fe"] = "ふぇ"; t["fo"] = "ふぉ"; t["va"] = "ゔぁ"; t["vi"] = "ゔぃ"
        t["vu"] = "ゔ"; t["ve"] = "ゔぇ"; t["vo"] = "ゔぉ"; t["ca"] = "か"; t["cu"] = "く"; t["co"] = "こ"
        t["ti"] = "てぃ"; t["di"] = "でぃ"; t["tu"] = "つ"; t["du"] = "づ"; t["si"] = "し"; t["zi"] = "じ"; t["hu"] = "ふ"
        for (v, k) in zip(["a", "i", "u", "e", "o"], ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]) { t["x" + v] = k; t["l" + v] = k }
        for (v, k) in zip(["ya", "yu", "yo"], ["ゃ", "ゅ", "ょ"]) { t["x" + v] = k; t["l" + v] = k }
        t["xtu"] = "っ"; t["ltu"] = "っ"; t["xtsu"] = "っ"; t["ltsu"] = "っ"; t["xn"] = "ん"
        return t
    }()

    /// Converts the romaji in `text` to hiragana, leaving kana as it is.
    /// While typing, an unfinished tail ("k", "ky", a lone "n") stays as
    /// letters; `final` turns a trailing "n" into ん.
    static func hiragana(_ text: String, final: Bool = false) -> String {
        let s = Array(text.lowercased())
        var out = ""
        var i = 0
        func vowelOrY(_ j: Int) -> Bool { j < s.count && "aiueoy".contains(s[j]) }
        while i < s.count {
            let c = s[i]
            if c == "-" { out += "ー"; i += 1; continue }
            guard c.isASCII, c.isLetter else { out.append(c); i += 1; continue }
            if c == "n" {
                let next: Character? = i + 1 < s.count ? s[i + 1] : nil
                if next == "'" { out += "ん"; i += 2; continue }
                if next == "n" {
                    // "nn" then a vowel is ん + な行 ("konnichi"); "nn" alone is ん.
                    if i + 2 < s.count { out += "ん"; i += vowelOrY(i + 2) ? 1 : 2; continue }
                    if final { out += "ん"; i += 2; continue }
                    out += "nn"; i += 2; continue
                }
                if let next, !"aiueoy".contains(next) { out += "ん"; i += 1; continue }
                if next == nil, final { out += "ん"; i += 1; continue }
            }
            // A doubled consonant is a small tsu: "kitte" -> きって.
            if i + 1 < s.count, s[i + 1] == c, "bcdfghjklmpqrstvwxyz".contains(c) { out += "っ"; i += 1; continue }
            var matched = false
            for len in stride(from: 4, through: 1, by: -1) where i + len <= s.count {
                if let k = table[String(s[i..<i + len])] { out += k; i += len; matched = true; break }
            }
            if !matched { out.append(c); i += 1 }
        }
        return out
    }

    /// Katakana as hiragana, for comparing readings.
    static func fold(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { s in
            (0x30A1...0x30F6).contains(s.value) ? Unicode.Scalar(s.value - 0x60)! : s
        }))
    }

    static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }
}

enum WKVerdict: Equatable {
    case right
    /// Right, with a small typo.
    case close
    case wrong
    /// Not graded: asks again with this message.
    case again(String)
}

/// One reading of a subject.
struct WKReading: Equatable {
    let reading: String
    let primary: Bool
    let accepted: Bool
    /// onyomi, kunyomi or nanori for kanji; nil for vocabulary.
    let type: String?
}

enum WKCheck {
    static func normal(_ s: String) -> String {
        let kept = s.lowercased().replacingOccurrences(of: "-", with: " ").unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept)).split(separator: " ").joined(separator: " ")
    }

    /// Typos allowed for an answer of this length.
    static func tolerance(_ length: Int) -> Int {
        length <= 3 ? 0 : length <= 5 ? 1 : length <= 7 ? 2 : 2 + (length - 7) / 7
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let old = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = old
            }
        }
        return row[b.count]
    }

    static func meaning(_ answer: String, accepted: [String], blacklist: [String]) -> WKVerdict {
        if Kana.hasKana(answer) { return .again("Answer in English") }
        let a = normal(answer)
        guard !a.isEmpty else { return .again("Type an answer") }
        if blacklist.map(normal).contains(a) { return .wrong }
        let options = accepted.map(normal)
        if options.contains(a) { return .right }
        if options.contains(where: { distance(a, $0) <= tolerance($0.count) }) { return .close }
        return .wrong
    }

    static func reading(_ answer: String, readings: [WKReading], kanji: Bool) -> WKVerdict {
        let a = Kana.fold(Kana.hiragana(answer, final: true)).trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return .again("Type an answer") }
        if a.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) { return .again("Answer in kana") }
        if readings.contains(where: { $0.accepted && Kana.fold($0.reading) == a }) { return .right }
        if kanji, readings.contains(where: { Kana.fold($0.reading) == a }) {
            let wanted = readings.first { $0.primary }?.type == "kunyomi" ? "kun'yomi" : "on'yomi"
            return .again("WaniKani wants the \(wanted) reading")
        }
        return .wrong
    }
}
