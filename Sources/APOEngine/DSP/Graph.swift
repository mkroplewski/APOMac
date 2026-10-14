import Accelerate
import Foundation

internal protocol RenderNode: AnyObject {
    var isInPlace: Bool { get }
    var displayName: String { get }
    var responseIsApproximate: Bool { get }
    func process(input: PlanarBuffer, output: PlanarBuffer, frameCount: Int)
    func reset()
    func responseMagnitude(frequency: Double, sampleRate: Double, channel: Int) -> Double
}

extension RenderNode {
    func reset() {}
    var responseIsApproximate: Bool { false }
    func responseMagnitude(frequency: Double, sampleRate: Double, channel: Int) -> Double { 1 }
}

private func biquadResponseMagnitude(_ coefficients: BiquadCoefficients, frequency: Double, sampleRate: Double) -> Double {
    let omega = 2.0 * Double.pi * frequency / max(sampleRate, 1.0)
    let z1Real = cos(omega)
    let z1Imag = -sin(omega)
    let z2Real = cos(2.0 * omega)
    let z2Imag = -sin(2.0 * omega)

    let numeratorReal = coefficients.b0 + coefficients.b1 * z1Real + coefficients.b2 * z2Real
    let numeratorImag = coefficients.b1 * z1Imag + coefficients.b2 * z2Imag
    let denominatorReal = 1.0 + coefficients.a1 * z1Real + coefficients.a2 * z2Real
    let denominatorImag = coefficients.a1 * z1Imag + coefficients.a2 * z2Imag
    let numerator = hypot(numeratorReal, numeratorImag)
    let denominator = max(hypot(denominatorReal, denominatorImag), 1.0e-15)
    return numerator / denominator
}

private func firResponseMagnitude(
    coefficient: (Int) -> Double,
    count: Int,
    frequency: Double,
    sampleRate: Double
) -> Double {
    let omega = 2.0 * Double.pi * frequency / max(sampleRate, 1.0)
    var real = 0.0
    var imaginary = 0.0
    for index in 0..<count {
        let phase = omega * Double(index)
        let value = coefficient(index)
        real += value * cos(phase)
        imaginary -= value * sin(phase)
    }
    return hypot(real, imaginary)
}

internal final class PreampNode: RenderNode {
    let isInPlace = true
    let displayName: String
    private let factor: Float

    init(gainDB: Double) {
        displayName = "Preamp \(gainDB) dB"
        factor = Float(pow(10.0, gainDB / 20.0))
    }

    func process(input: PlanarBuffer, output: PlanarBuffer, frameCount: Int) {
        guard frameCount > 0 else { return }
        var scalar = factor
        withUnsafePointer(to: &scalar) { scalarPointer in
            for channel in 0..<input.channelCount {
                vDSP_vsmul(input.channel(channel), 1, scalarPointer, output.channel(channel), 1, vDSP_Length(frameCount))
            }
        }
    }

    func responseMagnitude(frequency: Double, sampleRate: Double, channel: Int) -> Double {
        Double(factor)
    }

}

internal final class BiquadNode: RenderNode {
    let isInPlace = true
    let displayName: String
    private let setup: vDSP_biquad_Setup
    private let coefficients: BiquadCoefficients
    private let sectionCount: Int
    private let delays: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let channelCount: Int

    init(coefficients: BiquadCoefficients, channelCount: Int) {
        self.displayName = "Biquad"
        self.coefficients = coefficients
        self.sectionCount = 1
        self.channelCount = channelCount
        var created: vDSP_biquad_Setup?
        let values = coefficients.vDSPCoefficients
        values.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                created = vDSP_biquad_CreateSetup(baseAddress, 1)
            }
        }
        guard let created else { fatalError("Unable to create vDSP biquad setup") }
        self.setup = created
        self.delays = .allocate(capacity: channelCount)
        for channel in 0..<channelCount {
            let delay = UnsafeMutablePointer<Float>.allocate(capacity: 2 * (sectionCount + 1))
            delay.initialize(repeating: 0, count: 2 * (sectionCount + 1))
            delays[channel] = delay
        }
    }

    deinit {
        for channel in 0..<channelCount {
            delays[channel].deinitialize(count: 2 * (sectionCount + 1))
            delays[channel].deallocate()
        }
        delays.deallocate()
        vDSP_biquad_DestroySetup(setup)
    }

    func process(input: PlanarBuffer, output: PlanarBuffer, frameCount: Int) {
        guard frameCount > 0 else { return }
        for channel in 0..<channelCount {
            vDSP_biquad(
                setup,
                delays[channel],
                input.channel(channel),
                1,
                output.channel(channel),
                1,
                vDSP_Length(frameCount)
            )
        }
    }

    func reset() {
        for channel in 0..<channelCount {
            delays[channel].update(repeating: 0, count: 2 * (sectionCount + 1))
        }
    }

    func responseMagnitude(frequency: Double, sampleRate: Double, channel: Int) -> Double {
        biquadResponseMagnitude(coefficients, frequency: frequency, sampleRate: sampleRate)
    }
}

