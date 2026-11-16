import Foundation
import Testing
@testable import lyrics_ocr

// MARK: - Time parsing and export formats

@Test func parsesPlainSecondsAndClockTimes() throws {
    #expect(try parseTime("42.5") == 42.5)
    #expect(try parseTime("1:12") == 72)
    #expect(try parseTime("00:01:12.500") == 72.5)
}

@Test(arguments: ["", "-3", "abc", "1:75", "1.5:10", "1:2:3:4"])
func rejectsInvalidTimes(_ raw: String) {
    #expect(throws: Failure.self) { try parseTime(raw) }
}

@Test func formatsSRT() {
    let cues = [Cue(start: 1, end: 2.5, text: "春眠不觉晓\n春眠暁を覚えず"), Cue(start: 3723.4567, end: 3724, text: "x")]
    #expect(srt(cues) == """
        1
        00:00:01,000 --> 00:00:02,500
        春眠不觉晓
        春眠暁を覚えず

        2
        01:02:03,457 --> 01:02:04,000
        x


        """)
}

@Test func formatsLRCWithBothLanguagesOnOneLine() {
    #expect(lrc([Cue(start: 61.234, end: 62, text: "a\nb")]) == "[01:01.23]a / b\n")
}

@Test func readsTimedLyricsInTimeOrder() throws {
    let url = try temporaryFile("[00:05.00]second\n[00:01.50]first\n[ar:someone]\nno time\n")
    let lines = try readTimedLyrics(url)
    #expect(lines.map(\.text) == ["first", "second"])
    #expect(lines.map(\.index) == [1, 0])
    #expect(lines[0].time == 1.5)
}

// MARK: - Manual alignment

@Test func oneAnchorShiftsTheWholeTimeline() throws {
    let mapping = try #require(try manualAlignment(anchors: [Anchor(video: 42, audio: 37)], segments: [],
                                                   videoDuration: 100, audioDuration: 100))
    let cues = mapping.map([Cue(start: 2, end: 4, text: "before the audio starts"), Cue(start: 10, end: 12, text: "a")])
    #expect(cues.count == 1)
    #expect(abs(cues[0].start - 5) < 1e-9 && abs(cues[0].end - 7) < 1e-9)
}

@Test func severalAnchorsInterpolateAndExtendTheEdgeRates() throws {
    let mapping = try #require(try manualAlignment(
        anchors: [Anchor(video: 20, audio: 30), Anchor(video: 10, audio: 10)], segments: [],
        videoDuration: 30, audioDuration: 100))
    #expect(mapping.segments.count == 3)
    let mapped = mapping.map([Cue(start: 15, end: 16, text: "a"), Cue(start: 25, end: 26, text: "b")])
    #expect(mapped.map(\.start) == [20, 40])
    #expect(mapped.map(\.end) == [22, 42])
}

@Test func segmentsDropTheGapAndJoinACueThatSpansIt() throws {
    let mapping = try #require(try manualAlignment(
        anchors: [], segments: [Segment(videoStart: 5, videoEnd: 80, audioStart: 0, audioEnd: 75),
                                Segment(videoStart: 86, videoEnd: 182, audioStart: 75, audioEnd: 171)],
        videoDuration: 200, audioDuration: 171))
    let mapped = mapping.map([
        Cue(start: 1, end: 3, text: "outside"),
        Cue(start: 70, end: 90, text: "spans the cut"),
        Cue(start: 82, end: 84, text: "inside the cut")
    ])
    #expect(mapped.count == 1)
    #expect(mapped[0].text == "spans the cut")
    #expect(mapped[0].start == 65 && mapped[0].end == 79)
}

@Test func rejectsAnchorsThatGoBackwards() {
    #expect(throws: Failure.self) {
        try manualAlignment(anchors: [Anchor(video: 10, audio: 20), Anchor(video: 20, audio: 15)], segments: [],
                            videoDuration: 30, audioDuration: 30)
    }
}

@Test func rejectsOverlappingSegments() {
    #expect(throws: Failure.self) {
        try manualAlignment(anchors: [], segments: [
            Segment(videoStart: 0, videoEnd: 10, audioStart: 0, audioEnd: 10),
            Segment(videoStart: 5, videoEnd: 15, audioStart: 10, audioEnd: 20)
        ], videoDuration: 30, audioDuration: 30)
    }
}

// MARK: - Cue building

@Test func aSingleOddFrameIsSmoothedAway() {
    let good = Reading(text: "春眠不觉晓了", confidence: 0.9)
    let odd = Reading(text: "春眠不觉晚了", confidence: 0.9)
    let frames = [good, good, odd, good].enumerated().map { FrameReading(time: Double($0.offset) * 0.25, reading: $0.element) }
    let cues = makeCues(frames + [FrameReading(time: 1, reading: nil)], end: 2)
    #expect(cues.count == 1)
    #expect(cues[0].text == "春眠不觉晓了")
    #expect(cues[0].start == 0 && cues[0].end == 1)
}

@Test func languagesOneFrameApartStayTogether() {
    let zh = [Cue(start: 0, end: 2, text: "春眠不觉晓")]
    let ja = [Cue(start: 0.25, end: 2, text: "春眠暁を覚えず")]
    let combined = combinedCues([zh, ja], sampleInterval: 0.25)
    #expect(combined.count == 1)
    #expect(combined[0].text == "春眠不觉晓\n春眠暁を覚えず")
    #expect(combined[0].start == 0 && combined[0].end == 2)
}

// MARK: - Checks

@Test func flagsSmallKanaAfterANonIRowKana() {
    let checker = try! Checker(reference: nil, misreads: .builtIn, script: nil)
    let issues = checker.issues("さょなら", language: "ja-JP")
    #expect(issues.count == 2) // the small-kana rule and the known misreading
    #expect(issues.contains { $0.suggestion == "さよなら" })
    #expect(checker.issues("きょうは晴れ", language: "ja-JP").isEmpty)
}

@Test func scriptChecksRunOnlyForChinese() {
    let checker = try! Checker(reference: nil, misreads: .builtIn, script: nil)
    let mixed = checker.issues("呼喚", language: "zh-Hans")
    #expect(mixed.count == 1)
    #expect(mixed[0].suggestion == "呼唤")
    #expect(checker.issues("沉默", language: "zh-Hant").isEmpty)
    #expect(checker.issues("呼喚", language: "ja-JP").isEmpty)
}

@Test func knownMisreadingsSuggestTheFix() {
    let checker = try! Checker(reference: nil, misreads: .builtIn, script: nil)
    let issues = checker.issues("天气千燥", language: "zh-Hans")
    #expect(issues.map(\.suggestion) == ["干燥"])
}

@Test func comparesJapaneseWithTheReferenceLyrics() throws {
    let url = try temporaryFile("[00:01.00]春眠暁を覚えず\n[00:05.00]処処に啼鳥を聞く\n")
    let checker = try Checker(reference: url, misreads: Misreads(zh: [:], ja: [:]), script: nil)
    let issues = checker.issues("春眠暁を覚えす", language: "ja-JP")
    #expect(issues.count == 1)
    #expect(issues[0].reference == "春眠暁を覚えず")
    #expect(checker.issues("春眠暁を覚えず 処処に啼鳥を聞く", language: "ja-JP").isEmpty)
}

// MARK: - Fixes

private func twoLaneDocument() -> VideoCues {
    let zh = Region(id: "zh", language: "zh-Hans", x: 0, y: 0, width: 1, height: 0.5)
    let ja = Region(id: "ja", language: "ja-JP", x: 0, y: 0.5, width: 1, height: 0.5)
    let zhCues = [Cue(start: 0, end: 2, text: "天气千燥"), Cue(start: 2, end: 4, text: "春眠不觉晓")]
    let jaCues = [Cue(start: 0, end: 2, text: "乾いた"), Cue(start: 2, end: 4, text: "春眠暁を覚えず")]
    return VideoCues(videoName: "v.mp4", duration: 4, sampleInterval: 0.25,
                     tracks: [SubtitleTrack(region: zh, cues: zhCues), SubtitleTrack(region: ja, cues: jaCues)],
                     combined: combinedCues([zhCues, jaCues], sampleInterval: 0.25), credits: nil)
}

@Test func appliesAFixToTheTrackAndRebuildsCombinedCues() throws {
    var document = twoLaneDocument()
    try document.apply([TextFix(no: nil, cue: 0, pair: nil, lang: "zh", from: "千燥", to: "干燥")])
    #expect(document.tracks[0].cues[0].text == "天气干燥")
    #expect(document.combined[0].text == "天气干燥\n乾いた")
}

@Test func refusesAFixWhoseFromTextIsMissing() {
    var document = twoLaneDocument()
    #expect(throws: Failure.self) {
        try document.apply([TextFix(no: nil, cue: 1, pair: nil, lang: "zh", from: "千燥", to: "干燥")])
    }
}

@Test func multiTrackFixFilesNeedATrackNumber() throws {
    let url = try temporaryFile("""
        {"fixes": [
          {"no": 1, "cue": 0, "lang": "zh", "from": "a", "to": "b"},
          {"no": 2, "cue": 3, "lang": "ja", "from": "c", "to": "d"}
        ]}
        """)
    #expect(throws: Failure.self) { try readFixes(url, track: nil) }
    #expect(throws: Failure.self) { try readFixes(url, track: 3) }
    let fixes = try readFixes(url, track: 2)
    #expect(fixes.count == 1 && fixes[0].from == "c")
}

@Test func plainArrayFixFilesWork() throws {
    let url = try temporaryFile(#"[{"pair": 0, "lang": "zh", "from": "旳", "to": "的"}]"#)
    var image = ImageDocument(images: ["a.png"], lines: [],
                              pairs: [ImagePair(ja: "夜", zh: "我旳", image: "a.png", top: 0, needsReview: false)])
    try image.apply(readFixes(url, track: nil))
    #expect(image.pairs[0].zh == "我的")
}

// MARK: - Interface language

@Test func interfaceLanguageFollowsTheSystemUnlessOverridden() {
    #expect(InterfaceLanguage.resolve(override: nil, preferred: ["zh-Hans-CN", "en-US"]) == .chinese)
    #expect(InterfaceLanguage.resolve(override: nil, preferred: ["ja-JP", "zh-Hans"]) == .english)
    #expect(InterfaceLanguage.resolve(override: "en", preferred: ["zh-Hant-TW"]) == .english)
    #expect(InterfaceLanguage.resolve(override: "zh_CN", preferred: ["en-US"]) == .chinese)
    #expect(InterfaceLanguage.resolve(override: "fr", preferred: []) == .english)
}

// MARK: - Helpers

func temporaryFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-ocr-test-\(UUID().uuidString)")
    try Data(contents.utf8).write(to: url)
    return url
}
