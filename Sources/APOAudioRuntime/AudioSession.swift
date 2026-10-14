import APOEngine
import AudioToolbox
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

/// The format the running session processes; profiles must be compiled for it.
public struct AudioOutputFormat: Sendable, Equatable {
    public let deviceUID: String
    public let deviceName: String
    public let sampleRate: Double
    public let channelCount: Int
}

public enum AudioSessionState: Sendable, Equatable {
    case stopped
    case running
    case failed(String)
}

public enum AudioSessionError: Error, LocalizedError {
    case noOutputDevice
    case unsupportedFormat(String)
    case operatingSystem(OSStatus, String)

    public var errorDescription: String? {
        switch self {
        case .noOutputDevice:
            return "No output device is available."
        case .unsupportedFormat(let detail):
            return "The output device uses an unsupported audio format (\(detail))."
        case .operatingSystem(let status, let operation):
            return "\(operation) failed (OSStatus \(status))."
        }
    }

    /// Tap creation fails like this when system audio recording permission
    /// has not been granted.
    public var isLikelyPermissionDenied: Bool {
        if case .operatingSystem(_, let operation) = self { return operation == "Creating the system audio tap" }
        return false
    }
}

public enum AudioDeviceCatalog {
    public static func outputDevices() -> [AudioDeviceInfo] {
        guard let devices = try? AudioHardwareSystem.shared.devices else { return [] }
        return devices.compactMap { device in
            guard (try? device.canBeDefaultOutputDevice) == true else { return nil }
            let input = (try? device.inputStreamConfiguration.reduce(0) { $0 + Int($1.mNumberChannels) }) ?? 0
            let output = (try? device.outputStreamConfiguration.reduce(0) { $0 + Int($1.mNumberChannels) }) ?? 0
            let uid = (try? device.uid) ?? ""
            // Our own private processing device is not a user-facing output.
            guard output > 0, !uid.hasPrefix(AudioSession.aggregateUIDPrefix) else { return nil }
            return AudioDeviceInfo(
                id: device.id,
                uid: uid,
                name: ((try? device.name) ?? "Unknown output").trimmingCharacters(in: .whitespacesAndNewlines),
                sampleRate: (try? device.nominalSampleRate) ?? 48_000,
                inputChannelCount: input,
                outputChannelCount: output
            )
        }
    }

    public static func defaultOutputDeviceUID() -> String? {
        try? AudioHardwareSystem.shared.defaultOutputDevice?.uid
    }

    /// Changes the macOS sound output, exactly like choosing it in Control Center.
    public static func setDefaultOutputDevice(uid: String) throws {
        guard let device = try AudioHardwareSystem.shared.device(forUID: uid) else {
            throw AudioSessionError.noOutputDevice
        }
        try AudioHardwareSystem.shared.setDefaultOutputDevice(device)
    }

    /// Calls `handler` on the main queue whenever devices appear, disappear or
    /// the default output changes. Keep the returned token alive.
    public static func observeChanges(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        let observer = PropertyObserver()
        observer.add(objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices, handler: handler)
        observer.add(objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, handler: handler)
        return observer
    }
}

/// Owns the Core Audio objects for system-wide processing.
///
/// A private process tap captures (and mutes) everything other apps play to
/// the output device. The tap and the output device are combined into one
/// private aggregate device, so a single IOProc reads the tapped audio and
/// writes the processed audio on the same clock. The tap is drift
/// compensated by the HAL, so there is no ring buffer, no clock drift and no
/// sample-rate mismatch between capture and playback.
///
/// Use from the main thread.
public final class AudioSession: @unchecked Sendable {
    static let aggregateUIDPrefix = "com.apomac.aggregate."

    public private(set) var state: AudioSessionState = .stopped
    public private(set) var format: AudioOutputFormat?
    /// Called on the main queue when the running device changes format or
    /// disappears; the owner should restart the session.
    public var onDeviceChange: (@Sendable () -> Void)?

    private var tap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var renderer: Renderer?
    private var observer: PropertyObserver?

    public init() {}

    deinit { stop() }

    /// Fraction of the IO cycle spent processing (smoothed), 0...1+.
    public var dspLoad: Double {
        Double(renderer?.loadPermille.load(ordering: .relaxed) ?? 0) / 1000
    }