internal final class IIRNode: RenderNode {
    let isInPlace = true
    let displayName = "IIR"
    private let order: Int
    private let b0: Double
    private let b: UnsafeMutablePointer<Double>
    private let a: UnsafeMutablePointer<Double>
    private let x: UnsafeMutablePointer<Double>
    private let y: UnsafeMutablePointer<Double>
    private let channelCount: Int

    init(coefficients: [Double], channelCount: Int) {
        precondition(coefficients.count >= 4 && coefficients.count % 2 == 0)
        self.order = coefficients.count / 2 - 1
        self.channelCount = channelCount
        let a0 = coefficients[order + 1]
        self.b0 = coefficients[0] / a0
        self.b = .allocate(capacity: order)
        self.a = .allocate(capacity: order)
        self.x = .allocate(capacity: order * channelCount)
        self.y = .allocate(capacity: order * channelCount)
        for index in 0..<order {
            b[index] = coefficients[index + 1] / a0
            a[index] = -coefficients[index + order + 2] / a0
        }
        x.initialize(repeating: 0, count: order * channelCount)
        y.initialize(repeating: 0, count: order * channelCount)
    }

    deinit {
        b.deinitialize(count: order)
        b.deallocate()
        a.deinitialize(count: order)
        a.deallocate()
        x.deinitialize(count: order * channelCount)
        x.deallocate()
        y.deinitialize(count: order * channelCount)
        y.deallocate()
    }

    func process(input: PlanarBuffer, output: PlanarBuffer, frameCount: Int) {
        guard frameCount > 0 else { return }
        for channel in 0..<channelCount {
            let inputPointer = input.channel(channel)
            let outputPointer = output.channel(channel)
            let xState = x.advanced(by: channel * order)
            let yState = y.advanced(by: channel * order)
            for frame in 0..<frameCount {
                let sample = Double(inputPointer[frame])
                var sum = b0 * sample
                if order > 0 {
                    if order > 1 {
                        for index in stride(from: order - 1, through: 1, by: -1) {
                            sum += b[index] * xState[index]
                            xState[index] = xState[index - 1]
                        }
                    }
                    sum += b[0] * xState[0]
                    if order > 1 {
                        for index in stride(from: order - 1, through: 1, by: -1) {
                            sum += a[index] * yState[index]
                            yState[index] = yState[index - 1]
                        }
                    }
                    sum += a[0] * yState[0]
                    xState[0] = sample
                    yState[0] = sum
                }
                outputPointer[frame] = Float(sum)
            }
        }
    }

    func reset() {
        x.update(repeating: 0, count: order * channelCount)
        y.update(repeating: 0, count: order * channelCount)
    }

    func responseMagnitude(frequency: Double, sampleRate: Double, channel: Int) -> Double {
        let omega = 2.0 * Double.pi * frequency / max(sampleRate, 1.0)
        var numeratorReal = b0
        var numeratorImag = 0.0
        var denominatorReal = 1.0
        var denominatorImag = 0.0
        for index in 0..<order {
            let phase = omega * Double(index + 1)
            let cosine = cos(phase)
            let sine = -sin(phase)
            numeratorReal += b[index] * cosine
            numeratorImag += b[index] * sine
            denominatorReal -= a[index] * cosine
            denominatorImag -= a[index] * sine
        }
        return hypot(numeratorReal, numeratorImag) / max(hypot(denominatorReal, denominatorImag), 1.0e-15)
    }
}

internal final class DelayNode: RenderNode {
    let isInPlace = false
    let displayName = "Delay"
    private let bufferLength: Int
    private let channelCount: Int
    private let buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private var bufferOffset = 0

