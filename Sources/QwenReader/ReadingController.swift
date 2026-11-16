import AppKit
import os
import ReaderCore

/// Identifies generated audio: the same text, voice and language always sound the same when replayed.
private struct SpeechCacheKey: Hashable {
    let voice: SpeechVoice
    let language: String
    let text: String
}

/// Coordinates one read at a time: grabs the text, splits it into chunks, streams each chunk
/// from the engine into the player, and cancels everything when stopped or replaced.
@MainActor
@Observable
final class ReadingController {
    enum Phase {
        case idle
        /// Waiting for the model to load or for the first audio to arrive.
        case preparing
        case speaking
    }

    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { app?.readingPhaseDidChange() }
        }
    }
    private(set) var isPaused = false
    /// The most recently read text, for Replay Last Reading.
    private(set) var lastText: String?

    /// About the last 10 minutes of audio (24 kHz, around 58 MB), by chunk. Speed is applied at
    /// playback, so cached audio replays at whatever speed is set.
    @ObservationIgnored private let cache = AudioCache<SpeechCacheKey>(capacity: 24_000 * 60 * 10)
    /// Audio of the chunk being generated, stored in the cache once the chunk completes.
    @ObservationIgnored private var chunkSamples: [Float] = []
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Identifies the current read so audio from a cancelled one is never played.
    @ObservationIgnored private var currentRead: UUID?
    @ObservationIgnored private var readStart = ContinuousClock.now
    @ObservationIgnored private var samplesDelivered = 0
    @ObservationIgnored private let log = Logger(subsystem: "io.github.hazit90.QwenReader", category: "Reading")

    var isActive: Bool { phase != .idle }

    func attach(to app: AppModel) {
        self.app = app
    }

    /// The ⌃⌥S behaviour: read the selection, or stop if already reading.
    func toggle() {
        isActive ? stop() : readSelection()
    }

    func readSelection() {
        guard let app, app.requireModel() else { return }
        guard SelectionReader.isTrusted else {
            SelectionReader.requestAccess()
            app.flash("Allow Qwen Reader in Accessibility settings, then try again.")
            return
        }
        Task {
            guard let text = await SelectionReader.selectedText(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                NSSound.beep()
                app.flash("No text selected.")
                return
            }
            read(text)
        }
    }

    func read(_ text: String) {
        guard let app, app.requireModel() else { return }
        let chunks = TextChunker.chunks(from: text)
        guard !chunks.isEmpty else { return }

        let previous = task
        previous?.cancel()
        app.player.stop()
        let readID = UUID()
        currentRead = readID
        lastText = text
        readStart = .now
        samplesDelivered = 0
        phase = .preparing
        isPaused = false
        log.info("Reading \(text.count) characters in \(chunks.count) chunk(s)")

        task = Task {
            // The engine must finish (or abandon) the previous read before it can start this one.
            await previous?.value
            await run(chunks, readID: readID, app: app)
        }
    }

    /// Reads the last text again, from the cache when the voice hasn't changed.
    func replayLast() {
        guard let lastText else { return }
        read(lastText)
    }

    func stop() {
        task?.cancel()
        task = nil
        currentRead = nil
        app?.player.shutDown()
        phase = .idle
        isPaused = false
    }

    func togglePause() {
        guard let app, isActive else { return }
        isPaused ? app.player.resume() : app.player.pause()
        isPaused.toggle()
    }

    private func run(_ chunks: [String], readID: UUID, app: AppModel) async {
        do {
            let voice = app.selectedSpeechVoice
            let language = LanguageResolver.resolve(app.language, for: chunks.joined(separator: " "))
            let keys = chunks.map { SpeechCacheKey(voice: voice, language: language, text: $0) }
            let cachedCount = keys.filter(cache.contains).count
            if cachedCount > 0 {
                log.info("\(cachedCount) of \(keys.count) chunk(s) cached")
            }
            // A fully cached read doesn't need the model, even if it has been unloaded.
            if cachedCount < keys.count {
                try await app.ensureModelLoaded()
            }
            for key in keys {
                try Task.checkCancellation()
                if let samples = cache.samples(for: key) {
                    deliver(samples, readID: readID)
                    continue
                }
                chunkSamples = []
                try await app.engine.speak(key.text, voice: voice, language: language) { samples in
                    await self.deliver(samples, readID: readID)
                }
                // Only complete chunks are cached; a cancelled one throws before reaching here.
                if currentRead == readID {
                    cache.store(chunkSamples, for: key)
                }
            }
            while app.player.hasQueuedAudio {
                try await Task.sleep(for: .milliseconds(100))
            }
            // The model outputs 24 kHz. Elapsed time well beyond first audio + audio length means gaps.
            let audioSeconds = Double(samplesDelivered) / 24_000
            log.info("Finished reading \(audioSeconds, format: .fixed(precision: 1), privacy: .public) s of audio after \(ContinuousClock.now - self.readStart, privacy: .public)")
            finish(readID)
        } catch is CancellationError {
            // Stopped or replaced by a newer read, which owns the state now.
            log.info("Read cancelled")
        } catch {
            guard currentRead == readID else { return }
            app.report(error)
            finish(readID)
        }
        app.noteActivity()
        await app.engine.trimMemory()
        // The voice may have changed during the read; get it ready for next time.
        app.preloadSelectedVoice()
    }

    private func deliver(_ samples: [Float], readID: UUID) {
        guard let app, currentRead == readID else { return }
        do {
            try app.player.enqueue(samples)
            samplesDelivered += samples.count
            chunkSamples += samples
            if phase == .preparing {
                phase = .speaking
                log.info("First audio after \(ContinuousClock.now - self.readStart, privacy: .public)")
            }
        } catch {
            app.report(error)
        }
    }

    private func finish(_ readID: UUID) {
        guard currentRead == readID else { return }
        app?.player.shutDown()
        currentRead = nil
        task = nil
        phase = .idle
        isPaused = false
    }
}