    /// Starts processing on `deviceUID` (or the current default output).
    /// Audio passes through unprocessed until a graph is installed.
    @discardableResult
    public func start(deviceUID: String?) throws -> AudioOutputFormat {
        stop()
        do {
            let format = try startUnchecked(deviceUID: deviceUID)
            self.format = format
            state = .running
            return format
        } catch {
            stop()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Crossfades to `graph`. Returns false if the graph was compiled for a
    /// different format than the running session.
    @discardableResult
    public func install(graph: PreparedGraph) -> Bool {
        guard let renderer, let format,
              graph.channelCount == format.channelCount,
              abs(graph.sampleRate - format.sampleRate) < 0.5 else { return false }
        return renderer.crossfader.install(graph)
    }

    public func stop() {
        observer = nil
        if let aggregateDevice, let ioProcID {
            _ = AudioDeviceStop(aggregateDevice.id, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
        }
        if let aggregateDevice { try? AudioHardwareSystem.shared.destroyAggregateDevice(aggregateDevice) }
        if let tap { try? AudioHardwareSystem.shared.destroyProcessTap(tap) }
        // The IOProc is gone, so the renderer can release its graphs here.
        renderer?.crossfader.releaseAll()
        ioProcID = nil
        aggregateDevice = nil
        tap = nil
        renderer = nil
        format = nil
        state = .stopped
    }

    private func startUnchecked(deviceUID: String?) throws -> AudioOutputFormat {
        let system = AudioHardwareSystem.shared
        let requested = try deviceUID.flatMap { try system.device(forUID: $0) }
        guard let output = try requested ?? system.defaultOutputDevice else {
            throw AudioSessionError.noOutputDevice
        }
        let outputUID = try output.uid
        let outputName = ((try? output.name) ?? "Output").trimmingCharacters(in: .whitespacesAndNewlines)

        let ownProcess = try? system.process(for: getpid())
        let tapDescription = CATapDescription(
            excludingProcesses: ownProcess.map { [$0.id] } ?? [],
            deviceUID: outputUID,
            stream: 0
        )
        tapDescription.name = "APOMac"
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true
        let tap: AudioHardwareTap?
        do {
            tap = try system.makeProcessTap(description: tapDescription)
        } catch let error as AudioHardwareError {
            throw AudioSessionError.operatingSystem(error.error, "Creating the system audio tap")
        }
        guard let tap else { throw AudioSessionError.operatingSystem(-1, "Creating the system audio tap") }
        self.tap = tap

        let tapFormat = try tap.format
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mBitsPerChannel == 32,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw AudioSessionError.unsupportedFormat("tap is not 32-bit float PCM")
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "APOMac",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: try tap.uid,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        let aggregate: AudioHardwareAggregateDevice?
        do {
            aggregate = try system.makeAggregateDevice(description: composition)
        } catch let error as AudioHardwareError {
            throw AudioSessionError.operatingSystem(error.error, "Creating the processing device")
        }
        guard let aggregate else { throw AudioSessionError.operatingSystem(-1, "Creating the processing device") }
        aggregateDevice = aggregate

        let sampleRate = try aggregate.nominalSampleRate
        let outputBuffers = try aggregate.outputStreamConfiguration
        let channelCount = outputBuffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channelCount > 0, sampleRate > 0 else {
            throw AudioSessionError.unsupportedFormat("no output channels")
        }
        // Aggregate inputs list the sub-device's own inputs (e.g. a headset
        // microphone) first and the tap last.
        let inputBuffers = try aggregate.inputStreamConfiguration
        let tapIsInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let tapBufferCount = tapIsInterleaved ? 1 : Int(tapFormat.mChannelsPerFrame)
        let tapBufferOffset = max(0, inputBuffers.count - tapBufferCount)

        let renderer = Renderer(
            sampleRate: sampleRate,
            channelCount: channelCount,
            tapBufferOffset: tapBufferOffset
        )
        self.renderer = renderer

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) { _, inputData, _, outputData, _ in
            renderer.render(input: inputData, output: outputData)
        }
        guard status == noErr, let procID else { throw AudioSessionError.operatingSystem(status, "Creating the audio callback") }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate.id, procID)
        guard startStatus == noErr else { throw AudioSessionError.operatingSystem(startStatus, "Starting audio processing") }

        let observer = PropertyObserver()
        let notify: @Sendable () -> Void = { [weak self] in self?.onDeviceChange?() }
        observer.add(objectID: output.id, selector: kAudioDevicePropertyNominalSampleRate, handler: notify)
        observer.add(objectID: output.id, selector: kAudioDevicePropertyDeviceIsAlive, handler: notify)
        observer.add(objectID: output.id, selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput, handler: notify)
        // coreaudiod restarts (driver installs, crashes) destroy the tap and
        // the aggregate device without any per-device notification.
        observer.add(objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyServiceRestarted, handler: notify)
        self.observer = observer

        return AudioOutputFormat(deviceUID: outputUID, deviceName: outputName, sampleRate: sampleRate, channelCount: channelCount)
    }
}

/// Render-thread state, captured by the IOProc block.
private final class Renderer: @unchecked Sendable {
    static let capacityFrames = 16_384

