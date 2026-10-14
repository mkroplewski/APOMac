import Accelerate
import Foundation

internal struct GraphicEQBand: Sendable {
    let frequency: Double
    let gainDB: Double
}

/// Builds the minimum-phase FIR used for GraphicEQ: the band gains are
/// interpolated linearly in dB over log frequency (as Equalizer APO does) and
/// the magnitude response is turned into a minimum-phase impulse response
/// with the real-cepstrum (homomorphic) method. All of this is compile-time
/// work; the render path only runs the partitioned convolution.
internal enum GraphicEQBuilder {
    static func filterLength(for sampleRate: Double) -> Int {
        if sampleRate > 100_000 { return 65_536 }
        if sampleRate > 50_000 { return 32_768 }
        return 16_384
    }

    static func impulseResponse(
        bands: [GraphicEQBand],
        sampleRate: Double,
        filterLength requestedLength: Int? = nil
    ) -> [Float] {
        let validBands = bands
            .filter { $0.frequency > 0 && $0.gainDB.isFinite }
            .sorted { $0.frequency < $1.frequency }
        guard !validBands.isEmpty, sampleRate > 0 else { return [1] }
        if validBands.allSatisfy({ $0.gainDB == validBands[0].gainDB }) {
            return [Float(pow(10.0, validBands[0].gainDB / 20.0))]
        }

        let filterLength = max(64, requestedLength ?? filterLength(for: sampleRate))
        let log2n = vDSP_Length(ceil(log2(Double(filterLength * 4))))
        let size = 1 << Int(log2n)
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return [1] }
        defer { vDSP_destroy_fftsetupD(setup) }

        func gain(at frequency: Double) -> Double {
            if frequency <= validBands[0].frequency { return validBands[0].gainDB }
            if frequency >= validBands[validBands.count - 1].frequency { return validBands[validBands.count - 1].gainDB }
            var upperIndex = 1
            while validBands[upperIndex].frequency < frequency { upperIndex += 1 }
            let lower = validBands[upperIndex - 1]
            let upper = validBands[upperIndex]
            let span = log(upper.frequency) - log(lower.frequency)
            let amount = span == 0 ? 0 : (log(frequency) - log(lower.frequency)) / span
            return lower.gainDB + (upper.gainDB - lower.gainDB) * amount
        }

        var real = [Double](repeating: 0, count: size)
        var imaginary = [Double](repeating: 0, count: size)
        let half = size / 2
        let decibelToNeper = log(10.0) / 20.0
        for bin in 0...half {
            let frequency = Double(bin) * sampleRate / Double(size)
            let logMagnitude = gain(at: max(frequency, 1.0)) * decibelToNeper
            real[bin] = logMagnitude
            if bin > 0 && bin < half { real[size - bin] = logMagnitude }
        }

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPDoubleSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                let inverseScale = 1.0 / Double(size)

                // Real cepstrum of the log magnitude.
                vDSP_fft_zipD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                // Fold the anti-causal part onto the causal part.
                for index in 0..<size {
                    let factor: Double
                    if index == 0 || index == half { factor = 1 }
                    else if index < half { factor = 2 }
                    else { factor = 0 }
                    realBuffer[index] *= factor * inverseScale
                    imaginaryBuffer[index] = 0
                }
                // Back to the (complex) log spectrum, exponentiate, invert.
                vDSP_fft_zipD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                for index in 0..<size {
                    let magnitude = exp(realBuffer[index])
                    let phase = imaginaryBuffer[index]
                    realBuffer[index] = magnitude * cos(phase)
                    imaginaryBuffer[index] = magnitude * sin(phase)
                }
                vDSP_fft_zipD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                var scale = inverseScale
                vDSP_vsmulD(realBuffer.baseAddress!, 1, &scale, realBuffer.baseAddress!, 1, vDSP_Length(size))
            }
        }

        var impulse = real.prefix(filterLength).map(Float.init)
        // A minimum-phase response decays quickly; fade the tail so the
        // truncation does not ring.
        let fadeStart = filterLength * 3 / 4
        let fadeLength = filterLength - fadeStart
        for index in fadeStart..<filterLength {
            let position = Double(index - fadeStart) / Double(fadeLength)
            impulse[index] *= Float(0.5 * (1.0 + cos(Double.pi * position)))
        }
        return impulse
    }
}
