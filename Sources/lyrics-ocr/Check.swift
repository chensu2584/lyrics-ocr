import Foundation

struct CheckItem: Codable {
    let reason: String
    var reference: String?
    var suggestion: String?
    var language: String?
    var text: String?
}

struct Misreads: Codable {
    let zh: [String: String]
    let ja: [String: String]

    /// Look-alike misreadings Vision produced on real bilingual subtitles, confirmed by hand.
    /// Each key is what Vision read, each value what the frame actually showed. Only ordinary
    /// words are listed; `--misreads FILE.json` replaces this table.
    static let builtIn = Misreads(
        zh: [
            "千燥": "干燥", "睛空": "晴空", "风暴股": "风暴般", "点级": "点缀", "叙寥": "寂寥",
            "酒落": "洒落", "拾头": "抬头", "蹒踞": "蹒跚", "跟跑": "踉跄", "诡辦": "诡辩",
            "撤谎": "撒谎", "露肯": "露骨", "旳": "的", "兩後": "雨後", "欲穹": "欲穿",
            "矇曨": "矇矓", "𥻘": "粼"
        ],
        ja: [
            "叙しい": "寂しい", "呑み千す": "呑み干す", "香み": "呑み", "ルピー": "ルビー",
            "さょう": "さよう", "さょなら": "さよなら"
        ]
    )
}

struct ReviewEntry: Codable {
    var region: String?
    var cue: Cue?
    var pair: Int?
    var image: String?
    var issues: [CheckItem]
}

