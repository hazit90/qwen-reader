import AVFoundation

enum VoiceRecorderError: LocalizedError {
    case microphoneDenied
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Qwen Reader can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        case .couldNotStart:
            "Recording couldn't start."
        }
    }
}

/// Records a reference clip of the user reading `passage`, so its transcript is known exactly.
@MainActor
@Observable
final class VoiceRecorder {
    static let passage = """
        I'm recording this short sample so my Mac can read things aloud in my own voice. \
        I'll speak clearly and naturally, at my usual pace, just as if I were reading a page \
        out loud to a friend.
        """

    /// Stop automatically, since long clips slow generation down.
    static let maximumDuration: TimeInterval = 20

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var recordingURL: URL?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw VoiceRecorderError.microphoneDenied
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else { throw VoiceRecorderError.couldNotStart }

        discard()
        self.recorder = recorder
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        guard let recorder, isRecording else { return }
        recorder.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        recordingURL = recorder.url
        self.recorder = nil
    }

    /// Deletes the last recording.
    func discard() {
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        elapsed = 0
    }

    private func tick() {
        elapsed = recorder?.currentTime ?? elapsed
        if elapsed >= Self.maximumDuration {
            stop()
        }
    }
}
