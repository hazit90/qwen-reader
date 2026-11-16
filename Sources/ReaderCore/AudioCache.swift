/// Recently generated audio, so text that is read again plays without generating it again.
/// Holds at most `capacity` samples in total and drops the least recently used entries first.
public final class AudioCache<Key: Hashable> {
    public let capacity: Int
    public private(set) var totalSamples = 0

    private var entries: [Key: [Float]] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public var count: Int { entries.count }

    public func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    /// The cached samples for `key`, marking them as recently used.
    public func samples(for key: Key) -> [Float]? {
        guard let samples = entries[key] else { return nil }
        touch(key)
        return samples
    }

    public func store(_ samples: [Float], for key: Key) {
        guard !samples.isEmpty, samples.count <= capacity else { return }
        remove(key)
        entries[key] = samples
        order.append(key)
        totalSamples += samples.count
        while totalSamples > capacity, let oldest = order.first {
            remove(oldest)
        }
    }

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.append(order.remove(at: index))
    }

    private func remove(_ key: Key) {
        guard let samples = entries.removeValue(forKey: key) else { return }
        totalSamples -= samples.count
        order.removeAll { $0 == key }
    }
}