    init(delaySamples: Int, channelCount: Int) {
        self.bufferLength = max(0, delaySamples)
        self.channelCount = channelCount
        self.buffers = .allocate(capacity: channelCount)
        if bufferLength > 0 {
            for channel in 0..<channelCount {
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: bufferLength)
                buffer.initialize(repeating: 0, count: bufferLength)
                buffers[channel] = buffer
            }
        } else {
            for channel in 0..<channelCount {
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
                buffer.initialize(to: 0)
                buffers[channel] = buffer
            }
        }
    }

    deinit {
        for channel in 0..<channelCount {
            let count = max(1, bufferLength)
            buffers[channel].deinitialize(count: count)
            buffers[channel].deallocate()
        }
        buffers.deallocate()
    }

    func process(input: PlanarBuffer, output: PlanarBuffer, frameCount: Int) {
        guard frameCount > 0 else { return }
        if bufferLength == 0 {
            output.copy(from: input, frameCount: frameCount)
            return
        }

        for channel in 0..<channelCount {
            let inputPointer = input.channel(channel)
            let outputPointer = output.channel(channel)
            let delayBuffer = buffers[channel]
            for frame in 0..<frameCount {
                let index = (bufferOffset + frame) % bufferLength
                outputPointer[frame] = delayBuffer[index]
                delayBuffer[index] = inputPointer[frame]
            }
        }
        bufferOffset = (bufferOffset + frameCount) % bufferLength
    }

    func reset() {
        bufferOffset = 0
        if bufferLength > 0 {
            for channel in 0..<channelCount {
                buffers[channel].update(repeating: 0, count: bufferLength)
            }
        }
    }

    func responseMagnitude(frequency: Double, sampleRate: Double, channel: Int) -> Double { 1 }
}

internal struct CopySummand {
    let channel: Int?
    let factor: Float
}

internal struct CopyAssignment {
    let targetChannel: Int
    let summands: [CopySummand]
}

internal final class CopyNode: RenderNode {
    let isInPlace = false
    let displayName = "Copy"
    private let assignments: [CopyAssignment]
    private let channelCount: Int

    init(assignments: [CopyAssignment], channelCount: Int) {
        self.assignments = assignments
        self.channelCount = channelCount
    }

    func process(input: PlanarBuffer, output: PlanarBuffer, frameCount: Int) {
        output.copy(from: input, frameCount: frameCount)
        for assignment in assignments {
            guard assignment.targetChannel >= 0, assignment.targetChannel < channelCount else { continue }
            let destination = output.channel(assignment.targetChannel)
            for frame in 0..<frameCount {
                var value: Float = 0
                for summand in assignment.summands {
                    if let source = summand.channel {
                        guard source >= 0, source < channelCount else { continue }
                        value += input.channel(source)[frame] * summand.factor
                    } else {
                        value += summand.factor
                    }
                }
                destination[frame] = value
            }
        }
    }

    func reset() {}

    var responseIsApproximate: Bool { true }
}

/// Applies a node to the channels selected by the current APO Channel scope.
/// The scratch buffers are created with the graph, never from the render callback.
internal final class ScopedNode: RenderNode {
    let isInPlace = false
    let displayName: String
    private let inner: RenderNode
    private let selectedChannels: [Int]
    private let inputScratch: PlanarBuffer
    private let outputScratch: PlanarBuffer

    init(inner: RenderNode, selectedChannels: [Int], channelCount: Int, maxFrameCount: Int) {
        self.inner = inner
        self.selectedChannels = selectedChannels
        self.displayName = "\(inner.displayName) [\(selectedChannels.map(String.init).joined(separator: ", "))]"
        self.inputScratch = PlanarBuffer(channelCount: channelCount, capacity: maxFrameCount)
        self.outputScratch = PlanarBuffer(channelCount: channelCount, capacity: maxFrameCount)
    }

    func process(input: PlanarBuffer, output: PlanarBuffer, frameCount: Int) {
        output.copy(from: input, frameCount: frameCount)
        inputScratch.clear(frameCount: frameCount)
        outputScratch.clear(frameCount: frameCount)
        for channel in selectedChannels where channel >= 0 && channel < input.channelCount {
            inputScratch.channel(channel).update(from: input.channel(channel), count: frameCount)
        }
        inner.process(input: inputScratch, output: outputScratch, frameCount: frameCount)
        let processed = inner.isInPlace ? inputScratch : outputScratch
        for channel in selectedChannels where channel >= 0 && channel < output.channelCount {
            output.channel(channel).update(from: processed.channel(channel), count: frameCount)
        }
    }

    func reset() {
        inner.reset()
        inputScratch.clear(frameCount: inputScratch.capacity)
        outputScratch.clear(frameCount: outputScratch.capacity)
    }

    var responseIsApproximate: Bool { inner.responseIsApproximate }

    func responseMagnitude(frequency: Double, sampleRate: Double, channel: Int) -> Double {
        guard selectedChannels.contains(channel) else { return 1 }
        return inner.responseMagnitude(frequency: frequency, sampleRate: sampleRate, channel: channel)
    }
}

