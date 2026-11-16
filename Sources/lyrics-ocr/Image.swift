import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Recognition of lyric images: white background, with Japanese / romaji / translation lines
/// in turn and the translation printed in a different color.
///
/// The image is drawn onto white and split into text rows by counting ink pixels per row. The
/// luma at the core of each row's strokes separates light translations (blue-grey, warm grey,
/// teal) from near-black originals and romaji, and each row is read with the matching language.
/// Black rows with Latin letters only are romaji. Each translation attaches to the original lines
/// right before it.
struct ImageLine: Codable {
    let image: String
    let top: Int
    let height: Int
    let kind: String          // "ja" / "romaji" / "zh"
    let text: String
    let confidence: Float
    var alternative: String?
    var needsReview: Bool?
    let core: Double          // stroke-core luma, separates black text from colored translations
}

struct ImagePair: Codable {
    var ja: String
    var romaji: String?
    var zh: String
    let image: String
    let top: Int
    var needsReview: Bool
}

struct ImageDocument: Codable {
    let images: [String]
    let lines: [ImageLine]
    var pairs: [ImagePair]
    var zhLanguage: String?
    var sources: [ImageSource]?
}

struct ImageSource: Codable {
    let file: String
    let url: String?
}

struct ImageOptions {
    var zhLanguage = "zh-Hant"
    var jaLanguage = "ja-JP"
    /// Ink: pixels darker than this luma
    var inkLuma = 200
    /// Rows whose stroke core is lighter than this are translations (colored or light grey)
    var coreThreshold = 70.0
}

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw Failure(L("无法读取图片：\(url.path)", "Could not read image: \(url.path)"))
    }
    return image
}

/// Draws onto a white RGBA8 bitmap (transparent PNGs count as white)
private func flatten(_ image: CGImage) throws -> (bytes: [UInt8], width: Int, height: Int, image: CGImage) {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let made: CGImage? = bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
    guard let flat = made else { throw Failure(L("无法处理图片。", "Could not process the image.")) }
    return (bytes, width, height, flat)
}

/// Splits text rows by horizontal projection; returns (top, bottom) pixel ranges, top down
private func textRows(_ bytes: [UInt8], width: Int, height: Int, inkLuma: Int) -> [(Int, Int)] {
    var ink = [Int](repeating: 0, count: height)
    for y in 0..<height {
        var count = 0
        for x in 0..<width {
            let o = (y * width + x) * 4
            let luma = (77 * Int(bytes[o]) + 150 * Int(bytes[o + 1]) + 29 * Int(bytes[o + 2])) >> 8
            if luma < inkLuma { count += 1 }
        }
        ink[y] = count
    }
    var rows: [(Int, Int)] = []
    var start: Int?
    var gap = 0
    // Allow a few blank pixels inside a row (kana padding, punctuation)
    let maxGap = max(4, height / 200)
    for y in 0..<height {
        if ink[y] > 0 {
            if start == nil { start = y }
            gap = 0
        } else if let s = start {
            gap += 1
            if gap > maxGap {
                rows.append((s, y - gap + 1))
                start = nil
                gap = 0
            }
        }
    }
    if let s = start { rows.append((s, height)) }
    // Rows this short are noise or rules
    return rows.filter { $0.1 - $0.0 >= 8 }
}

/// Stroke-core luma: the 10th percentile of ink-pixel luma. Black text is close to 0; light
/// translations such as blue-grey or warm grey stay above 100 at the core, whatever the hue.
private func coreLuma(_ bytes: [UInt8], width: Int, rows: (Int, Int), inkLuma: Int) -> Double {
    var histogram = [Int](repeating: 0, count: 256)
    var count = 0
    for y in rows.0..<rows.1 {
        for x in 0..<width {
            let o = (y * width + x) * 4
            let luma = (77 * Int(bytes[o]) + 150 * Int(bytes[o + 1]) + 29 * Int(bytes[o + 2])) >> 8
            if luma < inkLuma {
                histogram[luma] += 1
                count += 1
            }
        }
    }
    guard count > 0 else { return 255 }
    var seen = 0
    for (luma, n) in histogram.enumerated() {
        seen += n
        if seen * 10 >= count { return Double(luma) }
    }
    return 255
}

