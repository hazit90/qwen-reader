import Foundation
import NaturalLanguage

/// Splits selected text into chunks of whole sentences, each short enough for one generation request.
public enum TextChunker {
    /// Roughly 20 seconds of speech. Generation is capped at about six codec tokens per text token,
    /// so chunks this size stay well inside the model's limits.
    public static let defaultMaxLength = 300

    public static func chunks(from text: String, maxLength: Int = defaultMaxLength) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in sentences(in: text) {
            for piece in split(sentence, maxLength: maxLength) {
                if current.isEmpty {
                    current = piece
                } else if current.count + 1 + piece.count <= maxLength {
                    current += " " + piece
                } else {
                    chunks.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// Sentences in reading order. Blank lines separate paragraphs, list items start new segments,
    /// and hard-wrapped lines inside a paragraph are rejoined. Segments without closing punctuation
    /// (headings, list items) get a full stop so the voice pauses after them.
    static func sentences(in text: String) -> [String] {
        let unhyphenated = text.replacingOccurrences(
            of: #"(\w)-\n\s*(\w)"#, with: "$1$2", options: .regularExpression
        )
        var segments: [String] = []
        for paragraph in unhyphenated.components(separatedBy: "\n\n") {
            var segment = ""
            for rawLine in paragraph.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                if let item = listItemText(line) {
                    if !segment.isEmpty { segments.append(segment) }
                    segment = item
                } else {
                    segment = segment.isEmpty ? line : segment + " " + line
                }
            }
            if !segment.isEmpty { segments.append(segment) }
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        var sentences: [String] = []
        for segment in segments.map(withClosingPunctuation) {
            tokenizer.string = segment
            tokenizer.enumerateTokens(in: segment.startIndex ..< segment.endIndex) { range, _ in
                let sentence = collapsingWhitespace(segment[range])
                if !sentence.isEmpty { sentences.append(sentence) }
                return true
            }
        }
        return sentences
    }

    /// Breaks an over-long sentence between words, preferring to break after punctuation.
    static func split(_ sentence: String, maxLength: Int) -> [String] {
        guard sentence.count > maxLength else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(separator: " ").map(String.init) {
            let endsClause = current.last.map { ",;:)".contains($0) } ?? false
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count > maxLength || (endsClause && current.count > maxLength / 2) {
                pieces.append(current)
                current = word
            } else {
                current += " " + word
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func listItemText(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^(?:[-*•‣◦▪]|\d{1,3}[.)])\s+(.+)$/) else { return nil }
        return String(match.1)
    }

    private static func withClosingPunctuation(_ segment: String) -> String {
        guard let last = segment.last, !".!?…:;。！？\"'”’)]".contains(last) else { return segment }
        return segment + "."
    }

    private static func collapsingWhitespace(_ text: Substring) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
