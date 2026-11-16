import Accelerate
import AVFoundation
import Foundation

private let audioRate = 8_000

struct Anchor: Codable {
    let video: Double
    let audio: Double
    var score: Double?
}

struct Segment: Codable {
    let videoStart: Double
    let videoEnd: Double
    let audioStart: Double
    let audioEnd: Double

    func audioTime(_ videoTime: Double) -> Double {
        audioStart + (videoTime - videoStart) * (audioEnd - audioStart) / (videoEnd - videoStart)
    }
}

struct Alignment: Codable {
    let method: String
    let anchors: [Anchor]
    let segments: [Segment]
    let targetDuration: Double
    var maxError: Double?

    func map(_ cues: [Cue]) -> [Cue] {
        var result: [Cue] = []
        for cue in cues {
            for segment in segments where cue.end > segment.videoStart && cue.start < segment.videoEnd {
                let start = max(0, segment.audioTime(max(cue.start, segment.videoStart)))
                let end = min(targetDuration, segment.audioTime(min(cue.end, segment.videoEnd)))
                if end > start {
                    var mapped = Cue(start: start, end: end, text: cue.text, needsReview: cue.needsReview)
                    if let last = result.last, last.text == mapped.text, abs(last.end - mapped.start) < 0.00001 {
                        mapped.start = last.start
                        mapped.needsReview = last.needsReview || mapped.needsReview
                        result.removeLast()
                    }
                    result.append(mapped)
                }
            }
        }
        return result
    }
}

func align(video: Video, audioURL: URL, anchors: [Anchor], segments: [Segment]) async throws -> Alignment {
    let target = AVURLAsset(url: audioURL)
    let duration = try await target.load(.duration).seconds
    guard duration.isFinite, duration > 0, !(try await target.loadTracks(withMediaType: .audio)).isEmpty else {
        throw Failure(L("找不到可用的本地音轨：\(audioURL.path)", "No usable audio track: \(audioURL.path)"))
    }

    if let manual = try manualAlignment(anchors: anchors, segments: segments,
                                        videoDuration: video.duration, audioDuration: duration) {
        return manual
    }

    log(L("读取视频和本地音源，寻找歌曲内部的匹配点…", "Reading the video and the local audio, looking for matching points…"))
    let source = try await readPCM(video.asset)
    let reference = try await readPCM(target)
    if let fit = try waveformFit(source, reference) {
        return automaticAlignment(fit, method: "waveform", videoDuration: video.duration, audioDuration: duration)
    }

    log(L("波形匹配不够稳定，改用音量变化寻找轻微变速的匹配点…", "Waveform matching was not reliable; trying loudness envelopes to allow a slight speed change…"))
    let rate = 50
    let sourceEnvelope = envelope(source, rate: rate)
    let targetEnvelope = envelope(reference, rate: rate)
    if let coarse = try estimate(sourceEnvelope, targetEnvelope, rate: rate, window: 6,
                                 minScore: 0.78, minMargin: 0.05, tolerance: 0.09),
       let refined = refine(coarse, source: source, target: reference) {
        return automaticAlignment(refined, method: "envelope-and-waveform", videoDuration: video.duration,
                                  audioDuration: duration)
    }
    throw Failure(L("未找到覆盖歌曲的可靠音频映射。可用 --anchor 指定同一个声音在两条时间轴的位置，或用 --segment 指定可对齐的片段。", "No reliable audio mapping covers the song. Use --anchor to mark the same sound on both timelines, or --segment to list spans that line up."))
}

