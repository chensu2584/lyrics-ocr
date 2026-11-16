import Foundation
import CoreGraphics

let toolVersion = "0.1.0"

private let usageChinese = """
用法
  lyrics-ocr sample 输出目录
      生成一支带双语字幕的合成示例视频、一份剪过片头并轻微变速的音源和对应模板
  lyrics-ocr select VIDEO --at 秒 --template 模板.json [--region zh=zh-Hans --region ja=ja-JP]
  lyrics-ocr preview VIDEO --at 秒 --out 图片.png
  lyrics-ocr extract VIDEO --template 模板.json --out 输出目录 [--audio AUDIO]
      [--fps 4] [--start 秒] [--end 秒] [--review-images] [--reference 歌词.lrc]
  lyrics-ocr align VIDEO AUDIO --cues video.json --out 输出目录
  lyrics-ocr image 图片… --out 输出目录 [--zh zh-Hant] [--ja ja-JP]
      白底歌词图（原文 / 罗马音 / 彩色译文逐行排列），图片按给出的顺序读
  lyrics-ocr fix video.json|image.json --fixes 改字表.json --out 输出目录 [--track 曲号]
  lyrics-ocr check 输出目录 [--reference 歌词.lrc] [--zh Hans|Hant] [--misreads 误读表.json] [--video VIDEO]
      圈出可疑的行：与参考歌词不同的日文、不合法的小写拗音、混入的另一种字形、常见误读

extract、align 和 image 支持 --fixes 改字表.json [--track 曲号]。
image 可用 --source-url URL 记录来源（可重复，按图片顺序）。
extract --audio 和 align 支持 --lrc 歌词.lrc，导出按歌词行号排列的译文。
手动音频对齐参数
  --anchor 视频秒=音源秒                     可重复；一个锚点平移，多个按段插值
  --segment 视频起点:终点=音源起点:终点      可重复；只导出列出的片段

时间可写秒数（42.5）或时分秒（00:00:42.500）。
界面语言跟随系统；设置 LYRICS_OCR_LANG=en 或 zh 可以指定。
lyrics-ocr --version 显示版本。
"""

private let usageEnglish = """
Usage
  lyrics-ocr sample OUTPUT_DIR
      Write a synthetic video with bilingual subtitles, a trimmed and slightly
      sped-up copy of its audio, and the matching template
  lyrics-ocr select VIDEO --at SECONDS --template TEMPLATE.json [--region zh=zh-Hans --region ja=ja-JP]
  lyrics-ocr preview VIDEO --at SECONDS --out FRAME.png
  lyrics-ocr extract VIDEO --template TEMPLATE.json --out OUTPUT_DIR [--audio AUDIO]
      [--fps 4] [--start SECONDS] [--end SECONDS] [--review-images] [--reference LYRICS.lrc]
  lyrics-ocr align VIDEO AUDIO --cues video.json --out OUTPUT_DIR
  lyrics-ocr image IMAGE… --out OUTPUT_DIR [--zh zh-Hant] [--ja ja-JP]
      Lyric images on a white background (original / romaji / colored translation,
      line by line), read in the order given
  lyrics-ocr fix video.json|image.json --fixes FIXES.json --out OUTPUT_DIR [--track NUMBER]
  lyrics-ocr check OUTPUT_DIR [--reference LYRICS.lrc] [--zh Hans|Hant] [--misreads MISREADS.json] [--video VIDEO]
      Flag suspicious lines: Japanese that differs from the reference lyrics, invalid
      small kana, characters from the other Chinese script, and known misreadings

extract, align and image accept --fixes FIXES.json [--track NUMBER].
image accepts --source-url URL to record where images came from (repeatable, in image order).
extract --audio and align accept --lrc LYRICS.lrc to export translations keyed by lyric line.
Manual audio alignment
  --anchor VIDEO_SEC=AUDIO_SEC                 repeatable; one anchor shifts, several interpolate
  --segment VSTART:VEND=ASTART:AEND            repeatable; only the listed spans are exported

Times are seconds (42.5) or hours:minutes:seconds (00:00:42.500).
Messages follow the system language; set LYRICS_OCR_LANG=en or zh to choose.
lyrics-ocr --version prints the version.
"""

struct Arguments {
    let paths: [String]
    let options: [String: [String]]

