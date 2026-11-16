import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

struct Video {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let duration: Double
    let transform: CGAffineTransform

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(L("找不到视频轨：\(url.path)", "No video track found: \(url.path)"))
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure(L("视频时长无效。", "The video duration is invalid.")) }
        self.asset = asset
        self.track = track
        self.duration = duration
        transform = try await track.load(.preferredTransform)
    }

    func preview(at time: Double) async throws -> CGImage {
        guard time >= 0, time < duration else {
            throw Failure(L("预览时间应在 0 和 \(duration) 秒之间。", "The preview time must be between 0 and \(duration) seconds."))
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000)).image
    }

    func recognize(template: Template, start: Double, end: Double, fps: Double) throws -> (tracks: [[Cue]], credits: [Credit]) {
        guard start < end, end <= duration else { throw Failure(L("识别时间范围超出视频。", "The time range lies outside the video.")) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                                       end: CMTime(seconds: end, preferredTimescale: 60_000))
        guard reader.canAdd(output) else { throw Failure(L("无法添加视频解码输出。", "Could not set up video decoding.")) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure(L("无法读取视频。", "Could not read the video.")) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        let lanes = try template.regions.map(Lane.init)
        var frames = lanes.map { _ in [FrameReading]() }
        var tick = 0
        var lastLog = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            let time = buffer.presentationTimeStamp.seconds
            let requestedTime = start + Double(tick) / fps
            if time >= end { break }
            guard time + 0.00001 >= requestedTime, let pixels = buffer.imageBuffer else { continue }
            try autoreleasepool {
                let image = oriented(CIImage(cvPixelBuffer: pixels))
                for (index, lane) in lanes.enumerated() {
                    let reading = try lane.recognize(image, at: max(start, time), with: context)
                    frames[index].append(FrameReading(time: max(start, time), reading: reading))
                }
            }
            tick = Int(floor((time - start + 0.00001) * fps)) + 1
            if time - lastLog >= 20 {
                log(String(format: L("OCR %.1f / %.1f 秒", "OCR %.1f / %.1f s"), time, end))
                lastLog = time
            }
        }
        if reader.status == .failed { throw reader.error ?? Failure(L("视频解码失败。", "Video decoding failed.")) }
        guard tick > 0 else { throw Failure(L("指定时间范围内没有可识别的视频帧。", "No video frames in the given time range.")) }
        let tracks = frames.map { makeCues($0, end: end) }
        for (index, lane) in lanes.enumerated() {
            log(L("\(lane.region.id): \(frames[index].count) 帧，实际 OCR \(lane.requests) 次，\(tracks[index].count) 条字幕", "\(lane.region.id): \(frames[index].count) frames, \(lane.requests) OCR passes, \(tracks[index].count) cues"))
        }
        return (tracks, lanes.flatMap(\.credits))
    }

    private func oriented(_ image: CIImage) -> CIImage {
        guard !transform.isIdentity else { return image }
        // The track transform uses top-left coordinates, while Core Image uses bottom-left.
        let toTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: image.extent.height)
        let transformed = image.transformed(by: toTopLeft).transformed(by: transform)
        let bounds = transformed.extent
        return transformed.transformed(by: CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1, tx: -bounds.minX, ty: bounds.maxY
        ))
    }
}

private final class Lane {
    let region: Region
    private let request = VNRecognizeTextRequest()
    private var previousMask: [UInt64]?
    private var previousReading: Reading?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var requests = 0
    private(set) var credits: [Credit] = []

    init(region: Region) throws {
        self.region = region
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        guard supported.contains(region.language) else {
            throw Failure(L("此系统的 Vision 不支持 \(region.language)。支持的语言：\(supported.joined(separator: ", "))", "Vision on this system does not support \(region.language). Supported: \(supported.joined(separator: ", "))"))
        }
        request.recognitionLanguages = [region.language]
        request.usesLanguageCorrection = false
    }

