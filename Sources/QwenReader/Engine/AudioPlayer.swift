import AVFoundation

/// Plays streamed audio chunks back to back, with pause and pitch-preserving speed control.
@MainActor
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format: AVAudioFormat

    private var queuedBuffers = 0
    /// Incremented by `stop()` so completion callbacks from discarded buffers are ignored.
    private var session = 0
    private(set) var isPaused = false

    init(sampleRate: Double = 24_000) {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        // Changing the output device stops the engine and drops scheduled audio.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session += 1
                self?.queuedBuffers = 0
            }
        }
    }

    /// Playback speed, 0.5–2.0. Pitch is preserved.
    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    /// Whether audio is still waiting to be heard.
    var hasQueuedAudio: Bool { queuedBuffers > 0 }

    func enqueue(_ samples: [Float]) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        if !engine.isRunning {
            try engine.start()
        }
        queuedBuffers += 1
        let session = session
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session == session else { return }
                self.queuedBuffers -= 1
            }
        }
        if !isPaused && !player.isPlaying {
            player.play()
        }
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    func resume() {
        isPaused = false
        player.play()
    }

    /// Stops immediately and discards queued audio.
    func stop() {
        session += 1
        queuedBuffers = 0
        isPaused = false
        player.stop()
    }

    /// Releases the audio device once reading has finished.
    func shutDown() {
        stop()
        engine.stop()
    }
}
