import AVFoundation
import Foundation

/// A cloned voice: a reference clip and exactly what is said in it.
struct VoiceProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var transcript: String
    var fileName: String
}

enum VoiceStoreError: LocalizedError {
    case clipTooShort(TimeInterval)
    case clipTooLong(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .clipTooShort(let seconds):
            String(format: "The clip is %.1f seconds long. Use at least 3 seconds of speech.", seconds)
        case .clipTooLong(let seconds):
            String(format: "The clip is %.0f seconds long. Use 30 seconds or less; 5–15 seconds works best.", seconds)
        }
    }
}

/// Saved voices, kept in ~/Library/Application Support/Qwen Reader/Voices.
@MainActor
@Observable
final class VoiceStore {
    private(set) var voices: [VoiceProfile] = []

    @ObservationIgnored let directory: URL
    @ObservationIgnored private var indexURL: URL { directory.appendingPathComponent("voices.json") }

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Qwen Reader/Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([VoiceProfile].self, from: data) {
            voices = saved
        }
    }

    func voice(id: UUID?) -> VoiceProfile? {
        voices.first { $0.id == id }
    }

    func audioURL(for voice: VoiceProfile) -> URL {
        directory.appendingPathComponent(voice.fileName)
    }

    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Copies the clip into the voices folder and saves the voice.
    func add(name: String, transcript: String, clip: URL) throws -> VoiceProfile {
        let seconds = try Self.duration(of: clip)
        if seconds < 3 { throw VoiceStoreError.clipTooShort(seconds) }
        if seconds > 30 { throw VoiceStoreError.clipTooLong(seconds) }

        let id = UUID()
        let fileExtension = clip.pathExtension.isEmpty ? "wav" : clip.pathExtension
        let voice = VoiceProfile(id: id, name: name, transcript: transcript, fileName: "\(id.uuidString).\(fileExtension)")
        try FileManager.default.copyItem(at: clip, to: audioURL(for: voice))
        voices.append(voice)
        try save()
        return voice
    }

    func delete(_ voice: VoiceProfile) throws {
        try? FileManager.default.removeItem(at: audioURL(for: voice))
        voices.removeAll { $0.id == voice.id }
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(voices).write(to: indexURL, options: .atomic)
    }
}
