import Foundation
import NaturalLanguage
import TranslateCore

enum LanguageResolver {
    static func sourceCode(text: String, preference: String) -> String? {
        if preference != "auto" { return TranslationLanguage.find(preference)?.id }
        // Short names and mixed snippets often have an unreliable dominant language.
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 4 else { return nil }
        let scalars = text.unicodeScalars.map(\.value)
        let latin = scalars.filter { (65...90).contains($0) || (97...122).contains($0) }.count
        let otherScript = scalars.filter { (0x3040...0x30ff).contains($0) || (0x4e00...0x9fff).contains($0) || (0xac00...0xd7af).contains($0) || (0x400...0x4ff).contains($0) || (0x600...0x6ff).contains($0) }.count
        if latin >= 4 && otherScript >= 2 { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.75 else { return nil }
        return best.key.rawValue
    }
    static func route(text: String, settings: AppSettings, input: Bool) -> TranslationLanguageRoute {
        TranslationLanguageRoute(target: input ? settings.inputLanguage : settings.readingLanguage,
            fallback: input ? settings.inputFallbackLanguage : settings.readingFallbackLanguage,
            mode: input ? settings.inputLanguageMode : settings.readingLanguageMode,
            sourceCode: sourceCode(text: text, preference: settings.textSourceLanguage), skipSame: settings.skipSameLanguage)
    }
}
