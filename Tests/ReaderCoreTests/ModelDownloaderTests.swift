import Foundation
import Testing
@testable import ReaderCore

struct ModelDownloaderTests {
    private static let checksums = [
        "model.safetensors": ModelFixture.sha256(ModelFixture.weights),
        "speech_tokenizer/model.safetensors": ModelFixture.sha256(ModelFixture.speechWeights),
    ]

    /// Where a test downloads to, removed afterwards.
    private struct Folders {
        let root: URL
        var destination: URL { root.appendingPathComponent("Models/Qwen3-TTS", isDirectory: true) }
        var staging: URL { root.appendingPathComponent("Models/.download", isDirectory: true) }

        init() throws {
            root = try ModelFixture.temporaryDirectory()
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func downloadsEveryFileAndInstallsTheModel() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        var files = ModelFixture.files()
        files[".gitattributes"] = Data("ignored".utf8)
        let downloader = StubServer.downloader(handler: StubServer.serving(files, checksums: Self.checksums))
        let progress = Recorder<ModelDownloadProgress>()

        try await downloader.download(to: folders.destination, staging: folders.staging) { progress.append($0) }

        #expect(ModelDirectory.isValid(folders.destination))
        #expect(try ModelDirectory.files(in: folders.destination).map(\.relativePath) == ModelFixture.files().keys.sorted())
        #expect(try Data(contentsOf: folders.destination.appendingPathComponent("model.safetensors")) == ModelFixture.weights)
        #expect(!FileManager.default.fileExists(atPath: folders.destination.appendingPathComponent(".gitattributes").path))
        #expect(!FileManager.default.fileExists(atPath: folders.staging.path))

        let total = Int64(ModelFixture.files().values.reduce(0) { $0 + $1.count })
        #expect(progress.values.first?.phase == .connecting)
        #expect(progress.values.contains { $0.phase == .verifying })
        #expect(progress.values.last?.transfer == TransferProgress(completedBytes: total, totalBytes: total))
        // Progress never runs backwards.
        let completed = progress.values.map(\.transfer.completedBytes)
        #expect(completed == completed.sorted())
    }

    @Test func resumesAPartialFileFromWhereItStopped() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        // An earlier attempt finished the small files and got 400 KB into the main weights.
        try ModelFixture.write(["config.json": ModelFixture.files()["config.json"]!], to: folders.staging)
        try ModelFixture.write(["model.safetensors.partial": ModelFixture.weights.prefix(400_000)], to: folders.staging)

        let requests = Recorder<String>()
        let handler = StubServer.serving(ModelFixture.files(), checksums: Self.checksums) { request in
            let file = request.url!.path.replacingOccurrences(of: "/org/model/resolve/rev/", with: "")
            requests.append("\(file) \(request.value(forHTTPHeaderField: "Range") ?? "-")")
            return nil
        }
        let progress = Recorder<ModelDownloadProgress>()
        try await StubServer.downloader(handler: handler)
            .download(to: folders.destination, staging: folders.staging) { progress.append($0) }

        #expect(requests.values.contains("model.safetensors bytes=400000-"))
        #expect(!requests.values.contains { $0.hasPrefix("config.json") })
        #expect(try Data(contentsOf: folders.destination.appendingPathComponent("model.safetensors")) == ModelFixture.weights)
        // The first progress report already counts what was on disk.
        let firstDownload = progress.values.first { $0.phase == .downloading }
        #expect((firstDownload?.transfer.completedBytes ?? 0) >= Int64(ModelFixture.files()["config.json"]!.count))
    }

    @Test func carriesOnAfterTheConnectionDrops() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let attempts = Recorder<String>()
        let handler = StubServer.serving(ModelFixture.files(), checksums: Self.checksums) { request in
            guard request.url!.path.hasSuffix("/rev/model.safetensors") else { return nil }
            attempts.append(request.value(forHTTPHeaderField: "Range") ?? "-")
            // The first attempt delivers 300 KB and then the connection is lost.
            return attempts.values.count == 1 ? .interrupted(body: ModelFixture.weights.prefix(300_000)) : nil
        }

        try await StubServer.downloader(handler: handler)
            .download(to: folders.destination, staging: folders.staging) { _ in }

