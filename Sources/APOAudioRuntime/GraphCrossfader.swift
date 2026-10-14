import APOEngine
import Foundation
import Synchronization

/// Hands compiled graphs from the main thread to the render thread and
/// crossfades between them.
///
/// The render side never locks, allocates or releases objects:
/// - `install` retains the graph into a single-slot mailbox (replacing any
///   graph the render thread has not picked up yet);
/// - the render thread takes the mailbox graph when no crossfade is running
///   and fades to it;
/// - the graph it fades away from goes into a trash queue that the main
///   thread drains, so deallocation never happens on the render thread.
final class GraphCrossfader: @unchecked Sendable {
    private static let trashCapacity = 16

    let channelCount: Int
    private let maxFrameCount: Int
    private let crossfadeFrames: Int

    private let mailbox = Atomic<Int>(0)
    private let trash: UnsafeMutablePointer<Int>
    private let trashWritten = Atomic<Int>(0)
    private let trashRead = Atomic<Int>(0)

    // Render-thread state (also touched by the main thread only while the
    // render thread is stopped, in `releaseAll`).
    private var current: Unmanaged<PreparedGraph>?
    private var target: Unmanaged<PreparedGraph>?
    private var transitionProgress = 0
    private let oldOutput: UnsafeMutablePointer<Float>
    private let newOutput: UnsafeMutablePointer<Float>

    init(sampleRate: Double, channelCount: Int, maxFrameCount: Int, crossfadeDuration: Double = 0.02) {
        self.channelCount = max(1, channelCount)
        self.maxFrameCount = max(1, maxFrameCount)
        self.crossfadeFrames = max(1, Int((sampleRate * crossfadeDuration).rounded()))
        trash = .allocate(capacity: Self.trashCapacity)
        trash.initialize(repeating: 0, count: Self.trashCapacity)
        let sampleCapacity = self.channelCount * self.maxFrameCount
        oldOutput = .allocate(capacity: sampleCapacity)
        newOutput = .allocate(capacity: sampleCapacity)
        oldOutput.initialize(repeating: 0, count: sampleCapacity)
        newOutput.initialize(repeating: 0, count: sampleCapacity)
    }

    deinit {
        releaseAll()
        trash.deinitialize(count: Self.trashCapacity)
        trash.deallocate()
        let count = channelCount * maxFrameCount
        oldOutput.deinitialize(count: count)
        oldOutput.deallocate()
        newOutput.deinitialize(count: count)
        newOutput.deallocate()
    }

    /// Main thread. The newest installed graph always wins.
    @discardableResult
    func install(_ graph: PreparedGraph) -> Bool {
        guard graph.channelCount == channelCount else { return false }
        let raw = Int(bitPattern: Unmanaged.passRetained(graph).toOpaque())
        let previous = mailbox.exchange(raw, ordering: .acquiringAndReleasing)
        release(previous)
        drainTrash()
        return true
    }

    /// Main thread: releases graphs the render thread has retired.
    func drainTrash() {
        var read = trashRead.load(ordering: .relaxed)
        let written = trashWritten.load(ordering: .acquiring)
        while read != written {
            let slot = read % Self.trashCapacity
            release(trash[slot])
            trash[slot] = 0
            read += 1
        }
        trashRead.store(read, ordering: .releasing)
    }

    /// Main thread, only while the render thread is not running.
    func releaseAll() {
        drainTrash()
        release(mailbox.exchange(0, ordering: .acquiringAndReleasing))
        current?.release()
        target?.release()
        current = nil
        target = nil
        transitionProgress = 0
    }

    /// Render thread.
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        takeMailboxGraphIfPossible()

        var offset = 0
        while offset < frameCount {
            let count = min(frameCount - offset, maxFrameCount)
            let sampleOffset = offset * channelCount
            processChunk(input: input + sampleOffset, output: output + sampleOffset, frameCount: count)
            offset += count
        }
    }

    private func takeMailboxGraphIfPossible() {
        guard target == nil, mailbox.load(ordering: .relaxed) != 0 else { return }
        // Finishing a crossfade retires one graph; make sure there is room.
        let used = trashWritten.load(ordering: .relaxed) - trashRead.load(ordering: .acquiring)
        guard used < Self.trashCapacity else { return }
        let raw = mailbox.exchange(0, ordering: .acquiringAndReleasing)
        guard raw != 0, let pointer = UnsafeRawPointer(bitPattern: raw) else { return }
        target = Unmanaged<PreparedGraph>.fromOpaque(pointer)
        transitionProgress = 0
    }

    private func processChunk(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        let sampleCount = frameCount * channelCount
        guard let target else {
            if let current {
                current._withUnsafeGuaranteedRef { $0.process(input: input, output: output, frameCount: frameCount) }
            } else {
                output.update(from: input, count: sampleCount)
            }
            return
        }

        // Fade from the current graph (or unprocessed audio) to the target.
        if let current {
            current._withUnsafeGuaranteedRef { $0.process(input: input, output: oldOutput, frameCount: frameCount) }
        } else {
            oldOutput.update(from: input, count: sampleCount)
        }
        target._withUnsafeGuaranteedRef { $0.process(input: input, output: newOutput, frameCount: frameCount) }
        for frame in 0..<frameCount {
            let progress = min(1.0, Double(transitionProgress + frame) / Double(crossfadeFrames))
            let newWeight = Float((1.0 - cos(Double.pi * progress)) * 0.5)
            let oldWeight = 1 - newWeight
            let offset = frame * channelCount
            for channel in 0..<channelCount {
                output[offset + channel] = oldOutput[offset + channel] * oldWeight + newOutput[offset + channel] * newWeight
            }
        }
        transitionProgress += frameCount
        if transitionProgress >= crossfadeFrames {
            if let current { retire(current) }
            self.current = target
            self.target = nil
            transitionProgress = 0
        }
    }

    private func retire(_ graph: Unmanaged<PreparedGraph>) {
        let written = trashWritten.load(ordering: .relaxed)
        trash[written % Self.trashCapacity] = Int(bitPattern: graph.toOpaque())
        trashWritten.store(written + 1, ordering: .releasing)
    }

    private func release(_ raw: Int) {
        guard raw != 0, let pointer = UnsafeRawPointer(bitPattern: raw) else { return }
        Unmanaged<PreparedGraph>.fromOpaque(pointer).release()
    }
}
