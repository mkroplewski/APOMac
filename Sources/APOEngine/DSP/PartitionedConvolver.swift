import Accelerate
import Foundation

/// Shared FFT resources for the partitioned convolvers of one node.
internal final class ConvolutionFFT {
    let blockSize: Int
    let fftSize: Int
    let log2n: vDSP_Length
    let setup: FFTSetup

    init(blockSize: Int) {
        self.blockSize = blockSize
        self.fftSize = blockSize * 2
        self.log2n = vDSP_Length(log2(Double(blockSize * 2)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Unable to create vDSP FFT setup")
        }
        self.setup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }
}

/// Zero-latency FIR convolution for one channel.
///
/// The first `blockSize` taps (the head) are convolved directly per sample
/// segment. The remaining taps (the tail) use uniformly partitioned
/// overlap-save FFT convolution. Because every tail tap is delayed by at least
/// one block, the tail output for block k+1 can be computed as soon as input
/// block k is complete, so arbitrary callback sizes cost no added latency.
/// All memory is allocated up front; `process` never allocates.
internal final class PartitionedConvolver {
    private let fft: ConvolutionFFT
    private let blockSize: Int
    private let halfSize: Int
    private let headLength: Int
    private let partitionCount: Int

    private let headTaps: UnsafeMutablePointer<Float>
    private let headWork: UnsafeMutablePointer<Float>

    // Frequency-domain filter partitions and input delay line, packed real FFT format.
    private let filterReal: UnsafeMutablePointer<Float>
    private let filterImaginary: UnsafeMutablePointer<Float>
    private let delayReal: UnsafeMutablePointer<Float>
    private let delayImaginary: UnsafeMutablePointer<Float>
    private let accumulatorReal: UnsafeMutablePointer<Float>
    private let accumulatorImaginary: UnsafeMutablePointer<Float>
    private let timeBuffer: UnsafeMutablePointer<Float>
    private let previousInput: UnsafeMutablePointer<Float>
    private let inputBlock: UnsafeMutablePointer<Float>
    private let tailOutput: UnsafeMutablePointer<Float>
    private var delayPosition = 0
    private var fill = 0

    init(filter: [Float], fft: ConvolutionFFT) {
        self.fft = fft
        blockSize = fft.blockSize
        halfSize = fft.blockSize
        let taps = filter.isEmpty ? [Float(1)] : filter
        self.headLength = min(taps.count, blockSize)
        partitionCount = taps.count > blockSize ? (taps.count - blockSize + blockSize - 1) / blockSize : 0

        let headLength = min(taps.count, blockSize)
        let head = UnsafeMutablePointer<Float>.allocate(capacity: headLength)
        taps.withUnsafeBufferPointer { head.initialize(from: $0.baseAddress!, count: headLength) }
        headTaps = head
        headWork = .allocate(capacity: headLength - 1 + blockSize)
        headWork.initialize(repeating: 0, count: headLength - 1 + blockSize)

        let spectrumCount = max(1, partitionCount) * halfSize
        filterReal = .allocate(capacity: spectrumCount)
        filterImaginary = .allocate(capacity: spectrumCount)
        delayReal = .allocate(capacity: spectrumCount)
        delayImaginary = .allocate(capacity: spectrumCount)
        for pointer in [filterReal, filterImaginary, delayReal, delayImaginary] {
            pointer.initialize(repeating: 0, count: spectrumCount)
        }
        accumulatorReal = .allocate(capacity: halfSize)
        accumulatorImaginary = .allocate(capacity: halfSize)
        accumulatorReal.initialize(repeating: 0, count: halfSize)
        accumulatorImaginary.initialize(repeating: 0, count: halfSize)
        timeBuffer = .allocate(capacity: fft.fftSize)
        timeBuffer.initialize(repeating: 0, count: fft.fftSize)
        previousInput = .allocate(capacity: blockSize)
        previousInput.initialize(repeating: 0, count: blockSize)
        inputBlock = .allocate(capacity: blockSize)
        inputBlock.initialize(repeating: 0, count: blockSize)
        tailOutput = .allocate(capacity: blockSize)
        tailOutput.initialize(repeating: 0, count: blockSize)

        // vDSP's real forward FFT scales by 2 and the inverse by N, so a
        // forward*forward*inverse round trip is 4N; fold that into the filter.
        var scale = Float(1.0 / Double(4 * fft.fftSize))
        for partition in 0..<partitionCount {
            timeBuffer.update(repeating: 0, count: fft.fftSize)
            let start = blockSize + partition * blockSize
            let count = min(blockSize, taps.count - start)
            taps.withUnsafeBufferPointer { timeBuffer.update(from: $0.baseAddress! + start, count: count) }
            vDSP_vsmul(timeBuffer, 1, &scale, timeBuffer, 1, vDSP_Length(fft.fftSize))
            var split = DSPSplitComplex(realp: filterReal + partition * halfSize, imagp: filterImaginary + partition * halfSize)
            forward(timeBuffer, into: &split)
        }
        timeBuffer.update(repeating: 0, count: fft.fftSize)
    }