internal class FIRNode: RenderNode {
    let isInPlace = false
    let displayName: String
    private let filterLength: Int
    private let maxFrameCount: Int
    private let filter: UnsafeMutablePointer<Float>
    private let history: PlanarBuffer
    private let work: PlanarBuffer
    private let channelCount: Int

    init(filter: [Float], channelCount: Int, maxFrameCount: Int, displayName: String) {
        self.displayName = displayName
        let filterLength = max(1, filter.count)
        let maximumFrameCount = max(1, maxFrameCount)
        self.channelCount = channelCount
        let filterPointer = UnsafeMutablePointer<Float>.allocate(capacity: filterLength)
        filterPointer.initialize(repeating: 0, count: filterLength)
        filter.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                filterPointer.update(from: baseAddress, count: min(filter.count, filterLength))
            }
        }
        self.filterLength = filterLength
        self.maxFrameCount = maximumFrameCount
        self.filter = filterPointer
        self.history = PlanarBuffer(channelCount: channelCount, capacity: max(1, filterLength - 1))
        self.work = PlanarBuffer(channelCount: channelCount, capacity: max(1, filterLength - 1 + maximumFrameCount))
    }

    deinit {
        filter.deinitialize(count: filterLength)
        filter.deallocate()
    }

    func process(input: PlanarBuffer, output: PlanarBuffer, frameCount: Int) {
        guard frameCount > 0 else { return }
        let count = min(frameCount, maxFrameCount)
        if filterLength == 1 {
            var scalar = filter[0]
            withUnsafePointer(to: &scalar) { scalarPointer in
                for channel in 0..<channelCount {
                    vDSP_vsmul(input.channel(channel), 1, scalarPointer, output.channel(channel), 1, vDSP_Length(count))
                }
            }
            return
        }

        let historyLength = filterLength - 1
        for channel in 0..<channelCount {
            let workPointer = work.channel(channel)
            workPointer.update(from: history.channel(channel), count: historyLength)
            workPointer.advanced(by: historyLength).update(from: input.channel(channel), count: count)
            vDSP_conv(
                workPointer,
                1,
                filter.advanced(by: filterLength - 1),
                -1,
                output.channel(channel),
                1,
                vDSP_Length(count),
                vDSP_Length(filterLength)
            )
            history.channel(channel).update(from: workPointer.advanced(by: count), count: historyLength)
        }
    }

    func reset() {
        history.clear(frameCount: history.capacity)
        work.clear(frameCount: work.capacity)
    }

    func responseMagnitude(frequency: Double, sampleRate: Double, channel: Int) -> Double {
        firResponseMagnitude(
            coefficient: { Double(filter[$0]) },
            count: filterLength,
            frequency: frequency,
            sampleRate: sampleRate
        )
    }
}

internal final class MultiFIRNode: RenderNode {
    let isInPlace = false
    let displayName: String
    private let filterLengths: [Int]
    private let maxFrameCount: Int
    private let filters: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let histories: PlanarBuffer
    private let work: PlanarBuffer
    private let channelCount: Int
    private let maxHistoryLength: Int

