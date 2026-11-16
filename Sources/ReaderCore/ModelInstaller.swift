import Foundation

/// Copies a model folder from anywhere on disk into the app's own Models folder.
public enum ModelInstaller {
    private static let copyChunkSize = 8 * 1024 * 1024

    /// Copies the model at `source` to `destination`, replacing any model already there. The copy
    /// is built in a temporary folder next to `destination` and only moved into place once it is
    /// complete, so an interrupted copy never leaves a half-installed model.
    ///
    /// On the same APFS volume the files are cloned, which is instant and uses no extra space.
    /// Throws `CancellationError` if the calling task is cancelled.
    public static func install(
        from source: URL, to destination: URL, progress: (TransferProgress) -> Void = { _ in }
    ) throws {
        try ModelDirectory.validate(source)
        guard source.resolvingSymlinksInPath().path != destination.resolvingSymlinksInPath().path else { return }

        let files = try ModelDirectory.files(in: source)
        var transfer = TransferProgress(totalBytes: files.reduce(0) { $0 + $1.size })
        progress(transfer)

        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var installed = false
        defer {
            if !installed { try? fileManager.removeItem(at: staging) }
        }

        for file in files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.relativePath)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if clonefile(file.url.path, target.path, 0) == 0 {
                transfer.completedBytes += file.size
                progress(transfer)
            } else {
                try copy(file.url, to: target) { bytes in
                    transfer.completedBytes += Int64(bytes)
                    progress(transfer)
                }
            }
        }

        try ModelDirectory.promote(staging, to: destination)
        installed = true
    }

    /// A plain copy in chunks, for when cloning isn't possible (another volume, or not APFS).
    private static func copy(_ source: URL, to target: URL, onBytes: (Int) -> Void) throws {
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }

        while true {
            try Task.checkCancellation()
            let finished = try autoreleasepool {
                guard let chunk = try input.read(upToCount: copyChunkSize), !chunk.isEmpty else { return true }
                try output.write(contentsOf: chunk)
                onBytes(chunk.count)
                return false
            }
            if finished { break }
        }
    }
}
