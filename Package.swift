// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lyrics-ocr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lyrics-ocr", targets: ["lyrics-ocr"])
    ],
    targets: [
        .executableTarget(
            name: "lyrics-ocr",
            path: "Sources/lyrics-ocr"
        ),
        .testTarget(
            name: "LyricsOCRTests",
            dependencies: ["lyrics-ocr"],
            path: "Tests/LyricsOCRTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
