import Foundation

/// Messages are bilingual. Chinese is used when the system's first preferred language is Chinese,
/// English otherwise. `LYRICS_OCR_LANG=zh` or `LYRICS_OCR_LANG=en` overrides the system setting.
enum InterfaceLanguage {
    case chinese
    case english

    static let current: InterfaceLanguage = resolve(
        override: ProcessInfo.processInfo.environment["LYRICS_OCR_LANG"],
        preferred: Locale.preferredLanguages
    )

    static func resolve(override: String?, preferred: [String]) -> InterfaceLanguage {
        if let value = override?.lowercased() {
            if value.hasPrefix("zh") { return .chinese }
            if value.hasPrefix("en") { return .english }
        }
        return preferred.first?.lowercased().hasPrefix("zh") == true ? .chinese : .english
    }
}

/// Picks the message for the current interface language.
func L(_ chinese: String, _ english: String) -> String {
    InterfaceLanguage.current == .chinese ? chinese : english
}
