import AVFoundation
import Foundation

internal struct LoadedImpulseResponse {
    let sourceSampleRate: Double
    let channels: [[Float]]
    let wasResampled: Bool
}

internal enum ImpulseResponseLoader {
    static func load(url: URL, targetSampleRate: Double) throws -> LoadedImpulseResponse {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sourceFormat = file.processingFormat
        let capacity = AVAudioFrameCount(max(1, file.length))
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: capacity) else {
            throw loaderError(1, "Unable to allocate impulse response buffer")
        }
        try file.read(into: sourceBuffer)

        var buffer = sourceBuffer
        let needsResampling = abs(sourceFormat.sampleRate - targetSampleRate) >= 0.5
        if needsResampling {
            buffer = try resample(sourceBuffer, to: targetSampleRate)
        }

        guard let channelData = buffer.floatChannelData else {
            throw loaderError(2, "Impulse response is not PCM float audio")
        }
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: channelData[channel], count: frames))
        }
        return LoadedImpulseResponse(
            sourceSampleRate: sourceFormat.sampleRate,
            channels: channels.isEmpty || frames == 0 ? [[1]] : channels,
            wasResampled: needsResampling
        )
    }

    private static func resample(_ source: AVAudioPCMBuffer, to sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: source.format.channelCount,
            interleaved: false
        ), let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            throw loaderError(3, "Unable to resample impulse response to \(Int(sampleRate)) Hz")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let ratio = sampleRate / source.format.sampleRate
        // Leave room for the converter's flush tail.
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw loaderError(1, "Unable to allocate impulse response buffer")
        }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error {
            throw conversionError ?? loaderError(3, "Unable to resample impulse response")
        }
        return output
    }

    private static func loaderError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "APOMac", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
