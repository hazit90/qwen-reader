import Foundation

/// Estimates download speed from recent progress, for showing speed and time remaining.
public struct TransferRate: Sendable {
    /// How far back to look. Long enough to smooth out bursts, short enough to follow real changes.
    public let window: TimeInterval
    private var samples: [(time: TimeInterval, bytes: Int64)] = []

    public init(window: TimeInterval = 10) {
        self.window = window
    }

    /// Records that `bytes` had been transferred in total at `time` (any steadily increasing clock).
    public mutating func record(bytes: Int64, at time: TimeInterval) {
        // A falling count means the transfer restarted, so earlier samples no longer apply.
        if let last = samples.last, bytes < last.bytes {
            samples.removeAll()
        }
        samples.append((time, bytes))
        samples.removeAll { time - $0.time > window }
    }

    /// Bytes per second, or nil until there is at least a second of progress to go on.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 1 else { return nil }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }

    public func secondsRemaining(for transfer: TransferProgress) -> TimeInterval? {
        guard let rate = bytesPerSecond, rate > 0 else { return nil }
        return Double(max(0, transfer.totalBytes - transfer.completedBytes)) / rate
    }

    /// For example "1.2 GB of 3.1 GB · 14 MB/s · about 2 min left".
    public func summary(for transfer: TransferProgress) -> String {
        var parts = [
            "\(transfer.completedBytes.formatted(.byteCount(style: .file))) of \(transfer.totalBytes.formatted(.byteCount(style: .file)))",
        ]
        if let rate = bytesPerSecond, rate > 0 {
            parts.append("\(Int64(rate).formatted(.byteCount(style: .file)))/s")
        }
        if let seconds = secondsRemaining(for: transfer) {
            parts.append(Self.timeRemaining(seconds))
        }
        return parts.joined(separator: " · ")
    }

    public static func timeRemaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds < 60 { return "less than a minute left" }
        if minutes < 60 { return "about \(minutes) min left" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "about \(hours) hr left" : "about \(hours) hr \(minutes % 60) min left"
    }
}
