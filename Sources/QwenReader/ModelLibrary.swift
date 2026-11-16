import Foundation
import os
import ReaderCore

/// The voice model on disk: whether it's installed, and getting it there by downloading it or
/// copying it from a folder. It lives in ~/Library/Application Support/Qwen Reader/Models.
@MainActor
@Observable
final class ModelLibrary {
    enum State: Equatable {
        case missing
        case downloading(ModelDownloadProgress)
        /// Copying a model from elsewhere on disk.
        case importing(TransferProgress)
        case installed
    }

    private(set) var state: State
    /// Why the last download or import failed. Cleared when another one starts.
    private(set) var problem: String?
    /// Whether an unfinished download is waiting to be resumed.
    private(set) var hasPartialDownload = false
    /// Sizes, speed and time remaining for the download in progress.
    private(set) var downloadSummary = ""

    /// Called once a model has been downloaded or imported.
    @ObservationIgnored var onInstalled: (() -> Void)?

    @ObservationIgnored let modelDirectory: URL
    @ObservationIgnored private let stagingDirectory: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rate = TransferRate()
    @ObservationIgnored private let log = Logger(subsystem: "io.github.hazit90.QwenReader", category: "Model")

    init() {
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Qwen Reader/Models", isDirectory: true)
        modelDirectory = models.appendingPathComponent(VoiceModel.folderName, isDirectory: true)
        stagingDirectory = models.appendingPathComponent(".download", isDirectory: true)
        state = ModelDirectory.isValid(modelDirectory) ? .installed : .missing
        refreshPartialDownload()
    }

    var isInstalled: Bool { state == .installed }

    /// Whether a download or import is running.
    var isBusy: Bool {
        switch state {
        case .downloading, .importing: true
        case .missing, .installed: false
        }
    }

    /// Progress of the download or import, from 0 to 1, or nil when neither is running.
    var transferFraction: Double? {
        switch state {
        case .downloading(let progress): progress.transfer.fraction
        case .importing(let transfer): transfer.fraction
        case .missing, .installed: nil
        }
    }

    /// One line describing the download or import in progress.
    var transferDescription: String? {
        switch state {
        case .downloading(let progress):
            switch progress.phase {
            case .connecting: "Contacting Hugging Face…"
            case .downloading: downloadSummary
            case .waitingForNetwork: "Waiting for the network…"
            case .verifying: "Checking the download…"
            }
        case .importing(let transfer):
            transfer.totalBytes == 0
                ? "Looking for the model…"
                : "Copying \(transfer.completedBytes.formatted(.byteCount(style: .file))) of \(transfer.totalBytes.formatted(.byteCount(style: .file)))"
        case .missing, .installed:
            nil
        }
    }

    /// Space the installed model takes on disk.
    var sizeOnDisk: Int64 {
        ModelDirectory.size(of: modelDirectory)
    }

    // MARK: - Download

    /// Downloads the model from Hugging Face, carrying on from any earlier unfinished download.
    func download() {
        guard state == .missing else { return }
        problem = nil
        rate = TransferRate()
        downloadSummary = ""
        state = .downloading(ModelDownloadProgress(
            phase: .connecting, transfer: TransferProgress(totalBytes: VoiceModel.downloadSize)
        ))
        log.info("Downloading \(VoiceModel.repository, privacy: .public)")

        let destination = modelDirectory
        let staging = stagingDirectory
        // Keep the Mac awake and the app out of App Nap until the download ends.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading the voice model"
        )
        task = Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try await ModelDownloader().download(to: destination, staging: staging) { [weak self] progress in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.downloadDidProgress(progress) }
                    }
                }
                didInstall()
            } catch {
                didFail(error)
            }
        }
    }

    private func downloadDidProgress(_ progress: ModelDownloadProgress) {
        // Progress queued before the download ended or was cancelled may still arrive after it.
        guard case .downloading = state else { return }
        rate.record(bytes: progress.transfer.completedBytes, at: ProcessInfo.processInfo.systemUptime)
        downloadSummary = rate.summary(for: progress.transfer)
        state = .downloading(progress)
    }

    // MARK: - Import

    /// Copies the model found at or inside `folder` into the app's Models folder.
    func importModel(from folder: URL) {
        guard state == .missing else { return }
        problem = nil
        state = .importing(TransferProgress())
        log.info("Importing a model from disk")

        let destination = modelDirectory
        task = Task {
            do {
                try await Self.copyModel(from: folder, to: destination) { [weak self] transfer in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, case .importing = self.state else { return }
                            self.state = .importing(transfer)
                        }
                    }
                }
                didInstall()
            } catch {
                didFail(error)
            }
        }
    }

    /// Uses a copy of the model that another tool, or an earlier version of this app, already
    /// downloaded, if there is one. Returns whether one was found.
    func adoptExistingDownload() -> Bool {
        guard state == .missing else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for location in VoiceModel.knownDownloadLocations(home: home) {
            if let found = try? ModelDirectory.locate(in: location, maxDepth: 1) {
                log.info("Found an existing download at \(found.path, privacy: .public)")
                importModel(from: found)
                return true
            }
        }
        return false
    }

    /// Runs off the main actor, since copying to another volume can take a while.
    private nonisolated static func copyModel(
        from folder: URL, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let source = try ModelDirectory.locate(in: folder)
        try ModelInstaller.install(from: source, to: destination, progress: progress)
    }

    // MARK: - Cancel and delete

    /// Stops the download or import. A stopped download keeps what it has, to resume later.
    func cancel() {
        task?.cancel()
    }

    /// Removes the installed model and any unfinished download.
    func delete() throws {
        guard !isBusy else { return }
        let fileManager = FileManager.default
        for directory in [modelDirectory, stagingDirectory] where fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        state = .missing
        refreshPartialDownload()
    }

    // MARK: - Results

    private func didInstall() {
        task = nil
        // A model imported from disk makes any unfinished download redundant.
        try? FileManager.default.removeItem(at: stagingDirectory)
        refreshPartialDownload()
        state = .installed
        log.info("Model installed")
        onInstalled?()
    }

    private func didFail(_ error: Error) {
        task = nil
        state = .missing
        refreshPartialDownload()
        if error is CancellationError {
            log.info("Model transfer cancelled")
        } else {
            problem = error.localizedDescription
            log.error("Model transfer failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshPartialDownload() {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)
        hasPartialDownload = !(contents ?? []).isEmpty
    }
}
