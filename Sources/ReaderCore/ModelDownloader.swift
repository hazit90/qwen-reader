import CryptoKit
import Foundation

/// What a model download is doing, and how far it has got.
public struct ModelDownloadProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Fetching the file list.
        case connecting
        case downloading
        /// The connection dropped; the download continues by itself when it returns.
        case waitingForNetwork
        /// Checking a finished file against its checksum.
        case verifying
    }

    public var phase: Phase
    public var transfer: TransferProgress

    public init(phase: Phase, transfer: TransferProgress) {
        self.phase = phase
        self.transfer = transfer
    }
}

public enum ModelDownloadError: LocalizedError, Equatable {
    case badListing
    case http(status: Int, file: String)
    case sizeMismatch(String)
    case checksumMismatch(String)
    case notEnoughSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .badListing:
            "Hugging Face returned an unexpected file list for the model."
        case .http(let status, let file):
            "Hugging Face answered with HTTP \(status) for \(file)."
        case .sizeMismatch(let file):
            "\(file) didn't download completely. Try again."
        case .checksumMismatch(let file):
            "\(file) was damaged in transit. Try again."
        case .notEnoughSpace(let needed, let available):
            "Not enough free disk space: the download needs \(needed.formatted(.byteCount(style: .file))) and \(available.formatted(.byteCount(style: .file))) is available."
        }
    }
}

/// Downloads the model's files from Hugging Face into a staging folder, then moves the finished
/// model into place.
///
/// Partial files stay in the staging folder, so a download that is cancelled, or cut short by
/// quitting or losing the connection, carries on from where it stopped. Large files are checked
/// against the SHA-256 that Hugging Face publishes for them.
public struct ModelDownloader: Sendable {
    /// One file of the model repository.
    public struct File: Sendable, Equatable {
        public let path: String
        public let size: Int64
        /// Published for large (LFS) files only.
        public let sha256: String?

        public init(path: String, size: Int64, sha256: String? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public var repository: String
    public var revision: String
    public var endpoint = URL(string: "https://huggingface.co")!
    /// Consecutive failed attempts without any new data before giving up on a file.
    public var maximumRetries = 5
    public var retryDelay: @Sendable (_ attempt: Int) -> Duration = { .seconds(min(30, 1 << $0)) }
    public var sessionConfiguration: @Sendable () -> URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        // The longest gap allowed between two pieces of data, not a limit on the whole download.
        configuration.timeoutIntervalForRequest = 60
        return configuration
    }

    public init(repository: String = VoiceModel.repository, revision: String = VoiceModel.revision) {
        self.repository = repository
        self.revision = revision
    }

    /// Downloads into `staging`, then installs the result at `destination`.
    /// Throws `CancellationError` if the calling task is cancelled; `staging` is kept for next time.
    public func download(
        to destination: URL, staging: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let tracker = ProgressTracker(expectedTotal: VoiceModel.downloadSize, report: progress)
        tracker.set(phase: .connecting)

        // One session for the whole download, so its connection to Hugging Face is reused.
        let delegate = TransferDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: sessionConfiguration(), delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }

        let files = try await listFiles(session: session)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        // Smallest first, so problems with the listing or the connection show up early.
        let ordered = files.sorted { ($0.size, $0.path) < ($1.size, $1.path) }
        let finished = ordered.filter { Self.fileSize(staging.appendingPathComponent($0.path)) == $0.size }
        let pending = ordered.filter { !finished.contains($0) }
        let onDisk = finished.reduce(0) { $0 + $1.size }
            + pending.reduce(0) { $0 + min($1.size, Self.fileSize(Self.partialURL(for: $1, in: staging)) ?? 0) }
        let total = ordered.reduce(0) { $0 + $1.size }
        try checkFreeSpace(for: total - onDisk, at: staging)

        tracker.start(total: total, completed: finished.reduce(0) { $0 + $1.size })
        for file in pending {
            try await fetch(file, into: staging, session: session, delegate: delegate, tracker: tracker)
        }
        try ModelDirectory.promote(staging, to: destination)
    }

    // MARK: - Listing

