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