private func readReference(_ url: URL) throws -> [String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(whereSeparator: \.isNewline).compactMap { raw in
        let line = raw.replacingOccurrences(of: #"^(\[[0-9:.]+\])+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty || line.hasPrefix("♪") || line.hasPrefix("[") ? nil : line
    }
}

func normalizeLyrics(_ s: String) -> [Character] {
    let skip = Set(" 　、。，．,.!！?？「」『』“”\"'‘’…・〜~ー-—()（）")
    return Array(s.precomposedStringWithCompatibilityMapping.lowercased()).filter { !skip.contains($0) && !$0.isWhitespace }
}

func lyricSimilarity(_ a: [Character], _ b: [Character]) -> Double {
    if a == b { return 1 }
    guard a.count >= 2, b.count >= 2 else { return 0 }
    var grams: [String: Int] = [:]
    for i in 0..<(a.count - 1) { grams[String(a[i...i + 1]), default: 0] += 1 }
    var hit = 0
    for i in 0..<(b.count - 1) {
        let g = String(b[i...i + 1])
        if let n = grams[g], n > 0 { grams[g] = n - 1; hit += 1 }
    }
    return 2 * Double(hit) / Double(a.count + b.count - 2)
}

private func contains(_ haystack: [Character], _ needle: [Character]) -> Bool {
    guard !needle.isEmpty, needle.count <= haystack.count else { return false }
    return String(haystack).contains(String(needle))
}

/// Characters that differ between the OCR text and the reference line (longest common subsequence)
private func differing(_ ocr: [Character], _ ref: [Character]) -> (String, String) {
    var table = Array(repeating: Array(repeating: 0, count: ref.count + 1), count: ocr.count + 1)
    for i in stride(from: ocr.count - 1, through: 0, by: -1) {
        for j in stride(from: ref.count - 1, through: 0, by: -1) {
            table[i][j] = ocr[i] == ref[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
        }
    }
    var i = 0, j = 0
    var extra = "", missing = ""
    while i < ocr.count || j < ref.count {
        if i < ocr.count, j < ref.count, ocr[i] == ref[j] { i += 1; j += 1 }
        else if j < ref.count, i == ocr.count || table[i][j + 1] >= table[i + 1][j] { missing.append(ref[j]); j += 1 }
        else { extra.append(ocr[i]); i += 1 }
    }
    return (extra, missing)
}

private let smallYouon = Set("ゃゅょャュョ")
private let iRow = Set("きしちにひみりぎじぢびぴキシチニヒミリギジヂビピ")

struct Checker {
    private let refs: [(text: String, chars: [Character])]
    private let accepted: Set<String>
    private let misreads: Misreads
    private let script: String?

    init(reference: URL?, misreads: Misreads, script: String?) throws {
        let lines = try reference.map(readReference) ?? []
        let refs = lines.map { (text: $0, chars: normalizeLyrics($0)) }.filter { !$0.chars.isEmpty }
        self.refs = refs
        self.misreads = misreads
        self.script = script
        accepted = Set(refs.indices.flatMap { i in
            (1...3).filter { i + $0 <= refs.count }.map { span in
                String(refs[i..<(i + span)].flatMap(\.chars))
            }
        })
    }

    func issues(_ text: String, language: String) -> [CheckItem] {
        var items: [CheckItem] = []
        if language.hasPrefix("ja") {
            let ja = normalizeLyrics(text)
            let exact = accepted.contains(String(ja)) || refs.contains { contains($0.chars, ja) }
            if !exact, !ja.isEmpty,
               let best = refs.max(by: { lyricSimilarity(ja, $0.chars) < lyricSimilarity(ja, $1.chars) }),
               lyricSimilarity(ja, best.chars) >= 0.45 {
                let (extra, missing) = differing(ja, best.chars)
                items.append(CheckItem(reason: L("与参考歌词不同：多「\(extra)」少「\(missing)」",
                                                 "differs from the reference: extra “\(extra)”, missing “\(missing)”"),
                                       reference: best.text))
            }
            let chars = Array(text)
            for (k, c) in chars.enumerated() where smallYouon.contains(c) && (k == 0 || !iRow.contains(chars[k - 1])) {
                let pair = "\(k > 0 ? String(chars[k - 1]) : "")\(c)"
                items.append(CheckItem(reason: L("「\(pair)」：小写拗音通常跟在い段假名后",
                                                 "“\(pair)”: a small ゃゅょ normally follows an i-row kana")))
            }
            items += knownMisreads(text, rules: misreads.ja)
        }
        if language.hasPrefix("zh") {
            let simplified = (script ?? (language == "zh-Hant" ? "Hant" : "Hans")) == "Hans"
            let transform = StringTransform(simplified ? "Hant-Hans" : "Hans-Hant")
            let allowed = simplified ? Set<Character>() : Set<Character>("沉抛")
            var suggestion = ""
            var other = ""
            for char in text {
                let original = String(char)
                let replacement = isHan(char) && !allowed.contains(char)
                    ? original.applyingTransform(transform, reverse: false) ?? original : original
                if replacement != original { other.append(char) }
                suggestion += replacement
            }
            if !other.isEmpty {
                items.append(CheckItem(reason: simplified
                                        ? L("简体译文里的繁体字「\(other)」", "traditional characters in simplified text: “\(other)”")
                                        : L("繁体译文里的简体字「\(other)」", "simplified characters in traditional text: “\(other)”"),
                                       suggestion: suggestion))
            }
            items += knownMisreads(text, rules: misreads.zh)
        }
        return items.map { issue in
            var item = issue
            item.language = language
            item.text = text
            return item
        }
    }

    func review(_ document: VideoCues) -> [ReviewEntry] {
        document.tracks.flatMap { track in
            track.cues.compactMap { cue in
                var items = issues(cue.text, language: track.region.language)
                if cue.needsReview {
                    items.append(CheckItem(reason: cue.alternative == nil
                        ? L("帧数或识别置信度不足", "too few frames or low OCR confidence")
                        : L("两种图像的识别结果不同", "the two image variants read differently"),
                                           suggestion: cue.alternative))
                }
                return items.isEmpty ? nil : ReviewEntry(region: track.region.id, cue: cue, issues: items)
            }
        }
    }

    func review(_ document: ImageDocument) -> [ReviewEntry] {
        document.pairs.enumerated().compactMap { index, pair in
            var items = issues(pair.ja, language: "ja-JP") + issues(pair.zh, language: document.zhLanguage ?? "zh-Hant")
            if pair.needsReview {
                items.append(CheckItem(reason: L("行数不一致、置信度不足或两种图像的识别结果不同",
                                                   "line counts differ, low confidence, or the two image variants read differently")))
            }
            return items.isEmpty ? nil : ReviewEntry(pair: index, image: pair.image, issues: items)
        }
    }
}

private func knownMisreads(_ text: String, rules: [String: String]) -> [CheckItem] {
    rules.keys.sorted().compactMap { bad in
        guard !bad.isEmpty, text.contains(bad), let good = rules[bad] else { return nil }
        return CheckItem(reason: L("常见误读「\(bad)」→「\(good)」？", "known misreading “\(bad)” → “\(good)”?"), suggestion: good)
    }
}
