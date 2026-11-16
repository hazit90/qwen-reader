import CryptoKit
import Foundation
@testable import ReaderCore

/// A stand-in for the real model: the same file layout, with weights just big enough not to look
/// like Git LFS placeholders.
enum ModelFixture {
    static let weights = Data(repeating: 7, count: 1_200_000)
    static let speechWeights = Data(repeating: 9, count: 1_100_000)

    static func files(variant: String = "base") -> [String: Data] {
        [
            "config.json": Data(#"{"model_type": "qwen3_tts", "tts_model_type": "\#(variant)"}"#.utf8),
            "model.safetensors": weights,
            "vocab.json": Data("{}".utf8),
            "merges.txt": Data("a b".utf8),
            "speech_tokenizer/config.json": Data("{}".utf8),
            "speech_tokenizer/model.safetensors": speechWeights,
        ]
    }

    /// A new empty folder that the caller removes when done.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ files: [String: Data], to directory: URL) throws {
        for (path, data) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    /// Writes the model the way the Hugging Face Hub cache stores it: the files live in `blobs`,
    /// and `snapshots/<commit>` holds symbolic links to them. Returns the cache's top folder.
    static func writeHubCache(in directory: URL) throws -> URL {
        let repo = directory.appendingPathComponent("models--mlx-community--Qwen3-TTS", isDirectory: true)
        let blobs = repo.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = repo.appendingPathComponent("snapshots/abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        for (index, (path, data)) in files().sorted(by: { $0.key < $1.key }).enumerated() {
            let blob = blobs.appendingPathComponent("blob\(index)")
            try data.write(to: blob)
            let link = snapshot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        }
        return repo
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Answers the downloader's requests from memory, standing in for Hugging Face. Each test uses
/// its own host name, so tests can run side by side.
final class StubServer: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(status: Int, body: Data)
        /// Sends `body`, then drops the connection.
        case interrupted(body: Data)
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    /// Registers `handler` for a new host and returns a downloader pointed at it.
    static func downloader(retries: Int = 2, handler: @escaping Handler) -> ModelDownloader {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        lock.withLock { handlers[host] = handler }
        var downloader = ModelDownloader(repository: "org/model", revision: "rev")
        downloader.endpoint = URL(string: "https://\(host)")!
        downloader.maximumRetries = retries
        downloader.retryDelay = { _ in .milliseconds(1) }
        downloader.sessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubServer.self]
            return configuration
        }
        return downloader
    }

    /// A handler that serves `files` like Hugging Face does: the listing, then each file, with
    /// byte ranges honoured. `intercept` can answer a request itself by returning a reply.
    static func serving(
        _ files: [String: Data], checksums: [String: String] = [:],
        intercept: @escaping @Sendable (URLRequest) -> Reply? = { _ in nil }
    ) -> Handler {
        { request in
            if let reply = intercept(request) { return reply }
            let path = request.url!.path
            if path == "/api/models/org/model/revision/rev" {
                let siblings = files.map { name, data -> [String: Any] in
                    var sibling: [String: Any] = ["rfilename": name, "size": data.count]
                    if let checksum = checksums[name] { sibling["lfs"] = ["sha256": checksum] }
                    return sibling
                }
                return .http(status: 200, body: try! JSONSerialization.data(withJSONObject: ["siblings": siblings]))
            }
            let prefix = "/org/model/resolve/rev/"
            guard path.hasPrefix(prefix), let data = files[String(path.dropFirst(prefix.count))] else {
                return .http(status: 404, body: Data())
            }
            if let range = request.value(forHTTPHeaderField: "Range"),
               let offset = Int(range.dropFirst("bytes=".count).dropLast()) {
                return .http(status: 206, body: data.dropFirst(offset))
            }
            return .http(status: 200, body: data)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.lock.withLock({ Self.handlers[host] })
        else { return }
        let (status, body, fails): (Int, Data, Bool) = switch handler(request) {
        case .http(let status, let body): (status, body, false)
        case .interrupted(let body): (request.value(forHTTPHeaderField: "Range") == nil ? 200 : 206, body, true)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if fails {
            // Give URLSession a moment to deliver the data first, as a real connection would
            // before it drops.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Collects values from a `@Sendable` callback.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }

    var values: [Value] {
        lock.withLock { stored }
    }
}