/// Builds the mapping from `--segment` or `--anchor` input; returns nil when neither was given.
/// One anchor shifts the whole timeline. Several anchors interpolate piecewise between them and
/// extend the first and last pieces' rates to the ends of the video.
func manualAlignment(anchors: [Anchor], segments: [Segment], videoDuration: Double,
                     audioDuration: Double) throws -> Alignment? {
    if !segments.isEmpty {
        guard segments.allSatisfy({
            $0.videoStart >= 0 && $0.videoEnd <= videoDuration &&
            $0.audioStart >= 0 && $0.audioEnd <= audioDuration &&
            $0.videoStart < $0.videoEnd && $0.audioStart < $0.audioEnd
        }), zip(segments, segments.dropFirst()).allSatisfy({
            $0.videoEnd <= $1.videoStart && $0.audioEnd <= $1.audioStart
        }) else {
            throw Failure(L("手动分段必须在文件范围内，并按时间递增且互不重叠。",
                            "Manual segments must lie within both files, increase in time and not overlap."))
        }
        return Alignment(method: "manual-segments", anchors: [], segments: segments, targetDuration: audioDuration)
    }
    guard !anchors.isEmpty else { return nil }
    let sorted = anchors.sorted { $0.video < $1.video }
    guard sorted.allSatisfy({ $0.video >= 0 && $0.video <= videoDuration && $0.audio >= 0 && $0.audio <= audioDuration }),
          zip(sorted, sorted.dropFirst()).allSatisfy({ $0.video < $1.video && $0.audio < $1.audio }) else {
        throw Failure(L("手动锚点必须在文件范围内，并在两条时间轴上都递增。",
                        "Manual anchors must lie within both files and increase on both timelines."))
    }
    var points = sorted
    let first = sorted[0], last = sorted[sorted.count - 1]
    let firstScale = sorted.count > 1 ? (sorted[1].audio - first.audio) / (sorted[1].video - first.video) : 1
    let beforeLast = sorted.count > 1 ? sorted[sorted.count - 2] : last
    let lastScale = sorted.count > 1 ? (last.audio - beforeLast.audio) / (last.video - beforeLast.video) : 1
    if first.video > 0 { points.insert(Anchor(video: 0, audio: first.audio - firstScale * first.video), at: 0) }
    if last.video < videoDuration {
        points.append(Anchor(video: videoDuration, audio: last.audio + lastScale * (videoDuration - last.video)))
    }
    let mapping = zip(points, points.dropFirst()).map {
        Segment(videoStart: $0.video, videoEnd: $1.video, audioStart: $0.audio, audioEnd: $1.audio)
    }
    return Alignment(method: "manual-anchors", anchors: sorted, segments: mapping, targetDuration: audioDuration)
}

private func automaticAlignment(_ fit: Fit, method: String, videoDuration: Double, audioDuration: Double) -> Alignment {
    let segment = Segment(videoStart: 0, videoEnd: videoDuration, audioStart: fit.offset,
                          audioEnd: fit.offset + videoDuration * fit.scale)
    log(String(format: L("音频对齐：偏移 %+.4f 秒，比例 %.7f，%d 个匹配点，最大偏差 %.3f 秒", "Audio alignment: offset %+.4f s, scale %.7f, %d matches, max error %.3f s"),
               fit.offset, fit.scale, fit.anchors.count, fit.error))
    return Alignment(method: method, anchors: fit.anchors, segments: [segment],
                     targetDuration: audioDuration, maxError: fit.error)
}

private func readPCM(_ asset: AVURLAsset) async throws -> [Float] {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw Failure(L("视频没有音轨。", "The video has no audio track."))
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: audioRate,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw Failure(L("无法添加音频解码输出。", "Could not set up audio decoding.")) }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? Failure(L("无法读取音轨。", "Could not read the audio track.")) }
    defer { if reader.status == .reading { reader.cancelReading() } }

    var mono: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        try autoreleasepool {
            guard let block = buffer.dataBuffer, let format = buffer.formatDescription,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  description.mSampleRate == Double(audioRate), description.mChannelsPerFrame > 0,
                  description.mBytesPerFrame == description.mChannelsPerFrame * 4 else {
                throw Failure(L("无法读取解码后的 PCM 音频。", "Could not read the decoded PCM audio."))
            }
            let channels = Int(description.mChannelsPerFrame)
            let count = buffer.numSamples
            let pts = buffer.presentationTimeStamp.seconds
            guard pts.isFinite else { throw Failure(L("音轨采样时间无效。", "The audio track has invalid timestamps.")) }
            var position = Int((pts * Double(audioRate)).rounded())
            if abs(position - mono.count) <= 1 { position = mono.count }
            if position > mono.count {
                mono.append(contentsOf: repeatElement(0, count: position - mono.count))
            }
            let skip = max(0, mono.count - position)
            guard skip < count else { return }
            var pcm = [Float](repeating: 0, count: count * channels)
            let status = pcm.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count,
                                           destination: bytes.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw Failure(L("无法复制音频样本：\(status)", "Could not copy audio samples: \(status)")) }
            for index in skip..<count {
                var value: Float = 0
                let offset = index * channels
                for channel in 0..<channels { value += pcm[offset + channel] }
                mono.append(value / Float(channels))
            }
        }
    }
    if reader.status == .failed { throw reader.error ?? Failure(L("音频解码失败。", "Audio decoding failed.")) }
    guard !mono.isEmpty else { throw Failure(L("音轨中没有音频样本。", "The audio track contains no samples.")) }
    return mono
}