    init(_ values: [String], withKeys keys: Set<String>, repeated: Set<String> = [],
         switches: Set<String> = []) throws {
        var paths: [String] = []
        var options: [String: [String]] = [:]
        var index = 0
        while index < values.count {
            let value = values[index]
            index += 1
            if value == "--" {
                paths.append(contentsOf: values[index...])
                break
            }
            if !value.hasPrefix("--") {
                paths.append(value)
                continue
            }
            guard keys.contains(value) || switches.contains(value) else {
                throw Failure(L("未知参数 \(value)。", "Unknown option \(value)."))
            }
            guard repeated.contains(value) || options[value] == nil else {
                throw Failure(L("参数 \(value) 重复。", "Option \(value) was given more than once."))
            }
            if switches.contains(value) {
                options[value] = ["true"]
                continue
            }
            guard index < values.count, !values[index].hasPrefix("--") else {
                throw Failure(L("参数 \(value) 缺少值。", "Option \(value) needs a value."))
            }
            options[value, default: []].append(values[index])
            index += 1
        }
        self.paths = paths
        self.options = options
    }

    func path(_ key: String) throws -> URL {
        guard let value = options[key]?.first else { throw Failure(L("缺少 \(key)。", "Missing \(key).")) }
        return file(value)
    }

    func time(_ key: String, default defaultTime: Double? = nil) throws -> Double {
        if let raw = options[key]?.first { return try parseTime(raw) }
        if let defaultTime { return defaultTime }
        throw Failure(L("缺少 \(key)。", "Missing \(key)."))
    }

    func alignmentInputs() throws -> (anchors: [Anchor], segments: [Segment]) {
        let anchors = try options["--anchor", default: []].map { raw in
            let parts = raw.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw Failure(L("锚点格式应为 视频秒=音源秒。", "An anchor is written VIDEO_SEC=AUDIO_SEC."))
            }
            return Anchor(video: try parseTime(String(parts[0])), audio: try parseTime(String(parts[1])))
        }
        let segments = try options["--segment", default: []].map { raw in
            let sides = raw.split(separator: "=", omittingEmptySubsequences: false)
            guard sides.count == 2 else {
                throw Failure(L("分段格式应为 视频起点:终点=音源起点:终点。",
                                "A segment is written VSTART:VEND=ASTART:AEND."))
            }
            let video = sides[0].split(separator: ":", omittingEmptySubsequences: false)
            let audio = sides[1].split(separator: ":", omittingEmptySubsequences: false)
            guard video.count == 2, audio.count == 2 else {
                throw Failure(L("分段的起止时间请用秒数。", "Segment boundaries must be plain seconds."))
            }
            return Segment(videoStart: try parseTime(String(video[0])), videoEnd: try parseTime(String(video[1])),
                           audioStart: try parseTime(String(audio[0])), audioEnd: try parseTime(String(audio[1])))
        }
        guard anchors.isEmpty || segments.isEmpty else {
            throw Failure(L("--anchor 和 --segment 只能使用一种。", "Use either --anchor or --segment, not both."))
        }
        return (anchors, segments)
    }
}

/// Parses `42.5`, `01:12.5` or `00:01:12.500` into seconds.
func parseTime(_ raw: String) throws -> Double {
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    let values = parts.compactMap { Double($0) }
    guard (1...3).contains(parts.count), values.count == parts.count,
          values.allSatisfy({ $0.isFinite && $0 >= 0 }), values.last! < 1e8,
          values.count == 1 || (
              values.dropFirst().allSatisfy({ $0 < 60 }) &&
              values.dropLast().allSatisfy({ $0.rounded() == $0 && $0 < 1e6 })
          ) else {
        throw Failure(L("无效时间：\(raw)", "Invalid time: \(raw)"))
    }
    return values.reduce(0) { $0 * 60 + $1 }
}

private func file(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL }

