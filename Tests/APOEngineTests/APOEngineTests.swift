import AVFoundation
import Foundation
import XCTest
@testable import APOEngine

final class APOEngineTests: XCTestCase {
    func testConfigurationParserPreservesSourceAndDecodesLegacyText() throws {
        let url = temporaryURL("config.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "# comment\r\nPreamp: -3 dB\r\nFilter: ON HP Fc 80 Hz\r\n"
        try source.data(using: .windowsCP1252)!.write(to: url)

        let document = try ConfigurationParser.read(url: url)
        XCTAssertEqual(document.lines.count, 4)
        XCTAssertEqual(document.lines[1].lineNumber, 2)
        XCTAssertEqual(document.lines[1].rawText, "Preamp: -3 dB")
        XCTAssertEqual(document.lines[2].command, "Filter")
        XCTAssertEqual(document.lines[2].value, "ON HP Fc 80 Hz")
    }

    func testCompilerBuildsSupportedPostMixGraph() async throws {
        let directory = try makeProfile("""
        Preamp: -6 dB
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1
        Delay: 2 samples
        Copy: L=L+0.5*R R=0.0
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let environment = testEnvironment()
        let result = await DefaultAPOCompiler().compile(profileRoot: directory, environment: environment)
        guard case .success(let graph) = result else {
            XCTFail("Expected graph, got \(result)")
            return
        }
        XCTAssertEqual(graph.channelCount, 2)
        XCTAssertEqual(graph.nodeNames.count, 4)
        let response = graph.frequencyResponse(pointCount: 32)
        XCTAssertEqual(response.count, 32)
        XCTAssertTrue(response.allSatisfy { $0.frequency.isFinite && $0.magnitudeDB.isFinite })

        let input: [Float] = [1, 2, 3, 4, 5, 6]
        var output = Array(repeating: Float.zero, count: input.count)
        input.withUnsafeBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                graph.process(input: inputPointer.baseAddress!, output: outputPointer.baseAddress!, frameCount: 3)
            }
        }
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertNotEqual(output, input)
    }

    func testFrequencyResponseShowsPeakingFilterShape() async throws {
        let directory = try makeProfile("Filter: ON PK Fc 1000 Hz Gain 6 dB Q 1\n")
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .success(let graph) = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment()) else {
            XCTFail("Expected graph")
            return
        }
        let response = graph.frequencyResponse(pointCount: 128)
        let magnitudes = response.map(\.magnitudeDB)
        XCTAssertGreaterThan((magnitudes.max() ?? 0) - (magnitudes.min() ?? 0), 3)
        XCTAssertTrue(magnitudes.allSatisfy(\.isFinite))
    }

    func testConditionalDeviceAndUnsupportedStageDiagnostics() async throws {
        let directory = try makeProfile("""
        Device: Definitely not this device
        Preamp: 6 dB
        Device: Test Output
        Stage: pre-mix
        Preamp: 2 dB
        Stage: post-mix
        If: sampleRate == 48000 and outputChannelCount == 2
        Preamp: -1 dB
        Else:
        Preamp: -99 dB
        EndIf:
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment())
        guard case .success(let graph) = result else {
            XCTFail("Expected graph despite warnings")
            return
        }
        XCTAssertEqual(graph.nodeNames.count, 1)
        XCTAssertTrue(graph.nodeNames[0].contains("Preamp"))
        XCTAssertTrue(graph.diagnostics.contains { $0.code == "unsupported-stage" })
    }

    func testEvalInlineExpressionAndGraphicEQ() async throws {
        let directory = try makeProfile("""
        Eval: linGain = 0.5
        Filter: ON PEQ Fc 1000 Hz Gain `20*log10(linGain)` dB BW Oct 0.167
        GraphicEQ: 100 3; 1000 0; 10000 -3
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment())
        guard case .success(let graph) = result else {
            XCTFail("Expected expression and GraphicEQ graph")
            return
        }
        XCTAssertEqual(graph.nodeNames.count, 2)
        let input = Array(repeating: Float(0.25), count: 64)
        var output = Array(repeating: Float.zero, count: input.count)
        input.withUnsafeBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                graph.process(input: inputPointer.baseAddress!, output: outputPointer.baseAddress!, frameCount: 32)
            }
        }
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func testIncludeCycleIsAnErrorAndDoesNotProduceGraph() async throws {
        let directory = try makeProfile("Include: a.txt\n")
        try "Include: b.txt\n".data(using: .utf8)!.write(to: directory.appendingPathComponent("a.txt"))
        try "Include: a.txt\n".data(using: .utf8)!.write(to: directory.appendingPathComponent("b.txt"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment())
        guard case .failure(let diagnostics) = result else {
            XCTFail("Expected include-cycle failure")
            return
        }
        XCTAssertTrue(diagnostics.diagnostics.contains { $0.code == "include-cycle" })
    }

    func testDelayAndCopyBoundaries() async throws {
        let directory = try makeProfile("Delay: 2 samples\nCopy: L=R R=0.0\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment())
        guard case .success(let graph) = result else {
            XCTFail("Expected graph")
            return
        }

        let input: [Float] = [1, 10, 2, 20, 3, 30]
        var output = Array(repeating: Float.zero, count: input.count)
        input.withUnsafeBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                graph.process(input: inputPointer.baseAddress!, output: outputPointer.baseAddress!, frameCount: 3)
            }
        }
        XCTAssertEqual(output[0], 0, accuracy: 0.0001)
        XCTAssertEqual(output[1], 0, accuracy: 0.0001)
        XCTAssertEqual(output[2], 0, accuracy: 0.0001)
        XCTAssertEqual(output[3], 0, accuracy: 0.0001)
        XCTAssertEqual(output[4], 10, accuracy: 0.0001)
    }

    func testChannelScopedInPlaceNodesAffectOnlySelectedChannels() async throws {
        let directory = try makeProfile("""
        Channel: L
        Preamp: -20 dB
        Channel: R
        Filter: ON PK Fc 1000 Hz Gain 12 dB Q 1
        Channel: all
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .success(let graph) = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment()) else {
            return XCTFail("Expected graph")
        }
        let output = process(graph, interleaved: Array(repeating: 1, count: 2 * 64), frameCount: 64)
        XCTAssertEqual(output[0], 0.1, accuracy: 0.0001, "Left channel must receive the scoped preamp")
        // A peaking filter has unity gain at DC, so the step response settles near 1 but must differ from the input initially.
        XCTAssertNotEqual(output[1], 1, accuracy: 0.0001, "Right channel must receive the scoped filter")
        let responses = graph.frequencyResponses(pointCount: 64)
        XCTAssertEqual(responses[0].map(\.magnitudeDB).max() ?? 0, -20, accuracy: 0.01)
        XCTAssertEqual(responses[1].map(\.magnitudeDB).max() ?? 0, 12, accuracy: 0.2)
    }

    func testPartitionedConvolutionMatchesDirectConvolutionForIrregularCallbacks() {
        var generator = SystemRandomNumberGenerator()
        for filterLength in [1, 5, 256, 257, 1_000, 4_097] {
            let filter = (0..<filterLength).map { _ in Float.random(in: -1...1, using: &generator) }
            let frameTotal = 3_000
            let input = (0..<frameTotal).map { _ in Float.random(in: -1...1, using: &generator) }
            var expected = [Float](repeating: 0, count: frameTotal)
            for n in 0..<frameTotal {
                var sum: Float = 0
                for k in 0..<min(filterLength, n + 1) { sum += filter[k] * input[n - k] }
                expected[n] = sum
            }

            let convolver = PartitionedConvolver(filter: filter, fft: ConvolutionFFT(blockSize: 256))
            var output = [Float](repeating: 0, count: frameTotal)
            let callbackSizes = [1, 7, 64, 255, 256, 257, 512, 33]
            var offset = 0
            var callback = 0
            input.withUnsafeBufferPointer { inputBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    while offset < frameTotal {
                        let count = min(callbackSizes[callback % callbackSizes.count], frameTotal - offset)
                        convolver.process(input: inputBuffer.baseAddress! + offset, output: outputBuffer.baseAddress! + offset, frameCount: count)
                        offset += count
                        callback += 1
                    }
                }
            }
            let maximumError = zip(output, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(maximumError, 2e-3, "filter length \(filterLength)")
        }
    }

    func testGraphicEQMatchesRequestedCurve() async throws {
        let directory = try makeProfile("GraphicEQ: 20 0; 500 0; 1000 6; 4000 6; 8000 -6; 20000 -6\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .success(let graph) = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment()) else {
            return XCTFail("Expected graph")
        }
        func gain(at frequency: Double) -> Double {
            graph.frequencyResponse(pointCount: 2, lowerFrequency: frequency, upperFrequency: frequency * 1.0001)[0].magnitudeDB
        }
        XCTAssertEqual(gain(at: 100), 0, accuracy: 0.3)
        XCTAssertEqual(gain(at: 2_000), 6, accuracy: 0.3)
        XCTAssertEqual(gain(at: 12_000), -6, accuracy: 0.3)

        // The response above is computed from the taps; check the actual audio
        // path too by measuring a steady 2 kHz sine.
        let frames = 48_000
        let sine = (0..<frames).map { Float(sin(2 * Double.pi * 2_000 * Double($0) / 48_000)) }
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames { interleaved[frame * 2] = sine[frame]; interleaved[frame * 2 + 1] = sine[frame] }
        let output = process(graph, interleaved: interleaved, frameCount: frames, callbackSize: 512)
        let tail = stride(from: frames / 2, to: frames, by: 1).map { output[$0 * 2] }
        let peak = tail.map(abs).max() ?? 0
        XCTAssertEqual(20 * log10(Double(peak)), 6, accuracy: 0.3)
    }

    func testConvolutionLoadsAndResamplesImpulseResponse() async throws {
        let directory = try makeProfile("Convolution: ir\\impulse.wav\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let irDirectory = directory.appendingPathComponent("ir", isDirectory: true)
        try FileManager.default.createDirectory(at: irDirectory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        buffer.frameLength = 64
        buffer.floatChannelData![0][0] = 0.5
        do {
            // The writer finalizes the WAV header when it is released.
            let file = try AVAudioFile(forWriting: irDirectory.appendingPathComponent("impulse.wav"), settings: format.settings)
            try file.write(from: buffer)
        }

        let result = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment())
        guard case .success(let graph) = result else { return XCTFail("Expected graph, got \(result)") }
        XCTAssertTrue(graph.diagnostics.contains { $0.code == "convolution-rate" })
        XCTAssertTrue(graph.nodeNames.contains("Convolution impulse.wav"))
        let response = graph.frequencyResponse(pointCount: 8, upperFrequency: 10_000)
        for point in response { XCTAssertEqual(point.magnitudeDB, -6.02, accuracy: 0.5) }
    }

    func testWindowsIncludePathsAreMappedIntoTheProfile() async throws {
        let directory = try makeProfile("Include: C:\\Program Files\\EqualizerAPO\\config\\sub\\eq.txt\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sub = directory.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "Preamp: -4 dB\n".write(to: sub.appendingPathComponent("eq.txt"), atomically: true, encoding: .utf8)

        guard case .success(let graph) = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment()) else {
            return XCTFail("Expected graph")
        }
        XCTAssertEqual(graph.nodeNames.count, 1)
        XCTAssertTrue(graph.diagnostics.contains { $0.code == "windows-path" })
    }

    func testCompileFromUnsavedSourceResolvesIncludesNextToProfile() async throws {
        let directory = try makeProfile("")
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Preamp: -2 dB\n".write(to: directory.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        let result = await DefaultAPOCompiler().compile(
            source: "Include: extra.txt\nPreamp: -1 dB\n",
            sourceURL: directory.appendingPathComponent("config.txt"),
            environment: testEnvironment()
        )
        guard case .success(let graph) = result else { return XCTFail("Expected graph") }
        XCTAssertEqual(graph.nodeNames.count, 2)
    }

    func testInlineExpressionErrorsInterpolateTheMessage() async throws {
        let directory = try makeProfile("Preamp: `1 +`\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .failure(let diagnostics) = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment()) else {
            return XCTFail("Expected failure")
        }
        XCTAssertFalse(diagnostics.diagnostics[0].message.contains("(error"))
    }

    func testDeviceSelectorMatchesWordsAndAlternatives() {
        XCTAssertTrue(DeviceSelector.matches("hd 650", deviceName: "Sennheiser HD 650", deviceUID: "usb-1"))
        XCTAssertTrue(DeviceSelector.matches("AirPods; HD 650", deviceName: "Sennheiser HD 650", deviceUID: "usb-1"))
        XCTAssertTrue(DeviceSelector.matches("usb-1", deviceName: "Sennheiser HD 650", deviceUID: "usb-1"))
        XCTAssertTrue(DeviceSelector.matches("all", deviceName: "Anything", deviceUID: ""))
        XCTAssertFalse(DeviceSelector.matches("HD 600", deviceName: "Sennheiser HD 650", deviceUID: "usb-1"))
    }

    func testDeviceLineInsideInactiveBranchIsIgnored() async throws {
        let directory = try makeProfile("""
        If: 1 == 2
        Device: Some Other Device
        EndIf:
        Preamp: -3 dB
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .success(let graph) = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment()) else {
            return XCTFail("Expected graph")
        }
        XCTAssertEqual(graph.nodeNames.count, 1)
    }

    func testConfigurationDecodingHandlesBOMsAndLegacyEncodings() {
        XCTAssertEqual(ConfigurationParser.decode(Data([0xEF, 0xBB, 0xBF]) + Data("Preamp: 1 dB".utf8)), "Preamp: 1 dB")
        XCTAssertEqual(ConfigurationParser.decode("# Kopfhörer".data(using: .windowsCP1252)!), "# Kopfhörer")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("Preamp: 2 dB".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(ConfigurationParser.decode(utf16), "Preamp: 2 dB")
    }

    func testGraphProcessesCallbacksLargerThanMaxFrameCount() async throws {
        let directory = try makeProfile("Preamp: -6.0206 dB\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .success(let graph) = await DefaultAPOCompiler().compile(profileRoot: directory, environment: testEnvironment()) else {
            return XCTFail("Expected graph")
        }
        let frames = graph.maxFrameCount * 3 + 17
        let output = process(graph, interleaved: Array(repeating: 1, count: frames * 2), frameCount: frames, callbackSize: frames)
        XCTAssertTrue(output.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    private func testEnvironment() -> APOEnvironment {
        APOEnvironment(
            sampleRate: 48_000,
            inputChannelCount: 2,
            outputChannelCount: 2,
            deviceName: "Test Output",
            connectionName: "Core Audio output",
            deviceUID: "test.uid",
            channelNames: ["L", "R"],
            maxFrameCount: 256
        )
    }

    private func process(_ graph: PreparedGraph, interleaved input: [Float], frameCount: Int, callbackSize: Int = 64) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        let channels = graph.channelCount
        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                var offset = 0
                while offset < frameCount {
                    let count = min(callbackSize, frameCount - offset)
                    graph.process(input: inputBuffer.baseAddress! + offset * channels, output: outputBuffer.baseAddress! + offset * channels, frameCount: count)
                    offset += count
                }
            }
        }
        return output
    }

    private func makeProfile(_ configuration: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APOMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try configuration.data(using: .utf8)!.write(to: directory.appendingPathComponent("config.txt"))
        return directory
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("APOMacTests-\(UUID().uuidString)-\(name)")
    }
}
