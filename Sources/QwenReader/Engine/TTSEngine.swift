import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS
import os
import ReaderCore

/// The voice to speak with.
enum SpeechVoice: Sendable, Hashable {
    /// The model's own voice; needs no reference clip and generates about twice as fast as real time.
    case standard
    /// A voice cloned from a reference clip and its exact transcript.
    case cloned(id: UUID, audioURL: URL, transcript: String)
}

enum TTSEngineError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded: "The voice model isn't loaded."
        }
    }
}

/// Owns the loaded Qwen3-TTS model. A model must only run one generation at a time, which the
/// actor guarantees as long as callers wait for one `speak` call to finish before starting the next.
actor TTSEngine {
    /// Seconds of audio per streamed chunk. Measured on an M1 Max: first audio after about 0.4 s.
    static let streamingInterval = 0.32

    /// After a stream is cancelled the library's generation task runs until its next cancellation
    /// check, so wait this long before reusing the model.
    private static let cancelSettleTime: Duration = .milliseconds(500)

    private let log = Logger(subsystem: "io.github.hazit90.QwenReader", category: "TTSEngine")
    private var model: Qwen3TTSModel?
    private var conditioningCache: [String: Qwen3TTSModel.Qwen3TTSReferenceConditioning] = [:]
    private var lastCancellation: ContinuousClock.Instant?
    private var isGenerating = false
    private var didWarmUpCloning = false

    /// Loads the model from `directory`, then runs one short silent generation, because the first
    /// generation compiles MLX's GPU kernels and otherwise takes 7–12 seconds.
    /// Callers must not run two loads concurrently.
    func load(from directory: URL) async throws {
        while isGenerating {
            try await Task.sleep(for: .milliseconds(20))
        }
        if model != nil { return }

        let start = ContinuousClock.now
        model = try await Qwen3TTSModel.fromModelDirectory(directory)
        do {
            try await speak("Warming up.", voice: .standard, language: "english") { _ in }
        } catch {
            // A model that loads but can't speak is no use; don't leave it looking ready.
            unload()
            throw error
        }
        Memory.clearCache()
        log.info("Model ready in \(ContinuousClock.now - start, privacy: .public)")
    }

    func unload() {
        model = nil
        conditioningCache.removeAll()
        didWarmUpCloning = false
        Memory.clearCache()
    }

    /// Prepares a cloned voice ahead of time so the first read with it starts quickly.
    /// Skipped while generating, since preparing uses the model too.
    func prepare(_ voice: SpeechVoice, language: String) async throws {
        guard !isGenerating, try conditioning(for: voice, language: language) != nil else { return }
        // Cloned voices take a separate path through the model whose GPU kernels are compiled on
        // first use, which otherwise delays the first cloned read by about 3 seconds.
        if !didWarmUpCloning {
            try await speak("Warming up.", voice: voice, language: language) { _ in }
            didWarmUpCloning = true
            Memory.clearCache()
        }
    }

    /// Generates speech for `text`, passing each streamed chunk of samples to `onAudio` as it arrives.
    /// Throws `CancellationError` if the calling task is cancelled.
    func speak(
        _ text: String,
        voice: SpeechVoice,
        language: String,
        onAudio: @Sendable ([Float]) async -> Void
    ) async throws {
        // The actor is re-entrant while a stream is awaited, so wait for any background
        // generation (such as a warm-up) to finish rather than running two at once.
        while isGenerating {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let model else { throw TTSEngineError.notLoaded }
        if let lastCancellation {
            try await Task.sleep(until: lastCancellation + Self.cancelSettleTime, clock: .continuous)
        }
        isGenerating = true
        defer { isGenerating = false }

        let parameters = model.defaultGenerationParameters
        let stream = if let conditioning = try conditioning(for: voice, language: language) {
            model.generateStream(
                text: text, conditioning: conditioning,
                generationParameters: parameters, streamingInterval: Self.streamingInterval
            )
        } else {
            model.generateStream(
                text: text, voice: nil, refAudio: nil, refText: nil, language: language,
                generationParameters: parameters, streamingInterval: Self.streamingInterval
            )
        }

        for try await event in stream {
            if Task.isCancelled { break }
            if case .audio(let chunk) = event {
                await onAudio(chunk.asArray(Float.self))
            }
        }
        if Task.isCancelled {
            lastCancellation = .now
            throw CancellationError()
        }
    }

    /// Releases MLX's cached GPU buffers. Peak use while speaking is about 5.7 GB.
    func trimMemory() {
        Memory.clearCache()
    }

    private func conditioning(
        for voice: SpeechVoice, language: String
    ) throws -> Qwen3TTSModel.Qwen3TTSReferenceConditioning? {
        guard case let .cloned(id, audioURL, transcript) = voice else { return nil }
        guard let model else { throw TTSEngineError.notLoaded }
        let key = "\(id.uuidString)|\(language)"
        if let cached = conditioningCache[key] { return cached }

        let start = ContinuousClock.now
        let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: model.sampleRate)
        let conditioning = try model.prepareReferenceConditioning(
            refAudio: audio, refText: transcript, language: language
        )
        conditioningCache[key] = conditioning
        log.info("Prepared voice \(id, privacy: .public) for \(language, privacy: .public) in \(ContinuousClock.now - start, privacy: .public)")
        return conditioning
    }
}