private let latinOnly = try! NSRegularExpression(pattern: #"^[\x20-\x7E’‘ōūāēīÔÛÂ]+$"#)

func readImages(_ urls: [URL], options: ImageOptions) throws -> ImageDocument {
    let requests = try Set([options.zhLanguage, options.jaLanguage]).reduce(into: [String: VNRecognizeTextRequest]()) { requests, language in
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard try request.supportedRecognitionLanguages().contains(language) else {
            throw Failure(L("此系统的 Vision 不支持 \(language)。", "Vision on this system does not support \(language)."))
        }
        request.recognitionLanguages = [language]
        request.usesLanguageCorrection = false
        requests[language] = request
    }
    var lines: [ImageLine] = []
    for url in urls {
        let flat = try flatten(try loadImage(url))
        let rows = textRows(flat.bytes, width: flat.width, height: flat.height, inkLuma: options.inkLuma)
        for row in rows {
            let pad = max(6, (row.1 - row.0) / 3)
            let rect = CGRect(x: 0, y: max(0, row.0 - pad), width: flat.width,
                              height: min(flat.height, row.1 + pad) - max(0, row.0 - pad))
            guard let crop = flat.image.cropping(to: rect) else { continue }
            let core = coreLuma(flat.bytes, width: flat.width, rows: row, inkLuma: options.inkLuma)
            let colored = core > options.coreThreshold
            let request = requests[colored ? options.zhLanguage : options.jaLanguage]!
            let primary = try recognizeText(crop, request: request)
            let alternate = try enlarged(crop).flatMap { try recognizeText($0, request: request) }
            guard let reading = compareReadings(primary, alternate) else { continue }
            let text = reading.text
            let range = NSRange(text.startIndex..., in: text)
            let kind = colored ? "zh" : (latinOnly.firstMatch(in: text, range: range) != nil ? "romaji" : "ja")
            lines.append(ImageLine(image: url.lastPathComponent, top: row.0, height: row.1 - row.0,
                                   kind: kind, text: text, confidence: reading.confidence, alternative: reading.alternative,
                                   needsReview: reading.needsReview ? true : nil, core: core))
        }
        log(L("\(url.lastPathComponent)：\(rows.count) 行", "\(url.lastPathComponent): \(rows.count) lines"))
    }
    // Pairing: a run of original lines (romaji may sit between them) followed by a run of translation lines
    var pairs: [ImagePair] = []
    var ja: [ImageLine] = []
    var romaji: [String] = []
    var zh: [ImageLine] = []
    func flush() {
        guard !ja.isEmpty, !zh.isEmpty else { return }
        if ja.count == zh.count {
            for (j, z) in zip(ja, zh) {
                pairs.append(ImagePair(ja: j.text, romaji: nil, zh: z.text, image: j.image, top: j.top,
                                       needsReview: j.confidence < 0.5 || z.confidence < 0.5 || j.needsReview == true || z.needsReview == true))
            }
            if ja.count == 1 { pairs[pairs.count - 1].romaji = romaji.joined(separator: " ") }
        } else {
            // Line counts differ (two lines merged into one, etc.): keep the run as one pair for manual review
            pairs.append(ImagePair(ja: ja.map(\.text).joined(separator: " "), romaji: romaji.joined(separator: " "),
                                   zh: zh.map(\.text).joined(separator: " "), image: ja[0].image, top: ja[0].top,
                                   needsReview: true))
        }
    }
    for line in lines {
        switch line.kind {
        case "zh":
            zh.append(line)
        case "romaji":
            romaji.append(line.text)
        default:
            if !zh.isEmpty {
                flush()
                ja = []
                romaji = []
                zh = []
            }
            ja.append(line)
        }
    }
    flush()
    return ImageDocument(images: urls.map(\.lastPathComponent), lines: lines, pairs: pairs, zhLanguage: options.zhLanguage)
}

func writeImageDocument(_ document: ImageDocument, to output: URL) throws {
    try writeJSON(document, to: output.appendingPathComponent("image.json"))
    let text = document.pairs.map { "\($0.zh)\n\($0.ja)" }.joined(separator: "\n\n")
    try writeText(text.isEmpty ? "" : text + "\n", to: output.appendingPathComponent("lyrics.txt"))
}

func imageSources(_ urls: [URL], remote: [String]) throws -> [ImageSource] {
    let names = urls.map(\.lastPathComponent)
    guard Set(names).count == names.count else { throw Failure(L("图片文件名必须唯一，才能保存原图和来源。", "Image file names must be unique so the originals and their sources can be kept.")) }
    guard remote.isEmpty || remote.count == 1 || remote.count == urls.count else {
        throw Failure(L("--source-url 可给一篇共用的来源网址，或按顺序给每张图一个网址。", "Give --source-url once for a shared page, or once per image in order."))
    }
    guard remote.allSatisfy({ address in
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }) else { throw Failure(L("--source-url 需要有效的 HTTP 或 HTTPS 网址。", "--source-url needs a valid HTTP or HTTPS address.")) }
    return names.enumerated().map { index, name in
        ImageSource(file: name, url: remote.count > 1 ? remote[index] : remote.first)
    }
}

func archiveImages(_ urls: [URL], to output: URL) throws {
    let manager = FileManager.default
    let folder = output.appendingPathComponent("image-sources", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    for url in urls {
        try manager.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
    }
}
