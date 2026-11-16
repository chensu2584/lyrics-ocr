import Foundation

struct Credit: Codable {
    let region: String
    let time: Double
    let text: String
}

struct SubtitleTrack: Codable {
    let region: Region
    var cues: [Cue]
}

struct VideoCues: Codable {
    let videoName: String
    let duration: Double
    let sampleInterval: Double
    var tracks: [SubtitleTrack]
    var combined: [Cue]
    var credits: [Credit]?

    func sourceIndices(in track: Int, for cue: Cue) -> [Int] {
        let lines = cue.text.components(separatedBy: "\n")
        return tracks[track].cues.indices.filter { index in
            let source = tracks[track].cues[index]
            return source.start < cue.end && source.end > cue.start && lines.contains(source.text)
        }
    }

    mutating func apply(_ fixes: [TextFix]) throws {
        let original = self
        for fix in fixes {
            guard let index = fix.cue, fix.pair == nil, combined.indices.contains(index) else {
                throw Failure(L("视频改字需要有效的 cue 编号（从 0 起）。", "A video fix needs a valid cue number (counting from 0)."))
            }
            let lanes = tracks.indices.filter { tracks[$0].region.id == fix.lang }
            let trackIndices = lanes.isEmpty ? tracks.indices.filter {
                tracks[$0].region.language.split(separator: "-").first == Substring(fix.lang)
            } : lanes
            guard trackIndices.count == 1, let track = trackIndices.first else {
                throw Failure(L("第 \(index) 句的字幕框 \(fix.lang) 不存在或有歧义。", "Cue \(index): region \(fix.lang) does not exist or is ambiguous."))
            }
            let indices = original.sourceIndices(in: track, for: original.combined[index])
            guard !indices.isEmpty else { throw Failure(L("第 \(index) 句没有 \(fix.lang) 字幕。", "Cue \(index) has no \(fix.lang) subtitle.")) }
            for source in indices {
                try fix.apply(to: &tracks[track].cues[source].text, index: index)
            }
        }
        if !fixes.isEmpty { combined = combinedCues(tracks.map(\.cues), sampleInterval: sampleInterval) }
    }
}

struct TextFix: Decodable {
    let no: Int?
    let cue: Int?
    let pair: Int?
    let lang: String
    let from: String
    let to: String

    func apply(to text: inout String, index: Int) throws {
        guard !from.isEmpty, let range = text.range(of: from, options: .literal) else {
            throw Failure(L("第 \(index) 句的 \(lang) 找不到「\(from)」，请检查改字表对应的识别版本。", "Cue \(index) (\(lang)) does not contain “\(from)”; check that the fixes file matches this OCR run."))
        }
        text.replaceSubrange(range, with: to)
    }
}

func readFixes(_ url: URL, track: Int?) throws -> [TextFix] {
    struct FixList: Decodable {
        enum CodingKeys: String, CodingKey { case fixes }
        let fixes: [TextFix]

        init(from decoder: Decoder) throws {
            if var entries = try? decoder.unkeyedContainer() {
                var fixes: [TextFix] = []
                while !entries.isAtEnd { fixes.append(try entries.decode(TextFix.self)) }
                self.fixes = fixes
            } else {
                fixes = try decoder.container(keyedBy: CodingKeys.self).decode([TextFix].self, forKey: .fixes)
            }
        }
    }
    let fixes = try JSONDecoder().decode(FixList.self, from: Data(contentsOf: url)).fixes
    let numbered = Set(fixes.compactMap(\.no))
    guard let track else {
        guard numbered.count <= 1 else { throw Failure(L("改字表含多首歌曲，请用 --track 指定曲号。", "The fixes file covers several tracks; choose one with --track.")) }
        return fixes
    }
    guard numbered.contains(track) else { throw Failure(L("改字表中没有曲号 \(track)。", "The fixes file has no entries for track \(track).")) }
    return fixes.filter { $0.no == track }
}

extension ImageDocument {
    mutating func apply(_ fixes: [TextFix]) throws {
        for fix in fixes {
            guard let index = fix.pair, fix.cue == nil, pairs.indices.contains(index) else {
                throw Failure(L("图片改字需要有效的 pair 编号（从 0 起）。", "An image fix needs a valid pair number (counting from 0)."))
            }
            switch fix.lang {
            case "ja": try fix.apply(to: &pairs[index].ja, index: index)
            case "zh": try fix.apply(to: &pairs[index].zh, index: index)
            default: throw Failure(L("图片改字的 lang 应为 ja 或 zh。", "An image fix's lang must be ja or zh."))
            }
        }
    }
}

struct LyricLine {
    let index: Int
    let time: Double
    let text: String
    let normalized: [Character]
}

