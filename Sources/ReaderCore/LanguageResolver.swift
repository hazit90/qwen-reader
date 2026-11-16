import Foundation
import NaturalLanguage

/// Maps text and user settings to the language names Qwen3-TTS expects.
public enum LanguageResolver {
    /// The automatic setting: detect the language of each piece of text.
    public static let auto = "auto"

    /// Supported languages by model name, in menu order.
    public static let supported = [
        "english", "chinese", "japanese", "korean", "german",
        "french", "russian", "portuguese", "spanish", "italian",
    ]

    private static let byNaturalLanguage: [NLLanguage: String] = [
        .english: "english", .simplifiedChinese: "chinese", .traditionalChinese: "chinese",
        .japanese: "japanese", .korean: "korean", .german: "german", .french: "french",
        .russian: "russian", .portuguese: "portuguese", .spanish: "spanish", .italian: "italian",
    ]

    private static let byLanguageCode: [String: String] = [
        "en": "english", "zh": "chinese", "ja": "japanese", "ko": "korean", "de": "german",
        "fr": "french", "ru": "russian", "pt": "portuguese", "es": "spanish", "it": "italian",
    ]

    /// The language to speak `text` in. A fixed setting wins; otherwise the text is detected,
    /// falling back to the model's own automatic mode when the language is unsupported.
    public static func resolve(_ setting: String, for text: String) -> String {
        guard setting == auto else { return setting }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Array(byNaturalLanguage.keys)
        recognizer.processString(text)
        return recognizer.dominantLanguage.flatMap { byNaturalLanguage[$0] } ?? auto
    }

    /// The user's preferred supported language, used to prepare a cloned voice before any text arrives.
    public static var preferred: String {
        for identifier in Locale.preferredLanguages {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier,
               let name = byLanguageCode[code] {
                return name
            }
        }
        return "english"
    }

    public static func displayName(_ language: String) -> String {
        language == auto ? "Auto-detect" : language.capitalized
    }
}
