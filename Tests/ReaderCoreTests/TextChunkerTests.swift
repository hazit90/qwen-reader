import Testing
@testable import ReaderCore

struct TextChunkerTests {
    @Test func emptyAndWhitespaceTextProducesNoChunks() {
        #expect(TextChunker.chunks(from: "").isEmpty)
        #expect(TextChunker.chunks(from: "  \n\n \t ").isEmpty)
    }

    @Test func shortTextIsOneChunk() {
        #expect(TextChunker.chunks(from: "Hello there. How are you?") == ["Hello there. How are you?"])
    }

    @Test func sentencesAreGroupedUpToTheLimit() {
        let sentence = "This sentence is exactly fifty characters long ok."
        let text = Array(repeating: sentence, count: 10).joined(separator: " ")
        let chunks = TextChunker.chunks(from: text, maxLength: 120)
        #expect(chunks.count == 5)
        #expect(chunks.allSatisfy { $0.count <= 120 })
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func hardWrappedLinesAreRejoined() {
        let text = "This line was wrapped\nby an email client and\ncontinues here."
        #expect(TextChunker.chunks(from: text) == ["This line was wrapped by an email client and continues here."])
    }

    @Test func hyphenatedLineBreaksAreJoined() {
        #expect(TextChunker.chunks(from: "An exam-\nple word.") == ["An example word."])
    }

    @Test func headingsAndListItemsGetPauses() {
        let text = "Shopping list\n\n- Apples\n- Bread\n1. Milk"
        #expect(TextChunker.chunks(from: text) == ["Shopping list. Apples. Bread. Milk."])
    }

    @Test func longSentenceIsSplitBetweenWords() {
        let words = Array(repeating: "word", count: 100).joined(separator: " ") + "."
        let chunks = TextChunker.chunks(from: words, maxLength: 60)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 60 })
        #expect(chunks.joined(separator: " ") == words)
    }

    @Test func longSentencePrefersBreakingAfterClauses() {
        let text = "First part of a long sentence goes here, and then the second part continues on for a while."
        let chunks = TextChunker.split(text, maxLength: 60)
        #expect(chunks.first == "First part of a long sentence goes here,")
    }
}

struct AudioCacheTests {
    @Test func storesAndReturnsSamples() {
        let cache = AudioCache<String>(capacity: 10)
        cache.store([1, 2, 3], for: "a")
        #expect(cache.samples(for: "a") == [1, 2, 3])
        #expect(cache.samples(for: "b") == nil)
        #expect(cache.totalSamples == 3)
    }

    @Test func replacingAnEntryKeepsTheTotalRight() {
        let cache = AudioCache<String>(capacity: 10)
        cache.store([1, 2, 3], for: "a")
        cache.store([4, 5], for: "a")
        #expect(cache.samples(for: "a") == [4, 5])
        #expect(cache.totalSamples == 2)
        #expect(cache.count == 1)
    }

    @Test func evictsTheLeastRecentlyUsedWhenFull() {
        let cache = AudioCache<String>(capacity: 6)
        cache.store([1, 1, 1], for: "a")
        cache.store([2, 2], for: "b")
        _ = cache.samples(for: "a")          // "a" is now more recent than "b"
        cache.store([3, 3], for: "c")        // 7 samples: drop "b"
        #expect(cache.contains("a"))
        #expect(!cache.contains("b"))
        #expect(cache.contains("c"))
        #expect(cache.totalSamples == 5)
    }

    @Test func ignoresEmptyAndOversizedAudio() {
        let cache = AudioCache<String>(capacity: 3)
        cache.store([], for: "empty")
        cache.store([1, 2, 3, 4], for: "big")
        #expect(cache.count == 0)
        #expect(cache.totalSamples == 0)
    }
}

struct LanguageResolverTests {
    @Test func fixedSettingIsUsedAsIs() {
        #expect(LanguageResolver.resolve("german", for: "This is English text.") == "german")
    }

    @Test func autoDetectsSupportedLanguages() {
        #expect(LanguageResolver.resolve("auto", for: "The weather is lovely today and I am going for a walk.") == "english")
        #expect(LanguageResolver.resolve("auto", for: "Il fait très beau aujourd'hui et je vais me promener.") == "french")
        #expect(LanguageResolver.resolve("auto", for: "今日はとても良い天気なので散歩に行きます。") == "japanese")
    }
}