private struct Fit {
    let scale: Double
    let offset: Double
    let anchors: [Anchor]
    let error: Double
}

private func waveformFit(_ source: [Float], _ target: [Float]) throws -> Fit? {
    try estimate(source, target, rate: audioRate, window: 0.8,
                 minScore: 0.62, minMargin: 0.08, tolerance: 0.025)
}

private func estimate(_ source: [Float], _ target: [Float], rate: Int, window: Double,
                      minScore: Double, minMargin: Double, tolerance: Double) throws -> Fit? {
    let length = Int(window * Double(rate))
    guard source.count >= length * 2, target.count >= length else { return nil }
    let correlator = try Correlator(target, window: length)
    let usable = source.count - length
    var anchors: [Anchor] = []
    for step in 1...12 {
        let start = usable * step / 13
        let values = Array(source[start..<(start + length)])
        guard let peak = correlator.match(values, separation: rate / 3),
              peak.score >= minScore, peak.score - peak.second >= minMargin else { continue }
        let center = Double(length - 1) / 2
        anchors.append(Anchor(video: (Double(start) + center) / Double(rate),
                              audio: (Double(peak.index) + center) / Double(rate), score: peak.score))
    }
    let span = Double(usable) / Double(rate)
    return fitAnchors(anchors, requiredSpan: span * 0.6, tolerance: tolerance)
}

private func fitAnchors(_ anchors: [Anchor], requiredSpan: Double, tolerance: Double) -> Fit? {
    guard anchors.count >= 4 else { return nil }
    var best: [Anchor] = []
    for (index, left) in anchors.enumerated() {
        for right in anchors.dropFirst(index + 1) where right.video - left.video >= requiredSpan * 0.35 {
            let scale = (right.audio - left.audio) / (right.video - left.video)
            guard (0.96...1.04).contains(scale) else { continue }
            let offset = left.audio - left.video * scale
            let matching = anchors.filter { abs($0.audio - ($0.video * scale + offset)) <= tolerance }
            if matching.count > best.count { best = matching }
        }
    }
    guard best.count >= 4, best.count >= anchors.count - 1,
          let first = best.first, let last = best.last,
          last.video - first.video >= requiredSpan else { return nil }

    let meanX = best.map(\.video).reduce(0, +) / Double(best.count)
    let meanY = best.map(\.audio).reduce(0, +) / Double(best.count)
    let variance = best.reduce(0) { $0 + pow($1.video - meanX, 2) }
    var scale = best.reduce(0) { $0 + ($1.video - meanX) * ($1.audio - meanY) } / variance
    if abs(scale - 1) * (last.video - first.video) <= 0.006 { scale = 1 }
    let offset = meanY - meanX * scale
    let error = best.map { abs($0.audio - ($0.video * scale + offset)) }.max() ?? .infinity
    guard error <= tolerance else { return nil }
    return Fit(scale: scale, offset: offset, anchors: best, error: error)
}

private func envelope(_ samples: [Float], rate: Int) -> [Float] {
    let hop = audioRate / rate
    let bins = samples.count / hop
    return (0..<bins).map { bin in
        let start = bin * hop
        let end = min(start + 2 * hop, samples.count)
        var energy: Float = 0
        for index in start..<end { energy += samples[index] * samples[index] }
        return log1p(50 * sqrt(energy / Float(end - start)))
    }
}

