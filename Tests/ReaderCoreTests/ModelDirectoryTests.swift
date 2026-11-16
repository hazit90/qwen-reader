import Foundation
import Testing
@testable import ReaderCore

struct ModelDirectoryTests {
    @Test func completeModelIsValid() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ModelFixture.write(ModelFixture.files(), to: directory)
        try ModelDirectory.validate(directory)
        #expect(ModelDirectory.isValid(directory))
    }

    @Test func tokenizerJSONCanReplaceVocabAndMerges() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var files = ModelFixture.files()
        files["vocab.json"] = nil
        files["merges.txt"] = nil
        files["tokenizer.json"] = Data("{}".utf8)
        try ModelFixture.write(files, to: directory)
        #expect(ModelDirectory.isValid(directory))
    }

    @Test func emptyFolderIsMissingItsConfig() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ModelDirectoryError.missingFiles(["config.json"])) {
            try ModelDirectory.validate(directory)
        }
    }

    @Test func otherVariantsAndModelsAreRejected() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ModelFixture.write(ModelFixture.files(variant: "custom_voice"), to: directory)
        #expect(throws: ModelDirectoryError.wrongModel("the Qwen3-TTS custom_voice model")) {
            try ModelDirectory.validate(directory)
        }

        try Data(#"{"model_type": "whisper"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        #expect(throws: ModelDirectoryError.wrongModel("a \"whisper\" model")) {
            try ModelDirectory.validate(directory)
        }
    }

    @Test func missingPartsAreListed() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var files = ModelFixture.files()
        files["merges.txt"] = nil
        files["speech_tokenizer/model.safetensors"] = nil
        try ModelFixture.write(files, to: directory)
        #expect(throws: ModelDirectoryError.missingFiles(["vocab.json and merges.txt", "speech_tokenizer/model.safetensors"])) {
            try ModelDirectory.validate(directory)
        }
    }

    @Test func gitLFSPlaceholdersAreRejected() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var files = ModelFixture.files()
        files["model.safetensors"] = Data("version https://git-lfs.github.com/spec/v1".utf8)
        try ModelFixture.write(files, to: directory)
        #expect(throws: ModelDirectoryError.placeholderWeights("model.safetensors")) {
            try ModelDirectory.validate(directory)
        }
    }

    @Test func locateFindsAModelInsideTheChosenFolder() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("Downloads/models/Qwen3-TTS", isDirectory: true)
        try ModelFixture.write(ModelFixture.files(), to: model)
        try ModelFixture.write(["notes.txt": Data()], to: directory.appendingPathComponent("Downloads/other"))

        #expect(try ModelDirectory.locate(in: model).path == model.path)
        #expect(try ModelDirectory.locate(in: directory).resolvingSymlinksInPath().path == model.resolvingSymlinksInPath().path)
    }

    @Test func locateFindsAModelInAHubCache() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try ModelFixture.writeHubCache(in: directory)
        let found = try ModelDirectory.locate(in: repo)
        #expect(found.lastPathComponent == "abc123")
    }

    @Test func locateReportsWhyTheChosenFolderIsUnusable() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ModelDirectoryError.notFound) {
            try ModelDirectory.locate(in: directory)
        }
        // A folder that is a model, just the wrong one, says so rather than "not found".
        try ModelFixture.write(ModelFixture.files(variant: "custom_voice"), to: directory)
        #expect(throws: ModelDirectoryError.wrongModel("the Qwen3-TTS custom_voice model")) {
            try ModelDirectory.locate(in: directory)
        }
    }

    @Test func filesSkipsHiddenFilesAndFollowsLinks() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try ModelFixture.writeHubCache(in: directory)
        let snapshot = try ModelDirectory.locate(in: repo)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent(".mlx-audio-snapshot.json"))

        let files = try ModelDirectory.files(in: snapshot)
        #expect(files.map(\.relativePath) == ModelFixture.files().keys.sorted())
        #expect(files.first { $0.relativePath == "model.safetensors" }?.size == Int64(ModelFixture.weights.count))
        #expect(ModelDirectory.size(of: snapshot) == Int64(ModelFixture.files().values.reduce(0) { $0 + $1.count }))
    }
}

struct ModelInstallerTests {
    @Test func installCopiesTheModelAndLeavesTheSourceAlone() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try ModelFixture.write(ModelFixture.files(), to: source)
        try ModelFixture.write([".hidden.json": Data("{}".utf8)], to: source)
        let destination = directory.appendingPathComponent("Models/Qwen3-TTS", isDirectory: true)

        var reports: [TransferProgress] = []
        try ModelInstaller.install(from: source, to: destination) { reports.append($0) }

        #expect(ModelDirectory.isValid(destination))
        #expect(ModelDirectory.isValid(source))
        #expect(try ModelDirectory.files(in: destination).map(\.relativePath) == ModelFixture.files().keys.sorted())
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(".hidden.json").path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("model.safetensors")) == ModelFixture.weights)
        #expect(reports.last?.fraction == 1)
        // Nothing but the model is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Qwen3-TTS"])
    }

    @Test func installFromAHubCacheCopiesFilesNotLinks() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try ModelDirectory.locate(in: ModelFixture.writeHubCache(in: directory))
        let destination = directory.appendingPathComponent("Models/Qwen3-TTS", isDirectory: true)

        try ModelInstaller.install(from: snapshot, to: destination)

        let weights = destination.appendingPathComponent("speech_tokenizer/model.safetensors")
        let values = try weights.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        #expect(values.isSymbolicLink == false)
        #expect(values.isRegularFile == true)
        #expect(try Data(contentsOf: weights) == ModelFixture.speechWeights)
    }

    @Test func installReplacesAnExistingModel() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try ModelFixture.write(ModelFixture.files(), to: source)
        let destination = directory.appendingPathComponent("Models/Qwen3-TTS", isDirectory: true)
        try ModelFixture.write(["stale.txt": Data("old".utf8)], to: destination)

        try ModelInstaller.install(from: source, to: destination)

        #expect(ModelDirectory.isValid(destination))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale.txt").path))
    }

    @Test func installingAnUnusableFolderChangesNothing() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try ModelFixture.write(ModelFixture.files(variant: "voice_design"), to: source)
        let models = directory.appendingPathComponent("Models", isDirectory: true)

        #expect(throws: ModelDirectoryError.self) {
            try ModelInstaller.install(from: source, to: models.appendingPathComponent("Qwen3-TTS"))
        }
        #expect(!FileManager.default.fileExists(atPath: models.path))
    }

    @Test func installingTheInstalledModelOverItselfKeepsIt() throws {
        let directory = try ModelFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ModelFixture.write(ModelFixture.files(), to: directory)
        try ModelInstaller.install(from: directory, to: directory)
        #expect(ModelDirectory.isValid(directory))
    }
}
