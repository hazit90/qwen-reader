import Foundation

/// The one speech model the app uses: Qwen3-TTS 1.7B Base (8-bit), which has its own default
/// voice and clones voices from a short reference clip.
public enum VoiceModel {
    public static let displayName = "Qwen3-TTS 1.7B"

    /// The Hugging Face repository the model is downloaded from.
    public static let repository = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"

    /// The commit the app was tested against. Pinning it means every install gets the same files.
    public static let revision = "e7dd0585652209fa0d7783659aad4e8a324de11c"

    /// The model's folder name inside the app's Models folder.
    public static let folderName = "Qwen3-TTS-12Hz-1.7B-Base-8bit"

    /// Download size, shown before the file listing has been fetched.
    public static let downloadSize: Int64 = 3_104_000_000

    /// Memory used with the model loaded and idle, measured on an M1 Max.
    public static let loadedMemory = "3 GB"

    public static var webPage: URL {
        URL(string: "https://huggingface.co/\(repository)")!
    }

    /// Folders where other tools keep this model, newest layout first: the mlx-audio cache used by
    /// earlier versions of this app, and the Hugging Face Hub cache used by Python tools.
    public static func knownDownloadLocations(home: URL) -> [URL] {
        let hub = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let flatName = repository.replacingOccurrences(of: "/", with: "_")
        let hubName = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        return [
            hub.appendingPathComponent("mlx-audio/\(flatName)", isDirectory: true),
            hub.appendingPathComponent("\(hubName)/snapshots", isDirectory: true),
        ]
    }
}

/// How far a download or copy has got, in bytes.
public struct TransferProgress: Sendable, Equatable {
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(completedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    /// From 0 to 1; 0 while the total is unknown.
    public var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : 0
    }
}
