import APOEngine
import CoreAudio
import Darwin
import Foundation
import Synchronization

public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let sampleRate: Double
    public let inputChannelCount: Int
    public let outputChannelCount: Int

    public init(id: AudioObjectID, uid: String, name: String, sampleRate: Double, inputChannelCount: Int, outputChannelCount: Int) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
    }
}

public enum AudioSessionState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case bypassed
    case failed(String)
}

public enum AudioSessionError: Error, LocalizedError {
    case noOutputDevice
    case unsupportedFormat
    case operatingSystem(OSStatus, String)

    public var errorDescription: String? {
        switch self {
        case .noOutputDevice: return "No Core Audio output device is available"
        case .unsupportedFormat: return "The selected Core Audio device is not Float32 PCM"
        case .operatingSystem(let status, let operation): return "\(operation) failed with OSStatus \(status)"
        }
    }
}

public enum AudioDeviceCatalog {
    public static func outputDevices() -> [AudioDeviceInfo] {
        guard let devices = try? AudioHardwareSystem.shared.devices else { return [] }
        return devices.compactMap { device in
            guard (try? device.canBeDefaultOutputDevice) == true else { return nil }
            let input = (try? device.inputStreamConfiguration.reduce(0) { $0 + Int($1.mNumberChannels) }) ?? 0
            let output = (try? device.outputStreamConfiguration.reduce(0) { $0 + Int($1.mNumberChannels) }) ?? 0
            guard output > 0 else { return nil }
            return AudioDeviceInfo(
                id: device.id,
                uid: (try? device.uid) ?? "",
                name: (try? device.name) ?? "Unknown output",
                sampleRate: (try? device.actualSampleRate) ?? 48_000,
                inputChannelCount: input,
                outputChannelCount: output
            )
        }
    }
}

public final class AudioSession: @unchecked Sendable {
    public private(set) var state: AudioSessionState = .stopped
    public var underrunCount: Int { underruns.load(ordering: .relaxed) }

    private var tap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var outputDevice: AudioHardwareDevice?
    private var inputIOProcID: AudioDeviceIOProcID?
    private var outputIOProcID: AudioDeviceIOProcID?
    private var ring: AudioRingBuffer?
    private var crossfader: GraphCrossfader?
    private var tapScratch: UnsafeMutablePointer<Float>?
    private var outputScratch: UnsafeMutablePointer<Float>?
    private let underruns = Synchronization.Atomic<Int>(0)
    private var channelCount = 2
    private var maxFrameCount = 4096

    public init() {}

    deinit { stop() }

    public func start(graph: PreparedGraph, deviceUID: String? = nil) throws {
        stop()
        state = .starting
        do {
            let system = AudioHardwareSystem.shared
            guard let output = try (deviceUID.flatMap { try? system.device(forUID: $0) } ?? system.defaultOutputDevice) else {
                throw AudioSessionError.noOutputDevice
            }
            let outputBuffers = try output.outputStreamConfiguration
            channelCount = max(1, outputBuffers.reduce(0) { $0 + Int($1.mNumberChannels) })
            maxFrameCount = max(256, (try? output.bufferFrameSize) ?? 4096)
            guard channelCount == graph.channelCount else { throw AudioSessionError.unsupportedFormat }

            let sampleCapacity = channelCount * maxFrameCount
            ring = AudioRingBuffer(channelCount: channelCount, capacityFrames: maxFrameCount * 8)
            crossfader = GraphCrossfader(sampleRate: (try? output.actualSampleRate) ?? 48_000, channelCount: channelCount, maxFrameCount: maxFrameCount)
            _ = crossfader?.install(graph)
            tapScratch = .allocate(capacity: sampleCapacity)
            tapScratch?.initialize(repeating: 0, count: sampleCapacity)
            outputScratch = .allocate(capacity: sampleCapacity)
            outputScratch?.initialize(repeating: 0, count: sampleCapacity)

            let ownProcessID = (try? system.process(for: getpid()))?.id
            let excludedProcesses = ownProcessID.map { [$0] } ?? []
            let description: CATapDescription
            if channelCount == 2 {
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
            } else {
                description = CATapDescription(
                    excludingProcesses: excludedProcesses,
                    deviceUID: try output.uid,
                    stream: 0
                )
            }
            description.muteBehavior = .mutedWhenTapped
            description.isPrivate = true
            tap = try system.makeProcessTap(description: description)
            guard let tap else { throw AudioSessionError.operatingSystem(-1, "Creating process tap") }
            let tapFormat = try tap.format
            guard Int(tapFormat.mChannelsPerFrame) == channelCount,
                  tapFormat.mFormatID == kAudioFormatLinearPCM,
                  tapFormat.mBitsPerChannel == 32,
                  tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw AudioSessionError.unsupportedFormat
            }

            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey as String: "APOMac Tap",
                kAudioAggregateDeviceUIDKey as String: "com.apomac.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey as String: true,
                kAudioAggregateDeviceTapListKey as String: [[kAudioSubTapUIDKey as String: try tap.uid]],
                kAudioAggregateDeviceTapAutoStartKey as String: true
            ]
            aggregateDevice = try system.makeAggregateDevice(description: composition)
            guard let aggregateDevice else { throw AudioSessionError.operatingSystem(-2, "Creating aggregate tap device") }
            outputDevice = output

