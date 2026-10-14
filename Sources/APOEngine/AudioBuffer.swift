import Foundation

internal final class PlanarBuffer {
    let channelCount: Int
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    init(channelCount: Int, capacity: Int) {
        self.channelCount = max(1, channelCount)
        self.capacity = max(1, capacity)
        self.storage = .allocate(capacity: self.channelCount * self.capacity)
        self.pointers = .allocate(capacity: self.channelCount)
        self.storage.initialize(repeating: 0, count: self.channelCount * self.capacity)
        for channel in 0..<self.channelCount {
            self.pointers[channel] = self.storage.advanced(by: channel * self.capacity)
        }
    }

    deinit {
        storage.deinitialize(count: channelCount * capacity)
        storage.deallocate()
        pointers.deallocate()
    }

    @inline(__always)
    func channel(_ index: Int) -> UnsafeMutablePointer<Float> {
        pointers[index]
    }

    @inline(__always)
    func channelPointers() -> UnsafeMutablePointer<UnsafeMutablePointer<Float>> {
        pointers
    }

    @inline(__always)
    func clear(frameCount: Int) {
        let count = min(max(0, frameCount), capacity)
        for channel in 0..<channelCount {
            pointers[channel].initialize(repeating: 0, count: count)
        }
    }

    @inline(__always)
    func copy(from other: PlanarBuffer, frameCount: Int) {
        let count = min(max(0, frameCount), min(capacity, other.capacity))
        for channel in 0..<min(channelCount, other.channelCount) {
            pointers[channel].update(from: other.pointers[channel], count: count)
        }
    }

    @inline(__always)
    func deinterleave(from input: UnsafePointer<Float>, frameCount: Int) {
        let count = min(max(0, frameCount), capacity)
        for frame in 0..<count {
            for channel in 0..<channelCount {
                pointers[channel][frame] = input[frame * channelCount + channel]
            }
        }
    }

    @inline(__always)
    func interleave(to output: UnsafeMutablePointer<Float>, frameCount: Int) {
        let count = min(max(0, frameCount), capacity)
        for frame in 0..<count {
            for channel in 0..<channelCount {
                output[frame * channelCount + channel] = pointers[channel][frame]
            }
        }
    }
}

internal struct BufferPair {
    let first: PlanarBuffer
    let second: PlanarBuffer
    var currentIsFirst = true

    init(channelCount: Int, capacity: Int) {
        first = PlanarBuffer(channelCount: channelCount, capacity: capacity)
        second = PlanarBuffer(channelCount: channelCount, capacity: capacity)
    }

    var current: PlanarBuffer { currentIsFirst ? first : second }
    var scratch: PlanarBuffer { currentIsFirst ? second : first }

    mutating func swap() {
        currentIsFirst.toggle()
    }
}
