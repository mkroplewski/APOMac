import Foundation

internal struct BiquadCoefficients: Equatable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    var vDSPCoefficients: [Double] {
        [b0, b1, b2, a1, a2]
    }
}

internal enum BiquadKind {
    case lowPass
    case highPass
    case bandPass
    case notch
    case allPass
    case peaking
    case lowShelf
    case highShelf
}

internal enum FilterMath {
    static func coefficients(
        kind: BiquadKind,
        gainDB: Double,
        frequency: Double,
        sampleRate: Double,
        bandwidthOrQOrS: Double,
        isBandwidthOrS: Bool
    ) -> BiquadCoefficients {
        let gainFactor: Double
        switch kind {
        case .peaking, .lowShelf, .highShelf:
            gainFactor = pow(10.0, gainDB / 40.0)
        default:
            gainFactor = pow(10.0, gainDB / 20.0)
        }

        let omega = 2.0 * Double.pi * frequency / sampleRate
        let sine = sin(omega)
        let cosine = cos(omega)
        let alpha: Double
        if !isBandwidthOrS {
            alpha = sine / (2.0 * bandwidthOrQOrS)
        } else if kind == .lowShelf || kind == .highShelf {
            alpha = sine / 2.0 * sqrt((gainFactor + 1.0 / gainFactor) * (1.0 / bandwidthOrQOrS - 1.0) + 2.0)
        } else {
            let safeSine = abs(sine) < 1.0e-12 ? 1.0e-12 : sine
            alpha = sine * sinh(log(2.0) / 2.0 * bandwidthOrQOrS * omega / safeSine)
        }

        let beta = 2.0 * sqrt(gainFactor) * alpha
        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double

        switch kind {
        case .lowPass:
            b0 = (1.0 - cosine) / 2.0
            b1 = 1.0 - cosine
            b2 = b0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosine
            a2 = 1.0 - alpha
        case .highPass:
            b0 = (1.0 + cosine) / 2.0
            b1 = -(1.0 + cosine)
            b2 = b0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosine
            a2 = 1.0 - alpha
        case .bandPass:
            b0 = alpha
            b1 = 0.0
            b2 = -alpha
            a0 = 1.0 + alpha
            a1 = -2.0 * cosine
            a2 = 1.0 - alpha
        case .notch:
            b0 = 1.0
            b1 = -2.0 * cosine
            b2 = 1.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosine
            a2 = 1.0 - alpha
        case .allPass:
            b0 = 1.0 - alpha
            b1 = -2.0 * cosine
            b2 = 1.0 + alpha
            a0 = 1.0 + alpha
            a1 = -2.0 * cosine
            a2 = 1.0 - alpha
        case .peaking:
            b0 = 1.0 + alpha * gainFactor
            b1 = -2.0 * cosine
            b2 = 1.0 - alpha * gainFactor
            a0 = 1.0 + alpha / gainFactor
            a1 = -2.0 * cosine
            a2 = 1.0 - alpha / gainFactor
        case .lowShelf:
            b0 = gainFactor * ((gainFactor + 1.0) - (gainFactor - 1.0) * cosine + beta)
            b1 = 2.0 * gainFactor * ((gainFactor - 1.0) - (gainFactor + 1.0) * cosine)
            b2 = gainFactor * ((gainFactor + 1.0) - (gainFactor - 1.0) * cosine - beta)
            a0 = (gainFactor + 1.0) + (gainFactor - 1.0) * cosine + beta
            a1 = -2.0 * ((gainFactor - 1.0) + (gainFactor + 1.0) * cosine)
            a2 = (gainFactor + 1.0) + (gainFactor - 1.0) * cosine - beta
        case .highShelf:
            b0 = gainFactor * ((gainFactor + 1.0) + (gainFactor - 1.0) * cosine + beta)
            b1 = -2.0 * gainFactor * ((gainFactor - 1.0) + (gainFactor + 1.0) * cosine)
            b2 = gainFactor * ((gainFactor + 1.0) + (gainFactor - 1.0) * cosine - beta)
            a0 = (gainFactor + 1.0) - (gainFactor - 1.0) * cosine + beta
            a1 = 2.0 * ((gainFactor - 1.0) - (gainFactor + 1.0) * cosine)
            a2 = (gainFactor + 1.0) - (gainFactor - 1.0) * cosine - beta
        }

        return BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }

    static func adjustedCornerFrequency(
        frequency: Double,
        gainDB: Double,
        bandwidthOrQOrS: Double,
        isBandwidthOrS: Bool,
        kind: BiquadKind
    ) -> Double {
        guard kind == .lowShelf || kind == .highShelf else { return frequency }
        var slope = bandwidthOrQOrS
        if !isBandwidthOrS {
            let gainFactor = pow(10.0, gainDB / 40.0)
            slope = 1.0 / ((1.0 / (slope * slope) - 2.0) / (gainFactor + 1.0 / gainFactor) + 1.0)
        }
        let centerFrequencyFactor = pow(10.0, abs(gainDB) / 80.0 / slope)
        return kind == .lowShelf ? frequency * centerFrequencyFactor : frequency / centerFrequencyFactor
    }
}
