import Foundation

/// Keeps the last `capacity` bytes of raw PTY output for mirroring to iOS.
/// Trimming can land mid-escape-sequence; the mirror replays into a fresh
/// emulator and TUI redraws settle any startup garbage.
public final class OutputRingBuffer {
    private var data = Data()
    private let capacity: Int
    private let lock = NSLock()

    public init(capacity: Int = 96 * 1024) { self.capacity = capacity }

    public func append(_ bytes: some Sequence<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        data.append(contentsOf: bytes)
        if data.count > capacity { data.removeFirst(data.count - capacity) }
    }

    public func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
