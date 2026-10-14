import XCTest
@testable import APOMacApp
@testable import APOAudioRuntime
import APOEngine

final class ProfileStoreTests: XCTestCase {
    func testProfileStoreImportsAndExportsCompleteDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("APOMacStore-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("export", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("Preamp: -3 dB\n".utf8).write(to: source.appendingPathComponent("config.txt"))
        try Data([0, 1, 2, 3]).write(to: source.appendingPathComponent("impulse.bin"))
        defer { try? fileManager.removeItem(at: root) }

        let store = ProfileStore(
            fileManager: fileManager,
            profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true)
        )
        let imported = try store.importDirectory(source, name: "Fixture")
        try store.export(imported, to: destination)
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("Fixture/config.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("Fixture/impulse.bin").path))
    }

    func testProfileLifecycleUsesManagedDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("APOMacLifecycle-\(UUID().uuidString)", isDirectory: true)
        let store = ProfileStore(
            fileManager: fileManager,
            profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true)
        )
        defer { try? fileManager.removeItem(at: root) }

        let created = try store.create(name: "Studio")
        XCTAssertEqual(store.list().map(\.name), ["Studio"])
        let renamed = try store.rename(created, to: "Living Room")
        XCTAssertEqual(renamed.name, "Living Room")
        XCTAssertEqual(store.list().map(\.name), ["Living Room"])
        try store.delete(renamed)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testVisualFilterEditorParsesAndFormatsSimpleProfiles() {
        let result = FilterEditorParser.parse("""
        # simple profile
        Preamp: -3 dB
        Filter: ON PK Fc 1000 Hz Gain 4 dB Q 0.7
        Delay: 12 ms
        """)

        XCTAssertTrue(result.isEditable)
        XCTAssertEqual(result.filters.map(\.kind), [.preamp, .peaking, .delay])
        XCTAssertEqual(result.filters[1].frequency, 1_000, accuracy: 0.001)
        XCTAssertEqual(result.filters[1].gainDB, 4, accuracy: 0.001)
        XCTAssertEqual(FilterEditorFormatter.line(for: result.filters[1]), "Filter: ON PK Fc 1000 Hz Gain 4 dB Q 0.7")

        let complex = FilterEditorParser.parse("Include: filters.txt\n")
        XCTAssertFalse(complex.isEditable)
    }

    func testGraphCrossfaderStartsOnFirstGraphAndCompletesCosineTransition() async throws {
        let fileManager = FileManager.default
        let firstDirectory = fileManager.temporaryDirectory.appendingPathComponent("APOMacGraph-\(UUID().uuidString)", isDirectory: true)
        let secondDirectory = fileManager.temporaryDirectory.appendingPathComponent("APOMacGraph-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try Data("Preamp: 0 dB\n".utf8).write(to: firstDirectory.appendingPathComponent("config.txt"))
        try Data("Preamp: 6 dB\n".utf8).write(to: secondDirectory.appendingPathComponent("config.txt"))
        defer {
            try? fileManager.removeItem(at: firstDirectory)
            try? fileManager.removeItem(at: secondDirectory)
        }

        let environment = APOEnvironment(sampleRate: 48_000, inputChannelCount: 2, outputChannelCount: 2, deviceName: "Test", channelNames: ["L", "R"], maxFrameCount: 256)
        let compiler = DefaultAPOCompiler()
        guard case .success(let first) = await compiler.compile(profileRoot: firstDirectory, environment: environment),
              case .success(let second) = await compiler.compile(profileRoot: secondDirectory, environment: environment) else {
            XCTFail("Expected both graphs")
            return
        }
        let crossfader = GraphCrossfader(sampleRate: 48_000, channelCount: 2, maxFrameCount: 256)
        XCTAssertTrue(crossfader.install(first))
        let input = Array(repeating: Float(1), count: 2 * 256)
        var output = Array(repeating: Float.zero, count: input.count)
        input.withUnsafeBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                crossfader.process(input: inputPointer.baseAddress!, output: outputPointer.baseAddress!, frameCount: 1)
            }
        }
        XCTAssertEqual(output[0], 1, accuracy: 0.0001)
        XCTAssertTrue(crossfader.install(second))
        for _ in 0..<20 {
            input.withUnsafeBufferPointer { inputPointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    crossfader.process(input: inputPointer.baseAddress!, output: outputPointer.baseAddress!, frameCount: 256)
                }
            }
        }
        XCTAssertEqual(output[0], powf(10, 0.3), accuracy: 0.01)
    }
}