func readTimedLyrics(_ url: URL) throws -> [LyricLine] {
    let contents = try String(contentsOf: url, encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: #"^\[(\d+):(\d+(?:\.\d+)?)\](.*)$"#)
    var lines: [LyricLine] = []
    for raw in contents.split(whereSeparator: \.isNewline) {
        let line = String(raw)
        guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let minutes = Range(match.range(at: 1), in: line).flatMap({ Double(line[$0]) }),
              let seconds = Range(match.range(at: 2), in: line).flatMap({ Double(line[$0]) }),
              let body = Range(match.range(at: 3), in: line) else { continue }
        let time = minutes * 60 + seconds
        guard time.isFinite else { throw Failure(L("LRC 时间无效：\(line)", "Invalid LRC time: \(line)")) }
        let text = line[body].trimmingCharacters(in: .whitespaces)
        lines.append(LyricLine(index: lines.count, time: time, text: text, normalized: normalizeLyrics(text)))
    }
    guard !lines.isEmpty else { throw Failure(L("LRC 没有带时间戳的歌词。", "The LRC file has no timestamped lines.")) }
    return lines.sorted { ($0.time, $0.index) < ($1.time, $1.index) }
}

struct Translation: Encodable {
    struct Doubt: Encodable {
        let index: Int
        let lrc: String
        let ocr: String
        let similarity: Double
    }
    var lines: [Int: String] = [:]
    var missed: [Int] = []
    var reused: [Int] = []
    var doubtful: [Doubt] = []
    var before: [Double] = []
}

func translateLyrics(_ lrc: [LyricLine], document: VideoCues, mapping: Alignment) throws -> Translation {
    guard let zh = document.tracks.firstIndex(where: { $0.region.language.hasPrefix("zh") }),
          let ja = document.tracks.firstIndex(where: { $0.region.language.hasPrefix("ja") }) else {
        throw Failure(L("--lrc 需要同时有中文和日文字幕框。", "--lrc needs both a Chinese and a Japanese region."))
    }

    struct Line {
        let lyric: LyricLine
        let end: Double
    }
    let sung = lrc.compactMap { line -> Line? in
        guard !line.normalized.isEmpty, !line.text.hasPrefix("♪") else { return nil }
        return Line(lyric: line, end: lrc.first { $0.time > line.time }?.time ?? .infinity)
    }

    func like(_ ja: [Character], _ line: [Character]) -> Double {
        guard !ja.isEmpty, !line.isEmpty else { return 0 }
        if String(ja).contains(String(line)) || String(line).contains(String(ja)) {
            return ja == line ? 1 : 0.9
        }
        return lyricSimilarity(ja, line)
    }

    struct Pair {
        let ja: String
        let zh: String
    }
    var groups: [Int: [Pair]] = [:]
    var report = Translation()
    var japaneseByTranslation: [Int: Set<Int>] = [:]
    for cue in document.combined {
        let sources = document.sourceIndices(in: ja, for: cue)
        for index in document.sourceIndices(in: zh, for: cue) {
            japaneseByTranslation[index, default: []].formUnion(sources)
        }
    }

    for (index, cue) in document.tracks[zh].cues.enumerated() {
        let sources = japaneseByTranslation[index, default: []].sorted()
        let pair = Pair(ja: sources.map { document.tracks[ja].cues[$0].text }.joined(), zh: cue.text)
        let japanese = normalizeLyrics(pair.ja)
        var assigned = Set<Int>()
        for mapped in mapping.map([cue]) {
            guard let start = sung.last(where: { $0.lyric.time <= mapped.start + 0.8 }) else {
                report.before.append(mapped.start)
                continue
            }
            let candidates = sung.filter { line in
                line.lyric.index == start.lyric.index || (line.lyric.time > start.lyric.time &&
                    min(mapped.end, line.end) - max(mapped.start, line.lyric.time) >= 0.4)
            }
            let best = candidates.max { a, b in
                func score(_ line: Line) -> Double {
                    like(japanese, line.lyric.normalized) + (line.lyric.index == start.lyric.index ? 0.15 : 0)
                }
                return score(a) < score(b)
            } ?? start
            if assigned.insert(best.lyric.index).inserted {
                groups[best.lyric.index, default: []].append(pair)
            }
        }
    }

    let sungLyrics = sung.map(\.lyric)
    for line in sungLyrics {
        guard let pairs = groups[line.index] else { continue }
        report.lines[line.index] = pairs.map(\.zh).joined(separator: " ")
        let similarity = like(normalizeLyrics(pairs.map(\.ja).joined()), line.normalized)
        if similarity < 0.6 {
            report.doubtful.append(.init(index: line.index, lrc: line.text,
                                         ocr: pairs.map(\.ja).joined(separator: " / "), similarity: similarity))
        }
    }

    for line in sungLyrics where report.lines[line.index] == nil {
        let twin = sungLyrics.first { other in
            guard other.normalized == line.normalized, let pairs = groups[other.index],
                  pairs.count == 1, let pair = pairs.first else { return false }
            return like(normalizeLyrics(pair.ja), line.normalized) >= 0.85
        }
        if let twin {
            report.lines[line.index] = report.lines[twin.index]
            report.reused.append(line.index)
        } else {
            report.missed.append(line.index)
        }
    }
    return report
}
