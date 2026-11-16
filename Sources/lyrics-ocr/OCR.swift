import CoreGraphics
import Vision

func enlarged(_ image: CGImage) -> CGImage? {
    let width = image.width * 2, height = image.height * 2
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

func recognizeText(_ image: CGImage, request: VNRecognizeTextRequest) throws -> Reading? {
    do {
        try VNImageRequestHandler(cgImage: image).perform([request])
    } catch {
        throw Failure(L("Vision 识别失败：\(error.localizedDescription)。请在普通 macOS 终端运行。", "Vision text recognition failed: \(error.localizedDescription). Run the tool from a regular macOS terminal."))
    }
    var rows: [[VNRecognizedTextObservation]] = []
    for observation in (request.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
        if let first = rows.last?.first,
           abs(first.boundingBox.midY - observation.boundingBox.midY) < min(0.12, first.boundingBox.height / 2) {
            rows[rows.count - 1].append(observation)
        } else {
            rows.append([observation])
        }
    }
    let candidates = rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
        .compactMap { $0.topCandidates(1).first }
    guard !candidates.isEmpty else { return nil }
    let text = candidates.map(spacedText).joined(separator: " ")
        .replacingOccurrences(of: #"、[^\S\r\n]+"#, with: "、", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return Reading(text: text, confidence: candidates.reduce(0) { $0 + $1.confidence } / Float(candidates.count))
}

private func spacedText(_ candidate: VNRecognizedText) -> String {
    let text = candidate.string
    let indices = text.indices.filter { isCJK(text[$0]) }
    guard indices.count >= 3 else { return text }
    var boxes: [String.Index: CGRect] = [:]
    for index in indices {
        boxes[index] = (try? candidate.boundingBox(for: index..<text.index(after: index)))?.boundingBox
    }
    let pairs = zip(indices, indices.dropFirst()).compactMap { left, right -> (String.Index, CGFloat)? in
        guard text.index(after: left) == right, let a = boxes[left], let b = boxes[right],
              b.minX > a.midX, a.width > 0, b.width > 0 else { return nil }
        return (right, (b.minX - a.maxX) / max(a.width, b.width))
    }
    // Vision can return word-sized boxes for individual characters. Only use distinct boxes
    // and measure a gap relative to normal spacing within the same observation.
    guard pairs.count >= 2 else { return text }
    let gaps = pairs.map(\.1).sorted()
    let threshold = max(0.36, gaps[(gaps.count - 1) / 2] + 0.30)
    let breaks = Set(pairs.filter { $0.1 >= threshold }.map(\.0))
    return text.indices.map { (breaks.contains($0) ? " " : "") + String(text[$0]) }.joined()
}

func isHan(_ character: Character) -> Bool {
    character.unicodeScalars.first?.properties.isIdeographic == true
}

private func isCJK(_ character: Character) -> Bool {
    isHan(character) || character.unicodeScalars.first.map { (0x3041...0x30FA).contains($0.value) } == true
}

func compareReadings(_ primary: Reading?, _ alternate: Reading?) -> Reading? {
    guard var primary else {
        guard var alternate else { return nil }
        alternate.needsReview = true
        return alternate
    }
    guard let alternate, alternate.key != primary.key, alternate.confidence >= 0.4 else { return primary }
    if primary.confidence < 0.5, alternate.confidence > primary.confidence + 0.15 {
        var better = alternate
        better.needsReview = true
        better.alternative = primary.text
        return better
    }
    primary.needsReview = true
    primary.alternative = alternate.text
    return primary
}
