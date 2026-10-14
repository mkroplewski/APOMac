import APOAudioRuntime
import APOEngine
import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [ManagedProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var devices: [AudioDeviceInfo] = []
    @Published var selectedDeviceUID = ""
    @Published var configurationText = ""
    @Published var diagnostics: [ConfigurationDiagnostic] = []
    @Published var nodeNames: [String] = []
    @Published var selectedNodeName: String?
    @Published var visualFilters: [EditableFilter] = []
    @Published var visualEditorAvailable = true
    @Published var visualEditorMessage: String?
    @Published var selectedFilterID: UUID?
    @Published var response: [APOFrequencyResponsePoint] = []
    @Published var responseIsApproximate = false
    @Published var responseIsPreview = false
    @Published var isConfigurationDirty = false
    @Published var isCompiling = false
    @Published var isBypassed = false
    @Published var statusMessage = "Stopped"

    let store: ProfileStore
    let compiler = DefaultAPOCompiler()
    let audioSession = AudioSession()
    private var previewTask: Task<Void, Never>?

    init(store: ProfileStore = ProfileStore()) {
        self.store = store
        refreshProfiles()
        devices = AudioDeviceCatalog.outputDevices()
        selectedDeviceUID = devices.first?.uid ?? ""
        if let first = profiles.first {
            selectedProfileID = first.id
            configurationText = store.readConfiguration(first)
            refreshVisualEditor()
        }
    }

    var selectedProfile: ManagedProfile? { profiles.first { $0.id == selectedProfileID } }
    var selectedDevice: AudioDeviceInfo? { devices.first { $0.uid == selectedDeviceUID } }

    func refreshProfiles() {
        profiles = store.list()
    }

    func importProfile(from url: URL) {
        do {
            let profile = try store.importDirectory(url)
            refreshProfiles()
            selectedProfileID = profile.id
            setConfigurationText(store.readConfiguration(profile), dirty: false)
            Task { await reload() }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportSelectedProfile() {
        guard let profile = selectedProfile else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = profile.name
        panel.message = "Choose a folder to receive the portable profile directory."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try store.export(profile, to: destination)
            statusMessage = "Exported \(profile.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
        if let profile = selectedProfile { setConfigurationText(store.readConfiguration(profile), dirty: false) }
        Task { await reload() }
    }

    func updateConfigurationText(_ text: String) {
        setConfigurationText(text, dirty: true)
        schedulePreview()
    }

    func createProfile() {
        do {
            let profile = try store.create()
            refreshProfiles()
            selectedProfileID = profile.id
            setConfigurationText(store.readConfiguration(profile), dirty: false)
            statusMessage = "Created (profile.name)"
            Task { await reload() }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameSelectedProfile(to name: String) {
        guard let profile = selectedProfile else { return }
        do {
            _ = try store.rename(profile, to: name)
            refreshProfiles()
            selectedProfileID = profile.id
            statusMessage = "Renamed profile"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteSelectedProfile() {
        guard let profile = selectedProfile else { return }
        do {
            audioSession.stop()
            try store.delete(profile)
            refreshProfiles()
            if let next = profiles.first {
                selectedProfileID = next.id
                setConfigurationText(store.readConfiguration(next), dirty: false)
                statusMessage = "Deleted (profile.name)"
                Task { await reload() }
            } else {
                selectedProfileID = nil
                setConfigurationText("", dirty: false)
                statusMessage = "No profile selected"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addFilter(_ filter: EditableFilter) {
        guard visualEditorAvailable else { return }
        var updated = configurationText
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated.append("\n") }
        updated.append(FilterEditorFormatter.line(for: filter))
        updated.append("\n")
        updateConfigurationText(updated)
        selectedFilterID = visualFilters.last?.id
        statusMessage = "Applying filter…"
        Task { await saveAndReload() }
    }

    func updateFilter(_ filter: EditableFilter) {
        guard visualEditorAvailable, let lineIndex = filter.lineIndex else { return }
        replaceConfigurationLine(at: lineIndex, with: FilterEditorFormatter.line(for: filter))
        selectedFilterID = visualFilters.first(where: { $0.lineIndex == lineIndex })?.id
        statusMessage = "Applying filter…"
        Task { await saveAndReload() }
    }

    func deleteFilter(_ filter: EditableFilter) {
        guard visualEditorAvailable, let lineIndex = filter.lineIndex else { return }
        var lines = normalizedLines(configurationText)
        guard lines.indices.contains(lineIndex) else { return }
        lines.remove(at: lineIndex)
        updateConfigurationText(lines.joined(separator: "\n"))
        selectedFilterID = visualFilters.first?.id
        statusMessage = "Applying filter…"
        Task { await saveAndReload() }
    }

    func reload() async {
        guard let profile = selectedProfile, let device = selectedDevice else {
            diagnostics = []
            nodeNames = []
            selectedNodeName = nil
            response = []
            responseIsApproximate = false
            responseIsPreview = false
            return
        }
        isCompiling = true
        let environment = makeEnvironment(for: device)
        let result = await compiler.compile(profileRoot: profile.directory, environment: environment)
        switch result {
        case .success(let graph):
            diagnostics = graph.diagnostics
            nodeNames = graph.nodeNames
            if let selectedNodeName, graph.nodeNames.contains(selectedNodeName) {
                self.selectedNodeName = selectedNodeName
            } else {
                selectedNodeName = graph.nodeNames.first
            }
            response = graph.frequencyResponse(channel: 0)
            responseIsApproximate = graph.responseIsApproximate
            responseIsPreview = false
            _ = audioSession.install(graph: graph)
            if audioSession.state == .stopped {
                do {
                    try audioSession.start(graph: graph, deviceUID: device.uid)
                    statusMessage = "Running"
                    isBypassed = false
                } catch {
                    statusMessage = error.localizedDescription
                    isBypassed = true
                }
            }
        case .failure(let errors):
            diagnostics = errors.diagnostics
            statusMessage = "Last known-good graph retained"
        }
        isCompiling = false
    }

    func saveAndReload() async {
        guard let profile = selectedProfile else { return }
        previewTask?.cancel()
        do {
            try store.writeConfiguration(configurationText, for: profile)
            isConfigurationDirty = false
            await reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func toggleBypass() {
        isBypassed.toggle()
        if isBypassed {
            audioSession.stop()
            statusMessage = "Bypassed"
        } else {
            Task { await reload() }
        }
    }

    func stop() {
        audioSession.stop()
        statusMessage = "Stopped"
    }

    private func setConfigurationText(_ text: String, dirty: Bool) {
        configurationText = text
        isConfigurationDirty = dirty
        if !dirty {
            previewTask?.cancel()
            responseIsPreview = false
        }
        refreshVisualEditor()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard isConfigurationDirty, visualEditorAvailable, let device = selectedDevice else { return }
        let source = configurationText
        let environment = makeEnvironment(for: device)
        let compiler = self.compiler
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("APOMac-Preview-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                try Data(source.utf8).write(to: temporaryRoot.appendingPathComponent("config.txt"), options: .atomic)
                let result = await compiler.compile(profileRoot: temporaryRoot, environment: environment)
                try? FileManager.default.removeItem(at: temporaryRoot)
                guard !Task.isCancelled, let self else { return }
                switch result {
                case .success(let graph):
                    self.response = graph.frequencyResponse(channel: 0)
                    self.responseIsApproximate = graph.responseIsApproximate
                    self.responseIsPreview = true
                    self.diagnostics = graph.diagnostics
                    self.statusMessage = "Preview ready — Apply & Reload to activate"
                case .failure(let diagnostics):
                    self.diagnostics = diagnostics.diagnostics
                    self.statusMessage = "Preview has errors — active graph retained"
                }
            } catch {
                try? FileManager.default.removeItem(at: temporaryRoot)
            }
        }
    }

    private func makeEnvironment(for device: AudioDeviceInfo) -> APOEnvironment {
        APOEnvironment(
            sampleRate: device.sampleRate,
            inputChannelCount: max(1, device.outputChannelCount),
            outputChannelCount: max(1, device.outputChannelCount),
            deviceName: device.name,
            connectionName: "Core Audio output",
            deviceUID: device.uid,
            channelNames: ChannelLayout.defaultNames(for: device.outputChannelCount),
            stage: .postMix,
            maxFrameCount: max(256, 4096)
        )
    }

    private func refreshVisualEditor() {
        let result = FilterEditorParser.parse(configurationText)
        visualFilters = result.filters
        visualEditorAvailable = result.isEditable
        visualEditorMessage = result.message
        if let selectedFilterID, visualFilters.contains(where: { $0.id == selectedFilterID }) {
            self.selectedFilterID = selectedFilterID
        } else {
            self.selectedFilterID = visualFilters.first?.id
        }
    }

    private func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private func replaceConfigurationLine(at lineIndex: Int, with replacement: String) {
        var lines = normalizedLines(configurationText)
        guard lines.indices.contains(lineIndex) else { return }
        lines[lineIndex] = replacement
        updateConfigurationText(lines.joined(separator: "\n"))
    }
}