    let crossfader: GraphCrossfader
    let loadPermille = Atomic<Int>(0)
    private let channelCount: Int
    private let sampleRate: Double
    private let tapBufferOffset: Int
    private let input: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>
    private let ticksToSeconds: Double
    private var smoothedLoad = 0.0

    init(sampleRate: Double, channelCount: Int, tapBufferOffset: Int) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.tapBufferOffset = tapBufferOffset
        crossfader = GraphCrossfader(sampleRate: sampleRate, channelCount: channelCount, maxFrameCount: 4_096)
        input = .allocate(capacity: Self.capacityFrames * channelCount)
        output = .allocate(capacity: Self.capacityFrames * channelCount)
        input.initialize(repeating: 0, count: Self.capacityFrames * channelCount)
        output.initialize(repeating: 0, count: Self.capacityFrames * channelCount)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    deinit {
        input.deinitialize(count: Self.capacityFrames * channelCount)
        input.deallocate()
        output.deinitialize(count: Self.capacityFrames * channelCount)
        output.deallocate()
    }

    func render(input inputData: UnsafePointer<AudioBufferList>?, output outputData: UnsafeMutablePointer<AudioBufferList>?) {
        let started = mach_absolute_time()
        guard let outputData else { return }
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard let first = outputBuffers.first, first.mNumberChannels > 0 else { return }
        let deviceFrames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        let frames = min(deviceFrames, Self.capacityFrames)
        guard frames > 0 else { return }

        gatherTap(inputData, frames: frames)
        crossfader.process(input: input, output: output, frameCount: frames)
        scatter(to: outputBuffers, frames: frames, deviceFrames: deviceFrames)

        let elapsed = Double(mach_absolute_time() - started) * ticksToSeconds
        let load = elapsed / (Double(frames) / sampleRate)
        smoothedLoad = smoothedLoad * 0.9 + load * 0.1
        loadPermille.store(Int(smoothedLoad * 1000), ordering: .relaxed)
    }

    private func gatherTap(_ inputData: UnsafePointer<AudioBufferList>?, frames: Int) {
        input.update(repeating: 0, count: frames * channelCount)
        guard let inputData else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard tapBufferOffset < buffers.count else { return }
        var channel = 0
        for index in tapBufferOffset..<buffers.count {
            let buffer = buffers[index]
            let bufferChannels = Int(buffer.mNumberChannels)
            guard bufferChannels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                channel += bufferChannels
                continue
            }
            let available = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * bufferChannels))
            for bufferChannel in 0..<bufferChannels where channel + bufferChannel < channelCount {
                let destination = channel + bufferChannel
                for frame in 0..<available {
                    input[frame * channelCount + destination] = data[frame * bufferChannels + bufferChannel]
                }
            }
            channel += bufferChannels
        }
    }

    private func scatter(to buffers: UnsafeMutableAudioBufferListPointer, frames: Int, deviceFrames: Int) {
        var channel = 0
        for buffer in buffers {
            let bufferChannels = Int(buffer.mNumberChannels)
            guard bufferChannels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                channel += bufferChannels
                continue
            }
            let capacity = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * bufferChannels)
            for bufferChannel in 0..<bufferChannels {
                let source = channel + bufferChannel
                for frame in 0..<min(frames, capacity) {
                    data[frame * bufferChannels + bufferChannel] = source < channelCount ? output[frame * channelCount + source] : 0
                }
            }
            if capacity > frames {
                (data + frames * bufferChannels).update(repeating: 0, count: (capacity - frames) * bufferChannels)
            }
            channel += bufferChannels
        }
    }
}

/// Registers Core Audio property listeners and removes them on deinit.
private final class PropertyObserver: @unchecked Sendable {
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func add(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping @Sendable () -> Void
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block) == noErr {
            registrations.append((objectID, address, block))
        }
    }

    deinit {
        for (objectID, address, block) in registrations {
            var address = address
            AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
        }
    }
}
