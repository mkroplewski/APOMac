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

    func testLegacyEncodedProfilesAreReadIntactAndImportFileWorks() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("APOMacEncoding-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let text = "# Kopfhörer\nPreamp: -3 dB\n"
        try text.data(using: .windowsCP1252)!.write(to: source.appendingPathComponent("config.txt"))
        let store = ProfileStore(fileManager: fileManager, profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))

        let imported = try store.importDirectory(source, name: "Legacy")
        XCTAssertEqual(try store.readConfiguration(imported), text)

        let autoEQ = root.appendingPathComponent("Headphones ParametricEQ.txt")
        try "Preamp: -6.2 dB\nFilter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70\n".write(to: autoEQ, atomically: true, encoding: .utf8)
        let single = try store.importFile(autoEQ)
        XCTAssertEqual(single.name, "Headphones ParametricEQ")
        XCTAssertTrue(try store.readConfiguration(single).contains("LSC"))
    }

    func testExportCreatesMissingDestinationAndNeverOverwrites() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("APOMacExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let store = ProfileStore(fileManager: fileManager, profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
        let profile = try store.create(name: "Studio")
        let destination = root.appendingPathComponent("does/not/exist", isDirectory: true)

        let first = try store.export(profile, to: destination)
        let second = try store.export(profile, to: destination)
        XCTAssertEqual(first.lastPathComponent, "Studio")
        XCTAssertEqual(second.lastPathComponent, "Studio 2")
        XCTAssertTrue(fileManager.fileExists(atPath: first.appendingPathComponent("config.txt").path))
    }

    func testProfilesCanBeManagedWhenTheStoreFolderDiffersOnlyInCase() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("APOMacCase-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root.appendingPathComponent("ApoMac/Profiles"), withIntermediateDirectories: true)
        // The volume is case-insensitive: this names the same folder.
        let store = ProfileStore(fileManager: fileManager, profilesDirectory: root.appendingPathComponent("APOMac/Profiles", isDirectory: true))
        _ = try store.create(name: "Old")

        let listed = try XCTUnwrap(store.list().first)
        XCTAssertTrue(listed.directory.path.contains("/ApoMac/"), "list() returns the on-disk casing")
        let renamed = try store.rename(listed, to: "Renamed")
        XCTAssertNoThrow(try store.duplicate(renamed))
        try store.delete(renamed)
        XCTAssertEqual(store.list().map(\.name), ["Renamed Copy"])

        let outside = ManagedProfile(id: listed.id, name: "x", directory: root.appendingPathComponent(listed.id.uuidString, isDirectory: true))
        XCTAssertThrowsError(try store.delete(outside))
    }

    func testLegacyProfilesMigrateToReadableFoldersAndKeepTheSelection() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("APOMacMigrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Application Support/APOMac/Profiles", isDirectory: true)
        let oldID = UUID()
        let oldFolder = legacy.appendingPathComponent(oldID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try "Preamp: -2 dB\n".write(to: oldFolder.appendingPathComponent("config.txt"), atomically: true, encoding: .utf8)
        try #"{"name":"HD 650"}"#.write(to: oldFolder.appendingPathComponent("profile.json"), atomically: true, encoding: .utf8)

        let store = ProfileStore(fileManager: fileManager, profilesDirectory: root.appendingPathComponent("APOMac", isDirectory: true), legacyProfilesDirectory: legacy)
        XCTAssertEqual(store.list().map(\.name), ["HD 650"])
        XCTAssertEqual(try store.readConfiguration(store.list()[0]), "Preamp: -2 dB\n")
        XCTAssertFalse(fileManager.fileExists(atPath: store.list()[0].directory.appendingPathComponent("profile.json").path))
        XCTAssertEqual(store.migratedProfileNames[oldID.uuidString], "HD 650")
        XCTAssertFalse(fileManager.fileExists(atPath: legacy.deletingLastPathComponent().path), "Empty legacy folders are removed")
    }

    func testRenamingChangesTheFolderIncludingCaseOnlyChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("APOMacRename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(profilesDirectory: root)
        let profile = try store.create(name: "studio")
        let renamed = try store.rename(profile, to: "Studio")
        XCTAssertEqual(renamed.directory.lastPathComponent, "Studio")
        XCTAssertEqual(store.list().map(\.name), ["Studio"])
        _ = try store.create(name: "Desk")
        let collision = try store.rename(store.list().first { $0.name == "Desk" }!, to: "Studio")
        XCTAssertEqual(collision.name, "Studio 2", "Never overwrite another profile")
    }

    @MainActor
    func testExternalEditsAndNewFoldersArePickedUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("APOMacWatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(profilesDirectory: root)
        let profile = try store.create(name: "Desk")
        try store.writeConfiguration("Filter: ON PK Fc 1000 Hz Gain 3 dB Q 1\n", for: profile)
        let defaults = UserDefaults(suiteName: "APOMacWatch-\(UUID().uuidString)")!
        let model = AppModel(store: store, defaults: defaults, startsAudio: false)
        try await waitUntil { (model.peakGainDB ?? 0) > 2.9 }

        // An editor saving atomically (write to a temp file, rename over).
        try "Filter: ON PK Fc 1000 Hz Gain 8 dB Q 1\n".write(to: profile.configurationURL, atomically: true, encoding: .utf8)
        try await waitUntil { (model.peakGainDB ?? 0) > 7.9 }
        // An editor writing in place.
        let handle = try FileHandle(forWritingTo: profile.configurationURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("Filter: ON PK Fc 1000 Hz Gain 5 dB Q 1\n".utf8))
        try handle.close()
        try await waitUntil { abs((model.peakGainDB ?? 0) - 5) < 0.1 }

        // A config folder copied in with Finder.
        let added = root.appendingPathComponent("Copied In", isDirectory: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try "Preamp: -1 dB\n".write(to: added.appendingPathComponent("config.txt"), atomically: true, encoding: .utf8)
        try await waitUntil { model.profiles.contains { $0.name == "Copied In" } }

        // The open profile renamed in Finder is followed, not replaced.
        try FileManager.default.moveItem(at: profile.directory, to: root.appendingPathComponent("Desk Renamed", isDirectory: true))
        try await waitUntil { model.selectedProfile?.name == "Desk Renamed" }
        XCTAssertTrue(model.configurationText.contains("Gain 5 dB"))
    }

    func testProfileNamesCannotEscapeTheExportFolder() throws {
        let store = ProfileStore(profilesDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("APOMacNames-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.profilesDirectory) }
        XCTAssertEqual(store.normalizedName(".."), "New Profile")
        XCTAssertEqual(store.normalizedName("../x"), "-x")
        XCTAssertEqual(store.normalizedName(" a/b:c "), "a-b-c")
    }

    func testVisualEditsPreserveLabelsTypeTokensAndComments() {
        let result = FilterEditorParser.parse("""
        Preamp: -6.2 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70 # bass
        Filter 2: ON PK Fc 10789 Hz Gain -3.25 dB Q 2.5
        """)
        XCTAssertTrue(result.isEditable)
        var shelf = result.filters[1]
        shelf.gainDB = 4
        XCTAssertEqual(FilterEditorFormatter.line(for: shelf), "Filter 1: ON LSC Fc 105 Hz Gain 4 dB Q 0.7 # bass")
        var peak = result.filters[2]
        peak.frequency = 12_345.6
        XCTAssertEqual(FilterEditorFormatter.line(for: peak), "Filter 2: ON PK Fc 12345.6 Hz Gain -3.25 dB Q 2.5")
        peak.kind = .highShelf
        XCTAssertTrue(FilterEditorFormatter.line(for: peak).contains(" HSC "))

        XCTAssertFalse(FilterEditorParser.parse("Filter: ON LSC 12 dB Fc 100 Hz Gain 3 dB Q 0.7\n").isEditable)
        XCTAssertFalse(FilterEditorParser.parse("Channel: L\nPreamp: -1 dB\n").isEditable)
    }

    func testUserNumberParsingAcceptsCommasAndSuffixes() {
        XCTAssertEqual(FilterEditorParser.userNumber("2,5"), 2.5)
        XCTAssertEqual(FilterEditorParser.userNumber("1.2k"), 1_200)
        XCTAssertEqual(FilterEditorParser.userNumber("80 Hz"), 80)
        XCTAssertEqual(FilterEditorParser.userNumber("+3 dB"), 3)
        XCTAssertEqual(FilterEditorParser.userNumber("−4"), -4)
        XCTAssertNil(FilterEditorParser.userNumber("abc"))
    }

    func testCrossfaderNewestInstallWinsAndRetiredGraphsAreReleasedOffTheRenderThread() async throws {
        let environment = APOEnvironment(sampleRate: 48_000, inputChannelCount: 2, outputChannelCount: 2, deviceName: "Test", channelNames: ["L", "R"], maxFrameCount: 256)
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("config.txt")
        let compiler = DefaultAPOCompiler()
        var graphs: [PreparedGraph] = []
        for gain in [0, -6.0206, -12.0412] {
            guard case .success(let graph) = await compiler.compile(source: "Preamp: \(gain) dB\n", sourceURL: sourceURL, environment: environment) else {
                return XCTFail("Expected graph")
            }
            graphs.append(graph)
        }
        weak var firstGraph = graphs[0]
        weak var skippedGraph = graphs[1]

        let crossfader = GraphCrossfader(sampleRate: 48_000, channelCount: 2, maxFrameCount: 256)
        let input = Array(repeating: Float(1), count: 2 * 512)
        var output = Array(repeating: Float.zero, count: input.count)
        func render(_ frames: Int) {
            input.withUnsafeBufferPointer { inputPointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    crossfader.process(input: inputPointer.baseAddress!, output: outputPointer.baseAddress!, frameCount: frames)
                }
            }
        }

        // Before any graph: unprocessed pass-through, not silence.
        render(16)
        XCTAssertEqual(output[0], 1, accuracy: 0.0001)

        crossfader.install(graphs[0])
        for _ in 0..<10 { render(512) }
        XCTAssertEqual(output[0], 1, accuracy: 0.0001)

        // Two installs before the render thread picks one up: only the newest plays.
        crossfader.install(graphs[1])
        crossfader.install(graphs[2])
        graphs.removeAll()
        XCTAssertNil(skippedGraph, "A graph replaced in the mailbox is released by install")
        for _ in 0..<10 { render(512) }
        XCTAssertEqual(output[0], 0.25, accuracy: 0.001)

        XCTAssertNotNil(firstGraph, "The render thread must not release graphs itself")
        crossfader.drainTrash()
        XCTAssertNil(firstGraph)
    }

    @MainActor
    func testSwitchingToABrokenProfileDoesNotKeepThePreviousProfilesResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("APOMacModel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(profilesDirectory: root)
        let defaults = UserDefaults(suiteName: "APOMacModel-\(UUID().uuidString)")!
        defaults.set(false, forKey: "isEnabled")
        let good = try store.create(name: "A good")
        try store.writeConfiguration("Filter: ON PK Fc 1000 Hz Gain 6 dB Q 1\n", for: good)
        let broken = try store.create(name: "B broken")
        try store.writeConfiguration("Filter: ON XX Fc 1000 Hz\n", for: broken)

        let model = AppModel(store: store, defaults: defaults)
        model.selectProfile(good.id)
        try await waitUntil { !model.responses.isEmpty }
        XCTAssertEqual(model.peakGainDB ?? 0, 6, accuracy: 0.1)

        model.selectProfile(broken.id)
        try await waitUntil { model.errorCount > 0 }
        XCTAssertTrue(model.responses.isEmpty)
        XCTAssertTrue(model.nodeNames.isEmpty)
    }

    @MainActor
    func testVisualEditsApplyImmediatelyAndAreUndoable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("APOMacUndo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(profilesDirectory: root)
        let defaults = UserDefaults(suiteName: "APOMacUndo-\(UUID().uuidString)")!
        defaults.set(false, forKey: "isEnabled")
        let profile = try store.create(name: "EQ")
        try store.writeConfiguration("Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1\n", for: profile)
        let model = AppModel(store: store, defaults: defaults)
        let undoManager = UndoManager()
        model.undoManager = undoManager
        model.selectProfile(profile.id)

        var filter = model.visualFilters[0]
        filter.gainDB = 9
        model.updateFilter(filter)
        try await waitUntil { (model.peakGainDB ?? 0) > 8.9 }
        XCTAssertEqual(model.configurationText, "Filter 1: ON PK Fc 1000 Hz Gain 9 dB Q 1\n")

        undoManager.undo()
        try await waitUntil { (model.peakGainDB ?? 1) < 0.1 }
        XCTAssertEqual(model.configurationText, "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1\n")
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for condition") }
            try await Task.sleep(for: .milliseconds(20))
        }
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
