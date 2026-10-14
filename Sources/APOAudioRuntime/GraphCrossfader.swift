import APOEngine
import Foundation
import Synchronization

final class GraphCrossfader: @unchecked Sendable {
    private let channelCount: Int
    private let maxFrameCount: Int
    private let crossfadeFrames: Int
    private let slots: UnsafeMutablePointer<PreparedGraph?>
    private let activeSlot = Atomic<Int>(0)
    private let transitionSlot = Atomic<Int>(-1)
    private var transitionProgress = 0
    private let oldOutput: UnsafeMutablePointer<Float>
    private let newOutput: UnsafeMutablePointer<Float>

    init(sampleRate: Double, channelCount: Int, maxFrameCount: Int) {
        self.channelCount = max(1, channelCount)
        self.maxFrameCount = max(1, maxFrameCount)
        self.crossfadeFrames = max(1, Int((sampleRate * 0.010).rounded()))
        self.slots = .allocate(capacity: 2)
        self.slots.initialize(repeating: nil, count: 2)
        let sampleCapacity = self.channelCount * self.maxFrameCount
        self.oldOutput = .allocate(capacity: sampleCapacity)
        self.newOutput = .allocate(capacity: sampleCapacity)
        self.oldOutput.initialize(repeating: 0, count: sampleCapacity)
        self.newOutput.initialize(repeating: 0, count: sampleCapacity)
    }

    deinit {
        slots.deinitialize(count: 2)
        slots.deallocate()
        let count = channelCount * maxFrameCount
        oldOutput.deinitialize(count: count)
        oldOutput.deallocate()
        newOutput.deinitialize(count: count)
        newOutput.deallocate()
    }

    func install(_ graph: PreparedGraph) -> Bool {
        let active = activeSlot.load(ordering: .acquiring)
        if slots[active] == nil {
            slots[active] = graph
            return true
        }
        guard transitionSlot.load(ordering: .acquiring) < 0 else { return false }
        let candidate = 1 - active
        slots[candidate] = graph
        transitionProgress = 0
        transitionSlot.store(candidate, ordering: .releasing)
        return true
    }

    @inline(__always)
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount requestedFrameCount: Int) {
        let frameCount = min(max(0, requestedFrameCount), maxFrameCount)
        guard frameCount > 0 else { return }
        let active = activeSlot.load(ordering: .acquiring)
        guard let activeGraph = slots[active] else {
            output.update(repeating: 0, count: frameCount * channelCount)
            return
        }

        let pending = transitionSlot.load(ordering: .acquiring)
        if pending >= 0, let pendingGraph = slots[pending] {
            activeGraph.process(input: input, output: oldOutput, frameCount: frameCount)
            pendingGraph.process(input: input, output: newOutput, frameCount: frameCount)
            for frame in 0..<frameCount {
                let progress = min(1.0, Double(transitionProgress + frame) / Double(crossfadeFrames))
                let cosine = (1.0 - cos(Double.pi * progress)) * 0.5
                let oldWeight = Float(1.0 - cosine)
                let newWeight = Float(cosine)
                let offset = frame * channelCount
                for channel in 0..<channelCount {
                    output[offset + channel] = oldOutput[offset + channel] * oldWeight + newOutput[offset + channel] * newWeight
                }
            }
            transitionProgress += frameCount
            if transitionProgress >= crossfadeFrames {
                activeSlot.store(pending, ordering: .releasing)
                transitionSlot.store(-1, ordering: .releasing)
                transitionProgress = 0
            }
        } else {
            activeGraph.process(input: input, output: output, frameCount: frameCount)
        }
        if requestedFrameCount > frameCount {
            output.advanced(by: frameCount * channelCount).update(repeating: 0, count: (requestedFrameCount - frameCount) * channelCount)
        }
    }
}