    deinit {
        for (pointer, count) in [
            (headTaps, headLength), (headWork, headLength - 1 + blockSize),
            (filterReal, max(1, partitionCount) * halfSize), (filterImaginary, max(1, partitionCount) * halfSize),
            (delayReal, max(1, partitionCount) * halfSize), (delayImaginary, max(1, partitionCount) * halfSize),
            (accumulatorReal, halfSize), (accumulatorImaginary, halfSize),
            (timeBuffer, fft.fftSize), (previousInput, blockSize), (inputBlock, blockSize), (tailOutput, blockSize)
        ] {
            pointer.deinitialize(count: count)
            pointer.deallocate()
        }
    }

    func reset() {
        let spectrumCount = max(1, partitionCount) * halfSize
        delayReal.update(repeating: 0, count: spectrumCount)
        delayImaginary.update(repeating: 0, count: spectrumCount)
        headWork.update(repeating: 0, count: headLength - 1 + blockSize)
        timeBuffer.update(repeating: 0, count: fft.fftSize)
        previousInput.update(repeating: 0, count: blockSize)
        inputBlock.update(repeating: 0, count: blockSize)
        tailOutput.update(repeating: 0, count: blockSize)
        delayPosition = 0
        fill = 0
    }

    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let segment = min(frameCount - offset, blockSize - fill)
            processSegment(input: input + offset, output: output + offset, count: segment)
            offset += segment
        }
    }

    private func processSegment(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, count: Int) {
        let history = headLength - 1
        // Head: direct convolution over [last `history` inputs, segment].
        (headWork + history).update(from: input, count: count)
        vDSP_conv(headWork, 1, headTaps + history, -1, output, 1, vDSP_Length(count), vDSP_Length(headLength))
        if history > 0 {
            headWork.update(from: headWork + count, count: history)
        }

        guard partitionCount > 0 else { return }
        vDSP_vadd(output, 1, tailOutput + fill, 1, output, 1, vDSP_Length(count))
        (inputBlock + fill).update(from: input, count: count)
        fill += count
        if fill == blockSize {
            computeNextTailBlock()
            fill = 0
        }
    }

    private func computeNextTailBlock() {
        // Overlap-save window: [previous block, current block].
        timeBuffer.update(from: previousInput, count: blockSize)
        (timeBuffer + blockSize).update(from: inputBlock, count: blockSize)
        previousInput.update(from: inputBlock, count: blockSize)

        delayPosition = (delayPosition + 1) % partitionCount
        var newest = DSPSplitComplex(realp: delayReal + delayPosition * halfSize, imagp: delayImaginary + delayPosition * halfSize)
        forward(timeBuffer, into: &newest)

        accumulatorReal.update(repeating: 0, count: halfSize)
        accumulatorImaginary.update(repeating: 0, count: halfSize)
        var accumulator = DSPSplitComplex(realp: accumulatorReal, imagp: accumulatorImaginary)
        // Element 0 holds DC (real) and Nyquist (imaginary) in packed format;
        // both are real-valued and must be multiplied separately.
        var dc: Float = 0
        var nyquist: Float = 0
        for partition in 0..<partitionCount {
            let slot = (delayPosition - partition + partitionCount) % partitionCount
            var spectrum = DSPSplitComplex(realp: delayReal + slot * halfSize, imagp: delayImaginary + slot * halfSize)
            var filter = DSPSplitComplex(realp: filterReal + partition * halfSize, imagp: filterImaginary + partition * halfSize)
            dc += spectrum.realp[0] * filter.realp[0]
            nyquist += spectrum.imagp[0] * filter.imagp[0]
            vDSP_zvma(&spectrum, 1, &filter, 1, &accumulator, 1, &accumulator, 1, vDSP_Length(halfSize))
        }
        accumulatorReal[0] = dc
        accumulatorImaginary[0] = nyquist

        vDSP_fft_zrip(fft.setup, &accumulator, 1, fft.log2n, FFTDirection(kFFTDirection_Inverse))
        timeBuffer.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complex in
            vDSP_ztoc(&accumulator, 1, complex, 2, vDSP_Length(halfSize))
        }
        // The valid overlap-save output is the second half of the window.
        tailOutput.update(from: timeBuffer + blockSize, count: blockSize)
    }

    /// Forward real FFT of `source` (fftSize samples) into `destination` (packed split format).
    private func forward(_ source: UnsafeMutablePointer<Float>, into destination: inout DSPSplitComplex) {
        source.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complex in
            vDSP_ctoz(complex, 2, &destination, 1, vDSP_Length(halfSize))
        }
        vDSP_fft_zrip(fft.setup, &destination, 1, fft.log2n, FFTDirection(kFFTDirection_Forward))
    }
}