            var inputProc: AudioDeviceIOProcID?
            let inputStatus = AudioDeviceCreateIOProcIDWithBlock(&inputProc, aggregateDevice.id, nil) { [weak self] _, inputData, _, _, _ in
                self?.receiveTap(inputData)
            }
            guard inputStatus == noErr, let inputProc else { throw AudioSessionError.operatingSystem(inputStatus, "Creating tap input client") }
            inputIOProcID = inputProc

            var outputProc: AudioDeviceIOProcID?
            let outputStatus = AudioDeviceCreateIOProcIDWithBlock(&outputProc, output.id, nil) { [weak self] _, _, _, outputData, _ in
                self?.renderOutput(outputData)
            }
            guard outputStatus == noErr, let outputProc else { throw AudioSessionError.operatingSystem(outputStatus, "Creating physical output client") }
            outputIOProcID = outputProc

            let startOutputStatus = AudioDeviceStart(output.id, outputProc)
            guard startOutputStatus == noErr else { throw AudioSessionError.operatingSystem(startOutputStatus, "Starting physical output") }
            let startInputStatus = AudioDeviceStart(aggregateDevice.id, inputProc)
            guard startInputStatus == noErr else { throw AudioSessionError.operatingSystem(startInputStatus, "Starting aggregate tap") }
            state = .running
        } catch {
            stop()
            state = .bypassed
            throw error
        }
    }

    public func install(graph: PreparedGraph) -> Bool {
        crossfader?.install(graph) ?? false
    }

    public func stop() {
        if let outputDevice, let outputIOProcID {
            _ = AudioDeviceStop(outputDevice.id, outputIOProcID)
            _ = AudioDeviceDestroyIOProcID(outputDevice.id, outputIOProcID)
        }
        if let aggregateDevice, let inputIOProcID {
            _ = AudioDeviceStop(aggregateDevice.id, inputIOProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDevice.id, inputIOProcID)
        }
        if let aggregateDevice { try? AudioHardwareSystem.shared.destroyAggregateDevice(aggregateDevice) }
        if let tap { try? AudioHardwareSystem.shared.destroyProcessTap(tap) }
        if let tapScratch {
            tapScratch.deinitialize(count: channelCount * maxFrameCount)
            tapScratch.deallocate()
        }
        if let outputScratch {
            outputScratch.deinitialize(count: channelCount * maxFrameCount)
            outputScratch.deallocate()
        }
        tap = nil
        aggregateDevice = nil
        outputDevice = nil
        inputIOProcID = nil
        outputIOProcID = nil
        tapScratch = nil
        outputScratch = nil
        ring = nil
        crossfader = nil
        state = .stopped
    }

    private func receiveTap(_ inputData: UnsafePointer<AudioBufferList>?) {
        guard let inputData, let scratch = tapScratch, let crossfader, let ring else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let firstBufferChannels = max(1, Int(buffers.first?.mNumberChannels ?? 1))
        let frames = min(maxFrameCount, buffers.first.map { Int($0.mDataByteSize) / (MemoryLayout<Float>.size * firstBufferChannels) } ?? 0)
        guard frames > 0 else { return }
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                let buffer = buffers.indices.contains(channel) ? buffers[channel] : buffers.first!
                if let data = buffer.mData {
                    if buffers.count == 1 {
                        scratch[frame * channelCount + channel] = data.assumingMemoryBound(to: Float.self)[frame * channelCount + channel]
                    } else {
                        scratch[frame * channelCount + channel] = data.assumingMemoryBound(to: Float.self)[frame]
                    }
                } else {
                    scratch[frame * channelCount + channel] = 0
                }
            }
        }
        crossfader.process(input: scratch, output: scratch, frameCount: frames)
        ring.write(scratch, frameCount: frames)
    }

    private func renderOutput(_ outputData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let outputData, let scratch = outputScratch, let ring else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        let firstBufferChannels = max(1, Int(buffers.first?.mNumberChannels ?? 1))
        let frames = min(maxFrameCount, buffers.first.map { Int($0.mDataByteSize) / (MemoryLayout<Float>.size * firstBufferChannels) } ?? 0)
        guard frames > 0 else { return }
        let received = ring.read(to: scratch, frameCount: frames)
        if received < frames {
            _ = underruns.wrappingAdd(1, ordering: .relaxed)
            scratch.advanced(by: received * channelCount).update(repeating: 0, count: (frames - received) * channelCount)
        }
        for (index, var buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            let destination = data.assumingMemoryBound(to: Float.self)
            let channel = min(index, channelCount - 1)
            if buffers.count == 1 {
                destination.update(from: scratch, count: frames * channelCount)
            } else {
                for frame in 0..<frames { destination[frame] = scratch[frame * channelCount + channel] }
            }
            buffer.mDataByteSize = UInt32(frames * channelCount * MemoryLayout<Float>.size)
        }
    }
}