    func recognize(_ image: CIImage, at time: Double, with context: CIContext) throws -> Reading? {
        let rect = region.crop(in: image.extent.size)
        guard rect.width >= 8, rect.height >= 8 else { throw Failure(L("字幕框 \(region.id) 太小。", "Region \(region.id) is too small.")) }
        guard let crop = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: colorSpace) else {
            throw Failure(L("无法裁剪字幕框 \(region.id)。", "Could not crop region \(region.id)."))
        }
        if let threshold = region.brightTextThreshold, let mask = brightMask(crop, threshold: threshold) {
            guard mask.count >= 20 else {
                previousMask = nil
                previousReading = nil
                return nil
            }
            if let previousMask, previousMask.count == mask.words.count, let previousReading {
                let difference = zip(previousMask, mask.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
                if difference <= max(5, mask.count / 25) { return previousReading }
            }
            previousMask = mask.words
            let ocrMask = region.ocrBrightnessThreshold.flatMap {
                brightMask(crop, threshold: $0)?.words
            } ?? mask.words
            if let isolated = isolatedText(ocrMask, width: crop.width, height: crop.height) {
                let primary = try read(isolated)
                let alternate = try read(crop)
                previousReading = checked(primary, against: alternate, at: time)
                return previousReading
            }
        }

        let primary = try read(crop)
        let alternate = try enlarged(crop).flatMap { try read($0) }
        let reading = checked(primary, against: alternate, at: time)
        previousReading = reading
        return reading
    }

    private func read(_ image: CGImage) throws -> Reading? {
        requests += 1
        return try recognizeText(image, request: request)
    }

    private func checked(_ primary: Reading?, against alternate: Reading?, at time: Double) -> Reading? {
        let matched = [primary, alternate].compactMap { $0 }.filter { reading in
            region.ignorePrefixes?.contains { prefix in
                reading.key.hasPrefix(prefix.filter { !$0.isWhitespace })
            } ?? false
        }
        if let credit = matched.first {
            if !credits.contains(where: { $0.text.filter { !$0.isWhitespace } == credit.key }) {
                credits.append(Credit(region: region.id, time: time, text: credit.text))
            }
            return nil
        }
        return compareReadings(primary, alternate)
    }

}

private func brightMask(_ image: CGImage, threshold: UInt8) -> (words: [UInt64], count: Int)? {
    guard image.bitsPerPixel == 32, let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return nil }
    var words = [UInt64](repeating: 0, count: (image.width * image.height + 63) / 64)
    var count = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            let offset = y * image.bytesPerRow + x * 4
            let luma = (77 * Int(bytes[offset]) + 150 * Int(bytes[offset + 1]) +
                        29 * Int(bytes[offset + 2]) + 128) / 256
            if luma >= Int(threshold) {
                let position = y * image.width + x
                words[position / 64] |= UInt64(1) << (position % 64)
                count += 1
            }
        }
    }
    return (words, count)
}

private func isolatedText(_ mask: [UInt64], width: Int, height: Int) -> CGImage? {
    let scaledWidth = width * 2, scaledHeight = height * 2
    var pixels = [UInt8](repeating: 0, count: scaledWidth * scaledHeight)
    func stroke(_ x: Int, _ y: Int) -> Int {
        let index = min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)
        return Int((mask[index / 64] >> (index % 64)) & 1)
    }
    // Upscale the stroke mask with bilinear sampling so Vision sees smooth edges.
    for y in 0..<scaledHeight {
        let top = (y - 1) >> 1
        let bottomWeight = y.isMultiple(of: 2) ? 3 : 1
        for x in 0..<scaledWidth {
            let left = (x - 1) >> 1
            let rightWeight = x.isMultiple(of: 2) ? 3 : 1
            let upper = stroke(left, top) * (4 - rightWeight) + stroke(left + 1, top) * rightWeight
            let lower = stroke(left, top + 1) * (4 - rightWeight) + stroke(left + 1, top + 1) * rightWeight
            let sample = upper * (4 - bottomWeight) + lower * bottomWeight
            pixels[y * scaledWidth + x] = UInt8((255 * sample + 8) / 16)
        }
    }
    let space = CGColorSpaceCreateDeviceGray()
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(width: scaledWidth, height: scaledHeight, bitsPerComponent: 8, bitsPerPixel: 8,
                   bytesPerRow: scaledWidth, space: space, bitmapInfo: [], provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                            1, nil) else {
        throw Failure(L("无法创建预览图：\(url.path)", "Could not create image file: \(url.path)"))
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure(L("无法保存预览图：\(url.path)", "Could not save image file: \(url.path)")) }
}
