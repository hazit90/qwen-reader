import AVFoundation

/// Plays streamed audio chunks back to back, with pause and pitch-preserving speed control.
///
/// Audio is generated while it plays. If playback catches up with generation, as it can when the
/// Mac is busy, the player waits until a little audio has built up rather than playing each
/// small chunk the moment it arrives, which would sound like a stutter.
@MainActor
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format: AVAudioFormat

    /// Seconds of playback to build up after running dry, before carrying on.
    private static let rebufferTime = 0.8

    private var queuedBuffers = 0
    /// Seconds of audio scheduled and not yet played, at normal speed.
    private var queuedSeconds = 0.0
    /// Whether playback ran out of audio mid-stream and is waiting for more.
    private var isRebuffering = false
    /// Whether all of the current read's audio has been enqueued.
    private var streamEnded = false
    /// How many times playback has had to wait for audio since the last `stop()`.
    private(set) var rebufferCount = 0
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
                self?.queuedSeconds = 0
                self?.isRebuffering = false
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
        let seconds = Double(samples.count) / format.sampleRate
        queuedBuffers += 1
        queuedSeconds += seconds
        let session = session
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session == session else { return }
                self.queuedBuffers -= 1
                self.queuedSeconds -= seconds
                if self.queuedBuffers == 0, !self.streamEnded {
                    self.isRebuffering = true
                    self.rebufferCount += 1
                    self.player.pause()
                }
            }
        }
        // Faster playback uses audio up faster, so it needs more in hand.
        if isRebuffering, queuedSeconds >= Self.rebufferTime * Double(rate) {
            isRebuffering = false
        }
        if !isPaused && !isRebuffering && !player.isPlaying {
            player.play()
        }
    }

    /// Call once the last audio of a read has been enqueued, so what is left plays out rather
    /// than waiting for more.
    func finishStream() {
        streamEnded = true
        guard isRebuffering else { return }
        isRebuffering = false
        if !isPaused {
            player.play()
        }
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    func resume() {
        isPaused = false
        if !isRebuffering {
            player.play()
        }
    }

    /// Stops immediately and discards queued audio.
    func stop() {
        session += 1
        queuedBuffers = 0
        queuedSeconds = 0
        isRebuffering = false
        streamEnded = false
        rebufferCount = 0
        isPaused = false
        player.stop()
    }

    /// Releases the audio device once reading has finished.
    func shutDown() {
        stop()
        engine.stop()
    }
}
