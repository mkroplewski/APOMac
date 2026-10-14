import Foundation
import Synchronization

/// Single-producer/single-consumer interleaved Float32 ring. The tap input
/// callback is the producer and the physical output callback is the consumer.
/// No locks, allocation, or file work occur in either callback.
final class AudioRingBuffer: @unchecked Sendable {
    private let channelCount: Int
    private let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeFrame = Atomic<Int>(0)
    private let readFrame = Atomic<Int>(0)

    init(channelCount: Int, capacityFrames: Int) {
        self.channelCount = max(1, channelCount)
        self.capacityFrames = max(2, capacityFrames)
        self.storage = .allocate(capacity: self.channelCount * self.capacityFrames)
        self.storage.initialize(repeating: 0, count: self.channelCount * self.capacityFrames)
    }

    deinit {
        storage.deinitialize(count: channelCount * capacityFrames)
        storage.deallocate()
    }

    func reset() {
        readFrame.store(0, ordering: .relaxed)
        writeFrame.store(0, ordering: .relaxed)
        storage.update(repeating: 0, count: channelCount * capacityFrames)
    }

    @inline(__always)
    func write(_ source: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let write = writeFrame.load(ordering: .relaxed)
        let read = readFrame.load(ordering: .acquiring)
        let available = capacityFrames - (write - read)
        let count = min(frameCount, max(0, available))
        guard count > 0 else { return }
        for frame in 0..<count {
            let destinationFrame = (write + frame) % capacityFrames
            storage.advanced(by: destinationFrame * channelCount).update(
                from: source.advanced(by: frame * channelCount),
                count: channelCount
            )
        }
        writeFrame.store(write + count, ordering: .releasing)
    }

    @inline(__always)
    func read(to destination: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let read = readFrame.load(ordering: .relaxed)
        let write = writeFrame.load(ordering: .acquiring)
        let count = min(frameCount, max(0, write - read))
        for frame in 0..<count {
            let sourceFrame = (read + frame) % capacityFrames
            destination.advanced(by: frame * channelCount).update(
                from: storage.advanced(by: sourceFrame * channelCount),
                count: channelCount
            )
        }
        readFrame.store(read + count, ordering: .releasing)
        return count
    }
}
