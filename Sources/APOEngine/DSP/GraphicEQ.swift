import Accelerate
import Foundation

internal struct GraphicEQBand: Sendable {
    let frequency: Double
    let gainDB: Double
}

/// Builds the same kind of finite impulse response used by APO's GraphicEQ:
/// logarithmic interpolation followed by minimum-phase reconstruction. The
/// work is deliberately compile-time work; FIRNode only performs vDSP_conv in
/// the audio callback.
internal enum GraphicEQBuilder {
    static func impulseResponse(
        bands: [GraphicEQBand],
        sampleRate: Double,
        filterLength: Int = 16_384
    ) -> [Float] {
        let validBands = bands
            .filter { $0.frequency > 0 && $0.frequency < sampleRate / 2 && $0.gainDB.isFinite }
            .sorted { $0.frequency < $1.frequency }
        guard !validBands.isEmpty else { return [1] }

        let fftSize = max(2, filterLength * 2)
        let log2n = vDSP_Length(Int(log2(Double(fftSize))))
        guard let fft = vDSP.FFT<DSPSplitComplex>(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return [1]
        }

        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = [Float](repeating: 0, count: fftSize)

        func gain(at frequency: Double) -> Double {
            if frequency <= validBands[0].frequency { return validBands[0].gainDB }
            if frequency >= validBands[validBands.count - 1].frequency { return validBands[validBands.count - 1].gainDB }
            for index in 1..<validBands.count where frequency <= validBands[index].frequency {
                let lower = validBands[index - 1]
                let upper = validBands[index]
                let denominator = log10(upper.frequency) - log10(lower.frequency)
                let amount = denominator == 0 ? 0 : (log10(frequency) - log10(lower.frequency)) / denominator
                return lower.gainDB + (upper.gainDB - lower.gainDB) * amount
            }
            return validBands.last?.gainDB ?? 0
        }

        for index in 0..<fftSize {
            let mirroredIndex = index <= fftSize / 2 ? index : fftSize - index
            let frequency = Double(mirroredIndex) * sampleRate / Double(fftSize)
            let amplitude = pow(10.0, gain(at: max(frequency, 1.0)) / 20.0)
            real[index] = Float(amplitude)
        }

        var impulseSpectrumReal = [Float](repeating: 0, count: fftSize)
        var impulseSpectrumImaginary = [Float](repeating: 0, count: fftSize)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                impulseSpectrumReal.withUnsafeMutableBufferPointer { outputRealBuffer in
                    impulseSpectrumImaginary.withUnsafeMutableBufferPointer { outputImaginaryBuffer in
                        guard let realPointer = realBuffer.baseAddress,
                              let imaginaryPointer = imaginaryBuffer.baseAddress,
                              let outputRealPointer = outputRealBuffer.baseAddress,
                              let outputImaginaryPointer = outputImaginaryBuffer.baseAddress else { return }
                        let input = DSPSplitComplex(realp: realPointer, imagp: imaginaryPointer)
                        var output = DSPSplitComplex(realp: outputRealPointer, imagp: outputImaginaryPointer)
                        fft.inverse(input: input, output: &output)
                        var inverseScale = Float(1.0 / Double(fftSize))
                        vDSP_vsmul(outputRealPointer, 1, &inverseScale, outputRealPointer, 1, vDSP_Length(fftSize))
                    }
                }
            }
        }

        var impulse = Array(impulseSpectrumReal.prefix(min(filterLength, impulseSpectrumReal.count)))
        if impulse.isEmpty { impulse = [1] }
        // A gentle truncation window keeps the finite IR from ringing at the
        // cut-off while preserving the first sample and the APO-style shape.
        if impulse.count > 2 {
            for index in impulse.indices {
                let window = 0.5 * (1.0 + cos(Double.pi * Double(index) / Double(impulse.count - 1)))
                impulse[index] *= Float(window)
            }
        }
        return impulse
    }
}
