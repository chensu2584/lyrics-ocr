import Foundation

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

struct Region: Codable {
    let id: String
    let language: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var brightTextThreshold: UInt8?
    var ocrBrightnessThreshold: UInt8?
    var ignorePrefixes: [String]?

    func crop(in size: CGSize) -> CGRect {
        let left = (x * size.width).rounded()
        let top = (y * size.height).rounded()
        let right = ((x + width) * size.width).rounded()
        let bottom = ((y + height) * size.height).rounded()
        return CGRect(x: left, y: size.height - bottom, width: right - left, height: bottom - top)
    }
}

struct Template: Codable {
    let regions: [Region]

    func validate() throws {
        guard !regions.isEmpty else { throw Failure(L("模板至少需要一个字幕框。", "A template needs at least one region.")) }
        var ids = Set<String>()
        for region in regions {
            guard region.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil,
                  ids.insert(region.id).inserted else {
                throw Failure(L("字幕框 ID 必须唯一，只能用字母、数字、连字符和下划线。", "Region IDs must be unique and use only letters, digits, hyphens and underscores."))
            }
            guard region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
                  region.x + region.width <= 1.000000001,
                  region.y + region.height <= 1.000000001 else {
                throw Failure(L("字幕框 \(region.id) 的坐标超出画面。", "Region \(region.id) extends outside the frame."))
            }
        }
    }
}

struct Reading {
    let text: String
    let confidence: Float
    var needsReview = false
    var alternative: String?
    var key: String { text.filter { !$0.isWhitespace }.precomposedStringWithCanonicalMapping }
}

struct FrameReading {
    let time: Double
    let reading: Reading?
}

struct Cue: Codable {
    var start: Double
    var end: Double
    var text: String
    var needsReview = false
    var alternative: String?
}

func makeCues(_ frames: [FrameReading], end: Double) -> [Cue] {
    var readings = frames.map(\.reading)
    if readings.count >= 3 {
        for index in 1..<(readings.count - 1) {
            guard let before = frames[index - 1].reading,
                  let after = frames[index + 1].reading, before.key == after.key else { continue }
            guard let current = frames[index].reading else {
                readings[index] = before
                continue
            }
            if current.key != before.key,
               (current.confidence < 0.4 || oneSubstitution(current.key, before.key)) {
                readings[index] = before
            }
        }
    }
    var cues: [Cue] = []
    var index = 0
    while index < readings.count {
        guard let first = readings[index] else {
            index += 1
            continue
        }
        let firstIndex = index
        var variants: [String: (count: Int, confidence: Float)] = [:]
        var strongest: Float = 0
        var hasClearReading = false
        var alternatives: [String: Float] = [:]
        while index < readings.count, let reading = readings[index], reading.key == first.key {
            let previous = variants[reading.text, default: (0, 0)]
            variants[reading.text] = (previous.count + 1, previous.confidence + reading.confidence)
            strongest = max(strongest, reading.confidence)
            hasClearReading = hasClearReading || !reading.needsReview
            if let alternative = reading.alternative {
                alternatives[alternative] = max(alternatives[alternative, default: 0], reading.confidence)
            }
            index += 1
        }
        let text = variants.keys.sorted { left, right in
            let a = variants[left]!, b = variants[right]!
            if a.count != b.count { return a.count > b.count }
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            return left < right
        }.first ?? first.text
        let cueEnd = index < frames.count ? frames[index].time : end
        if cueEnd > frames[firstIndex].time {
            let alternative = alternatives.keys.sorted().max { alternatives[$0]! < alternatives[$1]! }
            cues.append(Cue(start: frames[firstIndex].time, end: cueEnd, text: text,
                            needsReview: index == firstIndex + 1 || strongest < 0.5 || !hasClearReading || alternative != nil,
                            alternative: alternative))
        }
    }
    return cues
}

private func oneSubstitution(_ left: String, _ right: String) -> Bool {
    guard left.count >= 6, left.count == right.count else { return false }
    return zip(left, right).filter { $0 != $1 }.count == 1
}

func combinedCues(_ tracks: [[Cue]], sampleInterval: Double) -> [Cue] {
    let times = Set(tracks.flatMap { $0.flatMap { [$0.start, $0.end] } }).sorted()
    var result: [Cue] = []
    var indices = tracks.map { _ in 0 }
    for (start, end) in zip(times, times.dropFirst()) {
        var active: [Cue] = []
        for (lane, track) in tracks.enumerated() {
            while indices[lane] < track.count && track[indices[lane]].end <= start {
                indices[lane] += 1
            }
            if indices[lane] < track.count, track[indices[lane]].start <= start {
                active.append(track[indices[lane]])
            }
        }
        if !active.isEmpty {
            let text = active.map(\.text).joined(separator: "\n")
            let needsReview = active.contains(where: \.needsReview)
            if let last = result.last, last.end == start, last.text == text {
                result[result.count - 1].end = end
                result[result.count - 1].needsReview = last.needsReview || needsReview
            } else {
                result.append(Cue(start: start, end: end, text: text, needsReview: needsReview))
            }
        }
    }

    // The two languages can appear one sampled frame apart during a fade.
    // Keep both lines together across that short fringe when their text agrees.
    var index = 0
    while index < result.count {
        let cue = result[index]
        if !cue.text.contains("\n"), cue.end - cue.start <= sampleInterval * 1.25 {
            if index > 0, result[index - 1].end == cue.start,
               result[index - 1].text.split(separator: "\n").count > 1,
               result[index - 1].text.split(separator: "\n").contains(Substring(cue.text)) {
                result[index - 1].end = cue.end
                result.remove(at: index)
                continue
            }
            if index + 1 < result.count, result[index + 1].start == cue.end,
               result[index + 1].text.split(separator: "\n").count > 1,
               result[index + 1].text.split(separator: "\n").contains(Substring(cue.text)) {
                result[index + 1].start = cue.start
                result.remove(at: index)
                continue
            }
        }
        index += 1
    }
    var merged: [Cue] = []
    for cue in result {
        if let last = merged.last, last.end == cue.start, last.text == cue.text {
            merged[merged.count - 1].end = cue.end
            merged[merged.count - 1].needsReview = last.needsReview || cue.needsReview
        } else {
            merged.append(cue)
        }
    }
    return merged
}

func srtTime(_ seconds: Double) -> String {
    let ms = Int((max(0, seconds) * 1000).rounded())
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60,
                  ms / 1000 % 60, ms % 1000)
}

func srt(_ cues: [Cue]) -> String {
    cues.enumerated().map { index, cue in
        "\(index + 1)\n\(srtTime(cue.start)) --> \(srtTime(cue.end))\n\(cue.text)\n\n"
    }.joined()
}

func lrc(_ cues: [Cue]) -> String {
    cues.map { cue in
        let cs = Int((max(0, cue.start) * 100).rounded())
        let time = String(format: "%02d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100)
        return "[\(time)]\(cue.text.replacingOccurrences(of: "\n", with: " / "))\n"
    }.joined()
}

func writeText(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
}

func writeJSON<T: Encodable>(_ object: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (encoder.encode(object) + Data([10])).write(to: url, options: .atomic)
}