    init(filters sourceFilters: [[Float]], channelCount: Int, maxFrameCount: Int, displayName: String) {
        self.displayName = displayName
        self.channelCount = channelCount
        let maximumFrameCount = max(1, maxFrameCount)
        let lengths = (0..<channelCount).map { max(1, sourceFilters.indices.contains($0) ? sourceFilters[$0].count : 1) }
        let maximumHistoryLength = max(1, (lengths.max() ?? 1) - 1)
        let filterPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        for channel in 0..<channelCount {
            let source = sourceFilters.indices.contains(channel) && !sourceFilters[channel].isEmpty ? sourceFilters[channel] : [Float(1)]
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: lengths[channel])
            pointer.initialize(repeating: 0, count: lengths[channel])
            source.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    pointer.update(from: baseAddress, count: min(source.count, lengths[channel]))
                }
            }
            filterPointers[channel] = pointer
        }
        self.maxFrameCount = maximumFrameCount
        self.filterLengths = lengths
        self.maxHistoryLength = maximumHistoryLength
        self.filters = filterPointers
        self.histories = PlanarBuffer(channelCount: channelCount, capacity: maximumHistoryLength)
        self.work = PlanarBuffer(channelCount: channelCount, capacity: maximumHistoryLength + maximumFrameCount)
    }

    deinit {
        for channel in 0..<channelCount {
            filters[channel].deinitialize(count: filterLengths[channel])
            filters[channel].deallocate()
        }
        filters.deallocate()
    }

    func process(input: PlanarBuffer, output: PlanarBuffer, frameCount: Int) {
        let count = min(frameCount, maxFrameCount)
        guard count > 0 else { return }
        for channel in 0..<channelCount {
            let length = filterLengths[channel]
            if length == 1 {
                var scalar = filters[channel][0]
                withUnsafePointer(to: &scalar) { scalarPointer in
                    vDSP_vsmul(input.channel(channel), 1, scalarPointer, output.channel(channel), 1, vDSP_Length(count))
                }
                continue
            }
            let historyLength = length - 1
            let workPointer = work.channel(channel)
            workPointer.update(from: histories.channel(channel), count: historyLength)
            workPointer.advanced(by: historyLength).update(from: input.channel(channel), count: count)
            vDSP_conv(
                workPointer,
                1,
                filters[channel].advanced(by: length - 1),
                -1,
                output.channel(channel),
                1,
                vDSP_Length(count),
                vDSP_Length(length)
            )
            histories.channel(channel).update(from: workPointer.advanced(by: count), count: historyLength)
        }
    }

    func reset() {
        histories.clear(frameCount: histories.capacity)
        work.clear(frameCount: work.capacity)
    }

    func responseMagnitude(frequency: Double, sampleRate: Double, channel: Int) -> Double {
        guard channel >= 0, channel < channelCount else { return 1 }
        let filterPointer = filters[channel]
        return firResponseMagnitude(
            coefficient: { Double(filterPointer[$0]) },
            count: filterLengths[channel],
            frequency: frequency,
            sampleRate: sampleRate
        )
    }
}

public final class PreparedGraph: @unchecked Sendable {
    public let channelCount: Int
    public let maxFrameCount: Int
    public let sampleRate: Double
    public let nodeNames: [String]
    public let diagnostics: [ConfigurationDiagnostic]

    private var buffers: BufferPair
    private let nodes: [RenderNode]

    internal init(
        channelCount: Int,
        maxFrameCount: Int,
        sampleRate: Double = 48_000,
        nodes: [RenderNode],
        diagnostics: [ConfigurationDiagnostic] = []
    ) {
        self.channelCount = max(1, channelCount)
        self.maxFrameCount = max(1, maxFrameCount)
        self.sampleRate = max(sampleRate, 1.0)
        self.nodes = nodes
        self.nodeNames = nodes.map(\.displayName)
        self.diagnostics = diagnostics
        self.buffers = BufferPair(channelCount: self.channelCount, capacity: self.maxFrameCount)
    }

    public func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let count = min(max(0, frameCount), maxFrameCount)
        guard count > 0 else { return }
        buffers.current.deinterleave(from: input, frameCount: count)
        for node in nodes {
            let current = buffers.current
            let destination = node.isInPlace ? current : buffers.scratch
            node.process(input: current, output: destination, frameCount: count)
            if !node.isInPlace { buffers.swap() }
        }
        buffers.current.interleave(to: output, frameCount: count)
        if frameCount > count {
            output.advanced(by: count * channelCount).update(repeating: 0, count: (frameCount - count) * channelCount)
        }
    }

    public func reset() {
        buffers.first.clear(frameCount: maxFrameCount)
        buffers.second.clear(frameCount: maxFrameCount)
        for node in nodes { node.reset() }
    }

    public var responseIsApproximate: Bool {
        nodes.contains(where: \.responseIsApproximate)
    }

    public func frequencyResponse(
        pointCount: Int = 256,
        lowerFrequency: Double = 20,
        upperFrequency: Double? = nil,
        channel: Int = 0
    ) -> [APOFrequencyResponsePoint] {
        let count = max(2, pointCount)
        let low = max(1.0, lowerFrequency)
        let high = min(upperFrequency ?? 20_000, sampleRate / 2.0)
        guard high > low else { return [] }
        let selectedChannel = min(max(0, channel), channelCount - 1)
        let ratio = high / low
        return (0..<count).map { index in
            let progress = Double(index) / Double(count - 1)
            let frequency = low * pow(ratio, progress)
            var magnitude = 1.0
            for node in nodes {
                magnitude *= max(node.responseMagnitude(frequency: frequency, sampleRate: sampleRate, channel: selectedChannel), 1.0e-15)
            }
            return APOFrequencyResponsePoint(
                frequency: frequency,
                magnitudeDB: 20.0 * log10(max(magnitude, 1.0e-15))
            )
        }
    }
}
