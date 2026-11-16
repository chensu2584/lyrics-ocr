import Foundation
import Testing
@testable import lyrics_ocr

/// End to end on the synthetic sample: render it, read the subtitles back with Vision, compare
/// with the known text, then align the trimmed, sped-up recording.
/// Set LYRICS_OCR_SKIP_E2E=1 to skip (for machines where Vision text recognition is unavailable).
@Test(.disabled(if: ProcessInfo.processInfo.environment["LYRICS_OCR_SKIP_E2E"] == "1"),
      .timeLimit(.minutes(5)))
func syntheticSampleRoundTrip() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-ocr-sample-\(UUID().uuidString)")
    try prepareOutput(folder)
    defer { try? FileManager.default.removeItem(at: folder) }
    try await writeSample(to: folder)

    let video = try await Video(url: folder.appendingPathComponent("sample.mp4"))
    let template = SampleSpec.template
    let result = try video.recognize(template: template, start: 0, end: video.duration, fps: 4)
    let combined = combinedCues(result.tracks, sampleInterval: 0.25)

    // Text: every line should come back, with a character error rate of at most 2%.
    var errors = 0, total = 0
    for line in SampleSpec.lines {
        let middle = (line.start + line.end) / 2
        let cue = combined.first { $0.start <= middle && $0.end > middle }
        let expected = Array(line.zh + "\n" + line.ja)
        errors += editDistance(Array(cue?.text ?? ""), expected)
        total += expected.count
        if let cue {
            #expect(abs(cue.start - line.start) <= 0.5, "\(line.zh) starts at \(cue.start)")
            #expect(abs(cue.end - line.end) <= 0.5, "\(line.zh) ends at \(cue.end)")
        }
    }
    let rate = Double(errors) / Double(total)
    #expect(rate <= 0.02, "character error rate \(rate)")
    #expect(combined.count == SampleSpec.lines.count)

    // The credit line is kept apart from the lyrics.
    #expect(result.credits.count == 1)
    #expect(result.credits.first?.text.hasPrefix("原诗") == true)

    // Audio: the second recording starts 5 s later and runs 0.8% faster.
    let mapping = try await align(video: video, audioURL: folder.appendingPathComponent("other-master.wav"),
                                  anchors: [], segments: [])
    let segment = try #require(mapping.segments.first)
    let scale = (segment.audioEnd - segment.audioStart) / (segment.videoEnd - segment.videoStart)
    #expect(abs(scale - 1 / SampleSpec.speed) < 0.0005, "scale \(scale)")
    #expect(abs(segment.audioStart - SampleSpec.otherTime(0)) < 0.02, "offset \(segment.audioStart)")

    // Lyric lines on the new timeline get their translations.
    let tracks = zip(template.regions, result.tracks).map { SubtitleTrack(region: $0, cues: $1) }
    let document = VideoCues(videoName: "sample.mp4", duration: video.duration, sampleInterval: 0.25,
                             tracks: tracks, combined: combined, credits: result.credits)
    let translation = try translateLyrics(readTimedLyrics(folder.appendingPathComponent("reading.lrc")),
                                          document: document, mapping: mapping)
    #expect(translation.missed.isEmpty)
    #expect(translation.lines.count == SampleSpec.lines.count)
    #expect(translation.lines[6] == "欲穷千里目")
}

private func editDistance(_ a: [Character], _ b: [Character]) -> Int {
    var previous = Array(0...b.count)
    for (i, x) in a.enumerated() {
        var current = [i + 1]
        for (j, y) in b.enumerated() {
            current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
        }
        previous = current
    }
    return previous[b.count]
}
