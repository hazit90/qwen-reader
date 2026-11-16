import Foundation

public enum ModelDirectoryError: LocalizedError, Equatable {
    case notFound
    case missingFiles([String])
    case unreadableConfig
    case wrongModel(String)
    case placeholderWeights(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "That folder doesn't contain the Qwen3-TTS model. Choose the folder that holds config.json and model.safetensors."
        case .missingFiles(let files):
            "The model folder is incomplete. Missing: \(files.joined(separator: ", "))."
        case .unreadableConfig:
            "The model's config.json can't be read."
        case .wrongModel(let found):
            "That folder holds \(found). Qwen Reader needs the Qwen3-TTS Base model, the one that clones voices."
        case .placeholderWeights(let file):
            "\(file) is a Git LFS placeholder, not the real weights. Run \"git lfs pull\" in that folder, or download the model from the menu instead."
        }
    }
}

/// Checks that a folder holds a usable Qwen3-TTS Base model, and finds one inside a larger folder.
public enum ModelDirectory {
    /// Real weight files are hundreds of megabytes; Git LFS placeholders are about 130 bytes.
    private static let minimumWeightSize: Int64 = 1_000_000

    /// A file in a model folder, with symbolic links (as in the Hugging Face Hub cache) resolved.
    public struct File: Equatable, Sendable {
        public let relativePath: String
        public let url: URL
        public let size: Int64
    }

    /// Throws unless `directory` holds everything needed to load a Qwen3-TTS Base model.
    public static func validate(_ directory: URL) throws {
        let config = directory.appendingPathComponent("config.json")
        guard exists(config) else { throw ModelDirectoryError.missingFiles(["config.json"]) }
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ModelDirectoryError.unreadableConfig }

        let modelType = json["model_type"] as? String
        guard modelType == "qwen3_tts" else {
            throw ModelDirectoryError.wrongModel(modelType.map { "a \"\($0)\" model" } ?? "a different model")
        }
        let variant = json["tts_model_type"] as? String ?? "base"
        guard variant == "base" else {
            throw ModelDirectoryError.wrongModel("the Qwen3-TTS \(variant) model")
        }

        var missing: [String] = []
        if try !hasWeights(in: directory, name: "model.safetensors") {
            missing.append("model.safetensors")
        }
        let hasTokenizer = exists(directory.appendingPathComponent("tokenizer.json"))
            || (exists(directory.appendingPathComponent("vocab.json"))
                && exists(directory.appendingPathComponent("merges.txt")))
        if !hasTokenizer {
            missing.append("vocab.json and merges.txt")
        }
        let speechTokenizer = directory.appendingPathComponent("speech_tokenizer", isDirectory: true)
        if try !hasWeights(in: speechTokenizer, name: "speech_tokenizer/model.safetensors") {
            missing.append("speech_tokenizer/model.safetensors")
        }
        guard missing.isEmpty else { throw ModelDirectoryError.missingFiles(missing) }
    }

    public static func isValid(_ directory: URL) -> Bool {
        (try? validate(directory)) != nil
    }

    /// The model folder at or inside `root`, so choosing a parent folder such as Downloads, or a
    /// Hugging Face cache folder with its `snapshots/<commit>` layout, works too.
    public static func locate(in root: URL, maxDepth: Int = 4) throws -> URL {
        var rootError: Error?
        do {
            try validate(root)
            return root
        } catch {
            // Only worth reporting if the folder looked like a model in the first place.
            if exists(root.appendingPathComponent("config.json")) { rootError = error }
        }

        var level = [root]
        var visited = 0
        for _ in 0 ..< maxDepth {
            var next: [URL] = []
            for directory in level {
                for child in subdirectories(of: directory) {
                    visited += 1
                    if exists(child.appendingPathComponent("config.json")), isValid(child) {
                        return child
                    }
                    next.append(child)
                }
                // A huge folder tree isn't a model download; stop rather than crawl the disk.
                if visited > 5_000 { throw rootError ?? ModelDirectoryError.notFound }
            }
            level = next
        }
        throw rootError ?? ModelDirectoryError.notFound
    }

    /// Every file in the model folder, skipping hidden files such as download bookkeeping.
    public static func files(in directory: URL) throws -> [File] {
        let root = directory.resolvingSymlinksInPath()
        var result: [File] = []
        var pending = [(url: root, prefix: "")]
        while let (url, prefix) = pending.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            for child in children {
                let path = prefix + child.lastPathComponent
                let resolved = child.resolvingSymlinksInPath()
                let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                if values.isDirectory == true {
                    pending.append((resolved, path + "/"))
                } else if values.isRegularFile == true {
                    result.append(File(relativePath: path, url: resolved, size: Int64(values.fileSize ?? 0)))
                }
            }
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    /// Total size of the model's files in bytes.
    public static func size(of directory: URL) -> Int64 {
        ((try? files(in: directory)) ?? []).reduce(0) { $0 + $1.size }
    }

    /// Makes the checked folder at `staging` the installed model at `destination`, replacing any
    /// model already there.
    public static func promote(_ staging: URL, to destination: URL) throws {
        try validate(staging)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    // MARK: - Helpers

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Whether `directory` has at least one weights file. `name` is only used in error messages.
    private static func hasWeights(in directory: URL, name: String) throws -> Bool {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil
        )) ?? []
        let weights = children.filter { $0.pathExtension == "safetensors" }
        for file in weights {
            let size = (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if Int64(size) < minimumWeightSize {
                throw ModelDirectoryError.placeholderWeights(name)
            }
        }
        return !weights.isEmpty
    }

    private static func subdirectories(of directory: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { child in
                let values = try? child.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