    /// The repository's files at the pinned revision, with sizes and checksums.
    private func listFiles(session: URLSession) async throws -> [File] {
        struct Listing: Decodable {
            struct Sibling: Decodable {
                struct LFS: Decodable { let sha256: String? }
                let rfilename: String
                let size: Int64?
                let lfs: LFS?
            }
            let siblings: [Sibling]
        }

        var url = endpoint.appendingPathComponent("api/models")
        for component in repository.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        url.appendPathComponent("revision")
        url.appendPathComponent(revision)
        url.append(queryItems: [URLQueryItem(name: "blobs", value: "true")])

        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ModelDownloadError.http(status: status, file: "the file list") }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw ModelDownloadError.badListing
        }

        let files = try listing.siblings
            .filter { !$0.rfilename.hasPrefix(".") }
            .map { sibling in
                let path = sibling.rfilename
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                // The path becomes a file name on disk, so it must stay inside the staging folder.
                guard let size = sibling.size, size >= 0, !path.isEmpty,
                      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                      !path.contains("\\"), !path.contains("\0")
                else { throw ModelDownloadError.badListing }
                return File(path: path, size: size, sha256: sibling.lfs?.sha256)
            }
        guard !files.isEmpty else { throw ModelDownloadError.badListing }
        return files
    }

    // MARK: - Files

    private static func partialURL(for file: File, in staging: URL) -> URL {
        staging.appendingPathComponent(file.path + ".partial")
    }

    /// The file's current size. Read through FileManager because URL caches resource values,
    /// which would hide a partial file growing or being removed.
    static func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private func checkFreeSpace(for needed: Int64, at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        // Leave some room for the system once the model is in place.
        if available < needed + 500_000_000 {
            throw ModelDownloadError.notEnoughSpace(needed: needed, available: available)
        }
    }

    /// Downloads one file, resuming a partial one and retrying when the connection fails.
    private func fetch(
        _ file: File, into staging: URL, session: URLSession, delegate: TransferDelegate, tracker: ProgressTracker
    ) async throws {
        let fileManager = FileManager.default
        let target = staging.appendingPathComponent(file.path)
        let partial = Self.partialURL(for: file, in: staging)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        var failures = 0
        while true {
            try Task.checkCancellation()
            var offset = Self.fileSize(partial) ?? 0
            if offset > file.size || !fileManager.fileExists(atPath: partial.path) {
                try? fileManager.removeItem(at: partial)
                guard fileManager.createFile(atPath: partial.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
                }
                offset = 0
            }

            tracker.setCurrentFile(bytes: offset)
            if offset < file.size {
                do {
                    let transfer = Transfer(file: file.path, partial: partial, offset: offset, tracker: tracker)
                    try await run(transfer, session: session, delegate: delegate)
                } catch {
                    try Task.checkCancellation()
                    guard Self.isRetryable(error) else { throw error }
                    // Count only attempts that brought nothing new, so a slow, flaky connection
                    // still finishes.
                    failures = (Self.fileSize(partial) ?? 0) > offset ? 0 : failures + 1
                    guard failures <= maximumRetries else { throw error }
                    try await Task.sleep(for: retryDelay(failures))
                    continue
                }
            }

            guard Self.fileSize(partial) == file.size else {
                try? fileManager.removeItem(at: partial)
                tracker.setCurrentFile(bytes: 0)
                failures += 1
                guard failures <= maximumRetries else { throw ModelDownloadError.sizeMismatch(file.path) }
                continue
            }
            if let expected = file.sha256 {
                tracker.set(phase: .verifying)
                guard try Self.sha256(of: partial) == expected.lowercased() else {
                    try? fileManager.removeItem(at: partial)
                    tracker.setCurrentFile(bytes: 0)
                    throw ModelDownloadError.checksumMismatch(file.path)
                }
            }
            try? fileManager.removeItem(at: target)
            try fileManager.moveItem(at: partial, to: target)
            tracker.finishFile(size: file.size)
            return
        }
    }

    private func run(_ transfer: Transfer, session: URLSession, delegate: TransferDelegate) async throws {
        var url = endpoint
        for component in repository.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        url.appendPathComponent("resolve")
        url.appendPathComponent(revision)
        for component in transfer.file.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url)
        if transfer.offset > 0 {
            request.setValue("bytes=\(transfer.offset)-", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request)
        delegate.add(transfer, for: task)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                transfer.wait(with: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case ModelDownloadError.http(let status, _) = error {
            return status == 408 || status == 429 || status >= 500
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .badServerResponse,
             .secureConnectionFailed, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let finished = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { return true }
                hasher.update(data: chunk)
                return false
            }
            if finished { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Adds up bytes across files and reports them, at most ten times a second.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let report: @Sendable (ModelDownloadProgress) -> Void
    private var phase = ModelDownloadProgress.Phase.connecting
    private var total: Int64
    /// Bytes of files that are finished.
    private var finished: Int64 = 0
    /// Bytes of the file being downloaded.
    private var current: Int64 = 0
    private var lastReport = ContinuousClock.now - .seconds(1)

    init(expectedTotal: Int64, report: @escaping @Sendable (ModelDownloadProgress) -> Void) {
        total = expectedTotal
        self.report = report
    }

    /// Sets the totals without reporting them: the first report follows once the first file's
    /// already-downloaded bytes are known, so resuming doesn't look like a burst of speed.
    func start(total: Int64, completed: Int64) {
        lock.lock()
        self.total = total
        finished = completed
        current = 0
        lock.unlock()
    }

    func set(phase: ModelDownloadProgress.Phase) {
        update(force: true) { self.phase = phase }
    }

    func setCurrentFile(bytes: Int64) {
        update(force: true) {
            current = bytes
            phase = .downloading
        }
    }

    func advance(by bytes: Int) {
        update(force: false) {
            current += Int64(bytes)
            phase = .downloading
        }
    }

    func finishFile(size: Int64) {
        update(force: true) {
            finished += size
            current = 0
            phase = .downloading
        }
    }

    private func update(force: Bool, _ change: () -> Void) {
        lock.lock()
        change()
        let now = ContinuousClock.now
        let due = force || now - lastReport >= .milliseconds(100)
        if due { lastReport = now }
        let progress = ModelDownloadProgress(
            phase: phase, transfer: TransferProgress(completedBytes: finished + current, totalBytes: total)
        )
        lock.unlock()
        if due { report(progress) }
    }
}

/// One file being downloaded. `handle` and `failure` are only touched on the session's serial
/// delegate queue.
private final class Transfer: @unchecked Sendable {
    let file: String
    let partial: URL
    let offset: Int64
    let tracker: ProgressTracker
    var handle: FileHandle?
    var failure: Error?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    /// Resumes `continuation` when the transfer ends. A transfer cancelled before it started may
    /// already have ended, in which case this resumes it straight away.
    func wait(with continuation: CheckedContinuation<Void, Error>) {
        let result = lock.withLock {
            if self.result == nil { self.continuation = continuation }
            return self.result
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(with result: Result<Void, Error>) {
        let continuation = lock.withLock {
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    init(file: String, partial: URL, offset: Int64, tracker: ProgressTracker) {
        self.file = file
        self.partial = partial
        self.offset = offset
        self.tracker = tracker
    }
}

/// Writes each file's response to disk as it arrives.
private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    func add(_ transfer: Transfer, for task: URLSessionTask) {
        lock.withLock { transfers[task.taskIdentifier] = transfer }
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        lock.withLock { transfers[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        transfer(for: task)?.tracker.set(phase: .waitingForNetwork)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let transfer = transfer(for: dataTask) else { return completionHandler(.allow) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let handle = try FileHandle(forWritingTo: transfer.partial)
            transfer.handle = handle
            switch status {
            case 206:
                try handle.seekToEnd()
                transfer.tracker.setCurrentFile(bytes: transfer.offset)
            case 200:
                // The server sent the whole file rather than the rest of it, so start over.
                try handle.truncate(atOffset: 0)
                transfer.tracker.setCurrentFile(bytes: 0)
            default:
                throw ModelDownloadError.http(status: status, file: transfer.file)
            }
            completionHandler(.allow)
        } catch {
            transfer.failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask), transfer.failure == nil, let handle = transfer.handle else { return }
        do {
            try handle.write(contentsOf: data)
            transfer.tracker.advance(by: data.count)
        } catch {
            transfer.failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: task.taskIdentifier) }) else { return }
        try? transfer.handle?.close()
        transfer.handle = nil
        if let error = transfer.failure ?? error {
            transfer.finish(with: .failure(error))
        } else {
            transfer.finish(with: .success(()))
        }
    }
}