        #expect(attempts.values == ["-", "bytes=300000-"])
        #expect(try Data(contentsOf: folders.destination.appendingPathComponent("model.safetensors")) == ModelFixture.weights)
    }

    @Test func givesUpWhenTheConnectionKeepsFailing() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let attempts = Recorder<Int>()
        let handler = StubServer.serving(ModelFixture.files()) { request in
            guard request.url!.path.hasSuffix("/rev/model.safetensors") else { return nil }
            attempts.append(1)
            return .interrupted(body: Data())
        }

        await #expect(throws: URLError.self) {
            try await StubServer.downloader(retries: 2, handler: handler)
                .download(to: folders.destination, staging: folders.staging) { _ in }
        }
        #expect(attempts.values.count == 3)
        #expect(!FileManager.default.fileExists(atPath: folders.destination.path))
    }

    @Test func rejectsADamagedFile() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        var checksums = Self.checksums
        checksums["model.safetensors"] = String(repeating: "0", count: 64)
        let downloader = StubServer.downloader(handler: StubServer.serving(ModelFixture.files(), checksums: checksums))

        await #expect(throws: ModelDownloadError.checksumMismatch("model.safetensors")) {
            try await downloader.download(to: folders.destination, staging: folders.staging) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: folders.destination.path))
        // The damaged file is discarded so the next attempt fetches it again.
        #expect(!FileManager.default.fileExists(atPath: folders.staging.appendingPathComponent("model.safetensors.partial").path))
        #expect(!FileManager.default.fileExists(atPath: folders.staging.appendingPathComponent("model.safetensors").path))
    }

    @Test func reportsHTTPErrors() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let missingListing = StubServer.downloader { _ in .http(status: 404, body: Data()) }
        await #expect(throws: ModelDownloadError.http(status: 404, file: "the file list")) {
            try await missingListing.download(to: folders.destination, staging: folders.staging) { _ in }
        }

        let forbiddenFile = StubServer.downloader(handler: StubServer.serving(ModelFixture.files()) { request in
            request.url!.path.hasSuffix("/rev/vocab.json") ? .http(status: 403, body: Data()) : nil
        })
        await #expect(throws: ModelDownloadError.http(status: 403, file: "vocab.json")) {
            try await forbiddenFile.download(to: folders.destination, staging: folders.staging) { _ in }
        }
    }

    @Test func refusesFileNamesThatLeaveTheDownloadFolder() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        for name in ["../escape.txt", "/etc/passwd", "a//b", "speech_tokenizer/../../x"] {
            let downloader = StubServer.downloader(handler: StubServer.serving([name: Data("x".utf8)]))
            await #expect(throws: ModelDownloadError.badListing) {
                try await downloader.download(to: folders.destination, staging: folders.staging) { _ in }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: folders.root.appendingPathComponent("escape.txt").path))
    }

    @Test func cancellingKeepsThePartialDownload() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let handler = StubServer.serving(ModelFixture.files()) { request in
            request.url!.path.hasSuffix("/rev/model.safetensors")
                ? .interrupted(body: ModelFixture.weights.prefix(200_000)) : nil
        }
        var downloader = StubServer.downloader(retries: 100, handler: handler)
        // Long enough that the download is still waiting to retry when it is cancelled.
        downloader.retryDelay = { _ in .seconds(30) }
        let destination = folders.destination
        let staging = folders.staging
        let task = Task { [downloader] in
            try await downloader.download(to: destination, staging: staging) { _ in }
        }
        let partial = staging.appendingPathComponent("model.safetensors.partial")
        while (ModelDownloader.fileSize(partial) ?? 0) < 200_000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: partial) == ModelFixture.weights.prefix(200_000))
    }
}

struct TransferRateTests {
    @Test func needsASecondOfProgressBeforeEstimating() {
        var rate = TransferRate()
        rate.record(bytes: 0, at: 0)
        rate.record(bytes: 500, at: 0.5)
        #expect(rate.bytesPerSecond == nil)
        rate.record(bytes: 2_000, at: 2)
        #expect(rate.bytesPerSecond == 1_000)
        #expect(rate.secondsRemaining(for: TransferProgress(completedBytes: 2_000, totalBytes: 12_000)) == 10)
    }

    @Test func followsRecentSpeedOnly() {
        var rate = TransferRate(window: 10)
        rate.record(bytes: 0, at: 0)
        rate.record(bytes: 1_000_000, at: 1)
        // Much slower from here on; the fast first second drops out of the window.
        for second in 2 ... 20 {
            rate.record(bytes: 1_000_000 + Int64(second) * 100, at: Double(second))
        }
        #expect(rate.bytesPerSecond == 100)
    }

    @Test func aRestartDoesNotCountAsNegativeSpeed() {
        var rate = TransferRate()
        rate.record(bytes: 5_000, at: 0)
        rate.record(bytes: 9_000, at: 2)
        rate.record(bytes: 1_000, at: 3)
        #expect(rate.bytesPerSecond == nil)
        rate.record(bytes: 3_000, at: 4)
        #expect(rate.bytesPerSecond == 2_000)
    }

    @Test func timeRemainingReadsNaturally() {
        #expect(TransferRate.timeRemaining(20) == "less than a minute left")
        #expect(TransferRate.timeRemaining(61) == "about 2 min left")
        #expect(TransferRate.timeRemaining(45 * 60) == "about 45 min left")
        #expect(TransferRate.timeRemaining(2 * 3600) == "about 2 hr left")
        #expect(TransferRate.timeRemaining(2 * 3600 + 600) == "about 2 hr 10 min left")
    }

    @Test func fractionIsClampedAndSafeWithoutATotal() {
        #expect(TransferProgress().fraction == 0)
        #expect(TransferProgress(completedBytes: 50, totalBytes: 200).fraction == 0.25)
        #expect(TransferProgress(completedBytes: 300, totalBytes: 200).fraction == 1)
    }
}