func prepareOutput(_ url: URL) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: url.path) {
        let items = try manager.contentsOfDirectory(atPath: url.path)
        guard items.allSatisfy({ $0 == ".DS_Store" }) else {
            throw Failure(L("输出目录已有文件，请指定一个空目录：\(url.path)",
                            "The output directory is not empty; choose an empty one: \(url.path)"))
        }
    } else {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private extension Arguments {
    func optionalPath(_ key: String) -> URL? { options[key]?.first.map(file) }

    func fixes() throws -> [TextFix] {
        let track: Int?
        if let number = options["--track"]?.first {
            guard let parsed = Int(number), parsed > 0 else {
                throw Failure(L("--track 需要正整数曲号。", "--track needs a positive track number."))
            }
            track = parsed
        } else {
            track = nil
        }
        guard let url = optionalPath("--fixes") else {
            if track != nil { throw Failure(L("--track 需要搭配 --fixes。", "--track only works together with --fixes.")) }
            return []
        }
        return try readFixes(url, track: track)
    }

    func checker(reference: URL? = nil) throws -> Checker {
        let script = options["--zh"]?.first
        if let script, !["Hans", "Hant"].contains(script) {
            throw Failure(L("--zh 只能是 Hans 或 Hant。", "--zh must be Hans or Hant."))
        }
        return try Checker(reference: optionalPath("--reference") ?? reference,
                           misreads: loadMisreads(self), script: script)
    }
}

private func loadMisreads(_ arguments: Arguments) throws -> Misreads {
    guard let url = arguments.optionalPath("--misreads") else { return Misreads.builtIn }
    return try JSONDecoder().decode(Misreads.self, from: Data(contentsOf: url))
}

@main
struct Main {
    @MainActor
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            log(L("错误：", "Error: ") + error.localizedDescription)
            exit(1)
        }
    }

    @MainActor
    private static func run(_ values: [String]) async throws {
        guard let command = values.first, !["help", "-h", "--help"].contains(command) else {
            print(L(usageChinese, usageEnglish))
            return
        }
        if ["version", "--version"].contains(command) {
            print("lyrics-ocr \(toolVersion)")
            return
        }
        let rest = Array(values.dropFirst())
        let alignmentKeys: Set<String> = ["--anchor", "--segment"]
        let fixKeys: Set<String> = ["--fixes", "--track"]
        switch command {
        case "sample":
            let arguments = try Arguments(rest, withKeys: [])
            guard arguments.paths.count == 1 else {
                throw Failure(L("sample 需要一个输出目录。", "sample needs an output directory."))
            }
            let output = file(arguments.paths[0])
            try prepareOutput(output)
            try await writeSample(to: output)
            print(output.path)

        case "preview":
            let arguments = try Arguments(rest, withKeys: ["--at", "--out"])
            guard arguments.paths.count == 1 else {
                throw Failure(L("preview 需要一个视频路径。", "preview needs one video path."))
            }
            let video = try await Video(url: file(arguments.paths[0]))
            let image = try await video.preview(at: arguments.time("--at"))
            try writePNG(image, to: arguments.path("--out"))

        case "select":
            let arguments = try Arguments(rest, withKeys: ["--at", "--template", "--region"], repeated: ["--region"])
            guard arguments.paths.count == 1 else {
                throw Failure(L("select 需要一个视频路径。", "select needs one video path."))
            }
            let output = try arguments.path("--template")
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw Failure(L("模板文件已存在。", "The template file already exists."))
            }
            let lanes = try arguments.options["--region", default: ["zh=zh-Hans", "ja=ja-JP"]].map { raw in
                let parts = raw.split(separator: "=", omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[1].isEmpty else {
                    throw Failure(L("字幕框格式应为 ID=语言。", "A region is written ID=LANGUAGE."))
                }
                return (id: String(parts[0]), language: String(parts[1]))
            }
            try Template(regions: lanes.map {
                Region(id: $0.id, language: $0.language, x: 0, y: 0, width: 1, height: 1)
            }).validate()
            let video = try await Video(url: file(arguments.paths[0]))
            let image = try await video.preview(at: arguments.time("--at"))
            if let template = pickRegions(image: image, lanes: lanes) {
                try template.validate()
                try writeJSON(template, to: output)
                print(output.path)
            }

        case "extract":
            let arguments = try Arguments(rest, withKeys: alignmentKeys.union(fixKeys).union([
                "--template", "--out", "--audio", "--fps", "--start", "--end", "--reference", "--lrc", "--misreads"
            ]), repeated: alignmentKeys, switches: ["--review-images"])
            guard arguments.paths.count == 1 else {
                throw Failure(L("extract 需要一个视频路径。", "extract needs one video path."))
            }
            let source = file(arguments.paths[0])
            let video = try await Video(url: source)
            let output = try arguments.path("--out")
            let template = try JSONDecoder().decode(Template.self, from: Data(contentsOf: arguments.path("--template")))
            try template.validate()
            guard let fps = Double(arguments.options["--fps"]?.first ?? "4"), (0.5...30).contains(fps) else {
                throw Failure(L("--fps 应在 0.5 到 30 之间。", "--fps must be between 0.5 and 30."))
            }
            let start = try arguments.time("--start", default: 0)
            let end = try arguments.time("--end", default: video.duration)
            guard start < end, end <= video.duration else {
                throw Failure(L("识别时间范围超出视频。", "The time range lies outside the video."))
            }
            let inputs = try arguments.alignmentInputs()
            if arguments.options["--audio"] == nil, !inputs.anchors.isEmpty || !inputs.segments.isEmpty {
                throw Failure(L("使用锚点或分段时需要提供 --audio。", "--anchor and --segment need --audio."))
            }
            let lyrics = try arguments.optionalPath("--lrc").map(readTimedLyrics)
            if lyrics != nil, arguments.optionalPath("--audio") == nil {
                throw Failure(L("--lrc 需要搭配 --audio。", "--lrc needs --audio."))
            }
            let checker = try arguments.checker(reference: arguments.optionalPath("--lrc"))
            let fixes = try arguments.fixes()
            let result = try video.recognize(template: template, start: start, end: end, fps: fps)
            let tracks = zip(template.regions, result.tracks).map { SubtitleTrack(region: $0, cues: $1) }
            var document = VideoCues(videoName: source.lastPathComponent, duration: video.duration,
                                     sampleInterval: 1 / fps, tracks: tracks,
                                     combined: combinedCues(result.tracks, sampleInterval: 1 / fps),
                                     credits: result.credits)
            try document.apply(fixes)
            try prepareOutput(output)
            try writeVideo(document, to: output)
            try await writeReview(checker.review(document), document: document, video: video,
                                  allImages: arguments.options["--review-images"] != nil, to: output)
            if let audio = arguments.optionalPath("--audio") {
                let mapping = try await align(video: video, audioURL: audio, anchors: inputs.anchors, segments: inputs.segments)
                try writeAudio(document, mapping: mapping, lyrics: lyrics, to: output)
            }
            if document.combined.isEmpty {
                log(L("字幕为空，请检查框选区域和视频时间。",
                      "No subtitles found; check the template regions and the time range."))
            }
            print(output.path)

        case "align":
            let arguments = try Arguments(rest, withKeys: alignmentKeys.union(fixKeys).union(["--cues", "--out", "--lrc"]),
                                          repeated: alignmentKeys)
            guard arguments.paths.count == 2 else {
                throw Failure(L("align 需要视频路径和音源路径。", "align needs a video path and an audio path."))
            }
            let videoURL = file(arguments.paths[0])
            let video = try await Video(url: videoURL)
            var document = try JSONDecoder().decode(VideoCues.self, from: Data(contentsOf: arguments.path("--cues")))
            try Template(regions: document.tracks.map(\.region)).validate()
            guard document.videoName == videoURL.lastPathComponent, abs(document.duration - video.duration) < 0.05 else {
                throw Failure(L("video.json 和输入视频的名称或时长不一致。",
                                "video.json does not match the video's file name or duration."))
            }
            try document.apply(arguments.fixes())
            let inputs = try arguments.alignmentInputs()
            let lyrics = try arguments.optionalPath("--lrc").map(readTimedLyrics)
            let output = try arguments.path("--out")
            let mapping = try await align(video: video, audioURL: file(arguments.paths[1]),
                                          anchors: inputs.anchors, segments: inputs.segments)
            try prepareOutput(output)
            try writeAudio(document, mapping: mapping, lyrics: lyrics, to: output)
            print(output.path)

        case "image":
            let arguments = try Arguments(rest, withKeys: fixKeys.union([
                "--out", "--zh", "--ja", "--source-url", "--reference", "--misreads"
            ]), repeated: ["--source-url"])
            guard !arguments.paths.isEmpty else {
                throw Failure(L("image 需要至少一张图片。", "image needs at least one image."))
            }
            var options = ImageOptions()
            if let zh = arguments.options["--zh"]?.first { options.zhLanguage = zh }
            if let ja = arguments.options["--ja"]?.first { options.jaLanguage = ja }
            let checker = try Checker(reference: arguments.optionalPath("--reference"),
                                      misreads: loadMisreads(arguments), script: nil)
            let output = try arguments.path("--out")
            let urls = arguments.paths.map(file)
            let sources = try imageSources(urls, remote: arguments.options["--source-url"] ?? [])
            let fixes = try arguments.fixes()
            var document = try readImages(urls, options: options)
            document.sources = sources
            try document.apply(fixes)
            try prepareOutput(output)
            try archiveImages(urls, to: output)
            try writeImageDocument(document, to: output)
            let review = checker.review(document)
            try writeJSON(review, to: output.appendingPathComponent("review.json"))
            log(L("\(document.lines.count) 行，\(document.pairs.count) 对，待核对 \(review.count)",
                  "\(document.lines.count) lines, \(document.pairs.count) pairs, \(review.count) to review"))
            print(output.path)

        case "fix":
            let arguments = try Arguments(rest, withKeys: fixKeys.union(["--out", "--reference", "--misreads"]))
            guard arguments.paths.count == 1, arguments.optionalPath("--fixes") != nil else {
                throw Failure(L("fix 需要 video.json 或 image.json、--fixes 和 --out。",
                                "fix needs video.json or image.json, --fixes and --out."))
            }
            let source = file(arguments.paths[0])
            let output = try arguments.path("--out")
            let checker = try arguments.checker()
            let fixes = try arguments.fixes()
            let data = try Data(contentsOf: source)
            switch source.lastPathComponent {
            case "video.json":
                var document = try JSONDecoder().decode(VideoCues.self, from: data)
                try Template(regions: document.tracks.map(\.region)).validate()
                try document.apply(fixes)
                try prepareOutput(output)
                try writeVideo(document, to: output)
                try writeJSON(checker.review(document), to: output.appendingPathComponent("review.json"))
            case "image.json":
                var document = try JSONDecoder().decode(ImageDocument.self, from: data)
                try document.apply(fixes)
                try prepareOutput(output)
                if let sources = document.sources {
                    let folder = source.deletingLastPathComponent().appendingPathComponent("image-sources")
                    try archiveImages(sources.map { entry in
                        guard entry.file == URL(fileURLWithPath: entry.file).lastPathComponent else {
                            throw Failure(L("原图文件名无效：\(entry.file)", "Invalid source image name: \(entry.file)"))
                        }
                        return folder.appendingPathComponent(entry.file)
                    }, to: output)
                }
                try writeImageDocument(document, to: output)
                try writeJSON(checker.review(document), to: output.appendingPathComponent("review.json"))
            default:
                throw Failure(L("fix 的输入应为 video.json 或 image.json。", "fix reads video.json or image.json."))
            }
            print(output.path)

        case "check":
            let arguments = try Arguments(rest, withKeys: ["--reference", "--zh", "--misreads", "--video"])
            guard arguments.paths.count == 1 else {
                throw Failure(L("check 需要一个输出目录。", "check needs one output directory."))
            }
            let output = file(arguments.paths[0])
            let checker = try arguments.checker()
            let image = output.appendingPathComponent("image.json")
            if FileManager.default.fileExists(atPath: image.path) {
                let document = try JSONDecoder().decode(ImageDocument.self, from: Data(contentsOf: image))
                let review = checker.review(document)
                try writeJSON(review, to: output.appendingPathComponent("review.json"))
                printIssues(review)
                log(L("\(review.count) 处待看，写入 review.json", "\(review.count) items to review, written to review.json"))
            } else {
                let data = try Data(contentsOf: output.appendingPathComponent("video.json"))
                let document = try JSONDecoder().decode(VideoCues.self, from: data)
                try Template(regions: document.tracks.map(\.region)).validate()
                let video: Video?
                if let source = arguments.optionalPath("--video") {
                    let asset = try await Video(url: source)
                    guard source.lastPathComponent == document.videoName, abs(asset.duration - document.duration) < 0.05 else {
                        throw Failure(L("--video 与 video.json 的名称或时长不一致。",
                                        "--video does not match video.json's file name or duration."))
                    }
                    video = asset
                } else {
                    video = nil
                }
                let review = checker.review(document)
                try await writeReview(review, document: document, video: video, allImages: video != nil, to: output)
                printIssues(review)
            }

        default:
            throw Failure(L("未知命令 \(command)。运行 lyrics-ocr --help 查看用法。",
                            "Unknown command \(command). Run lyrics-ocr --help for usage."))
        }
    }

    private static func printIssues(_ review: [ReviewEntry]) {
        for entry in review {
            let location = entry.pair.map { "pair \($0)" } ??
                "\(entry.region ?? "") \(srtTime(entry.cue?.start ?? 0))"
            for issue in entry.issues {
                let text = issue.text ?? entry.cue?.text ?? ""
                print("\(location)\t\(issue.reason)\t\(text)" +
                    (issue.reference.map { "\t" + L("参考：", "reference: ") + $0 } ?? ""))
            }
        }
    }

    private static func writeVideo(_ document: VideoCues, to output: URL) throws {
        try writeJSON(document, to: output.appendingPathComponent("video.json"))
        try writeText(srt(document.combined), to: output.appendingPathComponent("video.srt"))
        let text = document.combined.map(\.text).joined(separator: "\n\n")
        try writeText(text.isEmpty ? "" : text + "\n", to: output.appendingPathComponent("lyrics.txt"))
        for track in document.tracks {
            try writeText(srt(track.cues), to: output.appendingPathComponent("video-\(track.region.id).srt"))
        }
    }

    private static func writeReview(_ review: [ReviewEntry], document: VideoCues, video: Video?,
                                    allImages: Bool, to output: URL) async throws {
        var entries = review
        let folder = output.appendingPathComponent("review")
        for index in entries.indices {
            guard let cue = entries[index].cue, let region = entries[index].region,
                  let track = document.tracks.first(where: { $0.region.id == region }) else { continue }
            let name = "\(region)-\(Int((cue.start * 1000).rounded())).png"
            let path = folder.appendingPathComponent(name)
            let hasChecks = entries[index].issues.count > (cue.needsReview ? 1 : 0)
            if let video, allImages || hasChecks {
                let time = cue.start + min((cue.end - cue.start) / 2, document.sampleInterval)
                let frame: CGImage
                do {
                    frame = try await video.preview(at: time)
                } catch {
                    log(L("无法截取 \(region) 在 \(time) 秒的画面：\(error.localizedDescription)",
                          "Could not capture \(region) at \(time) s: \(error.localizedDescription)"))
                    continue
                }
                let rect = track.region.crop(in: CGSize(width: frame.width, height: frame.height))
                if let crop = frame.cropping(to: CGRect(x: rect.minX, y: CGFloat(frame.height) - rect.maxY,
                                                       width: rect.width, height: rect.height)) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try writePNG(enlarged(crop) ?? crop, to: path)
                }
            }
            if FileManager.default.fileExists(atPath: path.path) { entries[index].image = "review/\(name)" }
        }
        try writeJSON(entries, to: output.appendingPathComponent("review.json"))
        log(L("\(entries.count) 处待看，写入 review.json", "\(entries.count) items to review, written to review.json"))
    }

    private static func writeAudio(_ document: VideoCues, mapping: Alignment, lyrics: [LyricLine]?, to output: URL) throws {
        if let lyrics {
            let translation = try translateLyrics(lyrics, document: document, mapping: mapping)
            try writeJSON(translation, to: output.appendingPathComponent("translation.json"))
        }
        try writeJSON(mapping, to: output.appendingPathComponent("alignment.json"))
        let cues = mapping.map(document.combined)
        try writeText(lrc(cues), to: output.appendingPathComponent("audio.lrc"))
        try writeText(srt(cues), to: output.appendingPathComponent("audio.srt"))
        for track in document.tracks {
            try writeText(lrc(mapping.map(track.cues)), to: output.appendingPathComponent("audio-\(track.region.id).lrc"))
        }
        if cues.isEmpty && !document.combined.isEmpty {
            log(L("匹配区间里没有字幕，请检查锚点或分段。",
                  "No subtitles fall inside the mapped range; check the anchors or segments."))
        }
    }
}