// Refine the coarse envelope fit with short, resampled waveform matches near its anchors.
private func refine(_ fit: Fit, source: [Float], target: [Float]) -> Fit? {
    let halfWindow = Int(Double(audioRate) * 0.22)
    let length = 2 * halfWindow + 1
    let search = Int(Double(audioRate) * 0.12)
    let rate = Double(audioRate)
    var anchors: [Anchor] = []
    for anchor in fit.anchors {
        let targetCenter = Int(((fit.scale * anchor.video + fit.offset) * rate).rounded())
        let low = targetCenter - search - halfWindow
        let high = targetCenter + search + halfWindow + 1
        guard low >= 0, high <= target.count else { continue }
        let center = anchor.video * rate
        let first = center - Double(halfWindow) / fit.scale
        let last = center + Double(halfWindow) / fit.scale
        guard first >= 0, last + 1 < Double(source.count) else { continue }
        let resampled = (-halfWindow...halfWindow).map { index -> Float in
            let position = center + Double(index) / fit.scale
            let floor = Int(position)
            let fraction = Float(position - Double(floor))
            return source[floor] + fraction * (source[floor + 1] - source[floor])
        }
        guard let correlator = try? Correlator(Array(target[low..<high]), window: length),
              let peak = correlator.match(resampled, separation: audioRate / 25),
              peak.score >= 0.56, peak.score - peak.second >= 0.07 else { continue }
        anchors.append(Anchor(video: anchor.video,
                              audio: Double(low + peak.index + halfWindow) / rate, score: peak.score))
    }
    let span = Double(source.count) / rate
    return fitAnchors(anchors, requiredSpan: span * 0.58, tolerance: 0.025)
}

private final class Correlator {
    private let fft: FFTSetup
    private let exponent: vDSP_Length
    private let count: Int
    private let window: Int
    private let targetCount: Int
    private let spectrum: (real: [Float], imaginary: [Float])
    private let sums: [Double]
    private let squaredSums: [Double]

    init(_ target: [Float], window: Int) throws {
        let required = target.count + window - 1
        var size = 1, power = 0
        while size < required {
            size *= 2
            power += 1
        }
        let exponent = vDSP_Length(power)
        guard let fft = vDSP_create_fftsetup(exponent, FFTRadix(kFFTRadix2)) else {
            throw Failure(L("无法创建音频 FFT。", "Could not create the audio FFT."))
        }
        self.fft = fft
        self.exponent = exponent
        self.count = size
        self.window = window
        self.targetCount = target.count
        var real = target + [Float](repeating: 0, count: size - target.count)
        var imaginary = [Float](repeating: 0, count: size)
        Self.transform(&real, &imaginary, setup: fft, exponent: exponent, direction: FFT_FORWARD)
        spectrum = (real, imaginary)
        var sums = [Double](repeating: 0, count: target.count + 1)
        var squares = sums
        for index in target.indices {
            let value = Double(target[index])
            sums[index + 1] = sums[index] + value
            squares[index + 1] = squares[index] + value * value
        }
        self.sums = sums
        squaredSums = squares
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func match(_ values: [Float], separation: Int) -> (index: Int, score: Double, second: Double)? {
        let mean = values.reduce(0, +) / Float(window)
        let centered = values.map { $0 - mean }
        let power = centered.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard power > 0.00001 else { return nil }

        var real = centered + [Float](repeating: 0, count: count - window)
        var imaginary = [Float](repeating: 0, count: count)
        Self.transform(&real, &imaginary, setup: fft, exponent: exponent, direction: FFT_FORWARD)
        for index in 0..<count {
            let a = real[index], b = imaginary[index]
            let c = spectrum.real[index], d = spectrum.imaginary[index]
            real[index] = a * c + b * d
            imaginary[index] = a * d - b * c
        }
        Self.transform(&real, &imaginary, setup: fft, exponent: exponent, direction: FFT_INVERSE)

        let normalization = Double(count)
        var best = -Double.infinity, bestIndex = 0
        for index in 0...(targetCount - window) {
            let end = index + window
            let sum = sums[end] - sums[index]
            let energy = squaredSums[end] - squaredSums[index] - sum * sum / Double(window)
            let score = energy > 0.00001 ? Double(real[index]) / (normalization * sqrt(energy * power)) : 0
            real[index] = Float(score)
            if score > best {
                best = score
                bestIndex = index
            }
        }
        var second: Float = 0
        for index in 0...(targetCount - window) where abs(index - bestIndex) > separation {
            second = max(second, real[index])
        }
        return (bestIndex, min(1, best), Double(second))
    }

    private static func transform(_ real: inout [Float], _ imaginary: inout [Float], setup: FFTSetup,
                                  exponent: vDSP_Length, direction: Int) {
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, exponent, FFTDirection(direction))
            }
        }
    }
}
