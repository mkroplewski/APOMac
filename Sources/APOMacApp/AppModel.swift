import APOAudioRuntime
import APOEngine
import AppKit
import Combine
import Foundation

enum EngineStatus: Equatable {
    case off
    case running(AudioOutputFormat)
    case failed(message: String, permissionProblem: Bool)
}

@MainActor
final class AppModel: ObservableObject {
    // Library
    @Published private(set) var profiles: [ManagedProfile] = [] {
        didSet { refreshDeviceRules() }
    }
    @Published private(set) var selectedProfileID: UUID?
    /// Each profile's output device, from its leading `Device:` line.
    @Published private(set) var deviceRules: [UUID: ProfileDeviceRule] = [:]

    // Output
    @Published private(set) var devices: [AudioDeviceInfo] = []
    /// The macOS sound output. Apps play to it, so it is always the device
    /// APOMac taps and processes.
    @Published private(set) var defaultDeviceUID: String?
    @Published private(set) var isEnabled: Bool
    @Published var isBypassed = false {
        didSet { if isBypassed != oldValue { installCurrentGraph() } }
    }
    @Published private(set) var engineStatus: EngineStatus = .off
    /// Separate from the model so its once-a-second updates redraw only the
    /// load label, not the whole window and the menu bar item.
    let loadMeter = LoadMeter()

    // Current profile
    @Published private(set) var configurationText = ""
    @Published private(set) var diagnostics: [ConfigurationDiagnostic] = []
    @Published private(set) var nodeNames: [String] = []
    @Published private(set) var responses: [[APOFrequencyResponsePoint]] = []
    @Published private(set) var responseChannelNames: [String] = []
    @Published private(set) var visualFilters: [EditableFilter] = []
    @Published private(set) var visualEditorAvailable = true
    @Published private(set) var visualEditorMessage: String?
    @Published var selectedFilterID: UUID?
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var isCompiling = false
    @Published var alertMessage: String?

    weak var undoManager: UndoManager?
    /// The DSP load is only shown in the window; don't publish it otherwise.
    var isWindowVisible = false {
        didSet { if isWindowVisible { refreshLoad() } }
    }

    let store: ProfileStore
    private let compiler = DefaultAPOCompiler()
    private let audioSession = AudioSession()
    private let defaults: UserDefaults
    private let startsAudio: Bool
    private var currentGraph: PreparedGraph?
    private var compileGeneration = 0
    private var appliedGeneration = 0
    private var debounceTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var deviceObserver: AnyObject?
    private var timers: Set<AnyCancellable> = []
    private var libraryWatcher: FileWatcher?
    private var profileWatchers: [FileWatcher] = []
    private var supportingFilesSignature: Date?
    /// The output profiles were last chosen for; selections are remembered
    /// against it.
    private var followedOutput: (name: String, uid: String)?

    private enum Keys {
        static let profile = "selectedProfileName"
        static let legacyProfileID = "selectedProfileID"
        static let enabled = "isEnabled"
        /// Output device UID → the profile last used with it.
        static let profileByOutput = "profileByOutput"
    }

    /// `startsAudio: false` keeps the model away from Core Audio (tests, previews).
    init(store: ProfileStore = ProfileStore(), defaults: UserDefaults = .standard, startsAudio: Bool = true) {
        self.store = store
        self.defaults = defaults
        self.startsAudio = startsAudio
        // Earlier builds stored a separate device choice that had no effect.
        defaults.removeObject(forKey: "deviceSelection")
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true

        refreshDevices()
        profiles = store.list()
        refreshDeviceRules() // Property observers don't run in init.
        var savedName = defaults.string(forKey: Keys.profile)
        if savedName == nil, let legacyID = defaults.string(forKey: Keys.legacyProfileID) {
            savedName = store.migratedProfileNames[legacyID.uppercased()]
        }
        defaults.removeObject(forKey: Keys.legacyProfileID)
        let saved = savedName.flatMap { name in profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        followedOutput = outputDevice.map { ($0.name, $0.uid) }
        let forOutput = followedOutput.flatMap { preferredProfile(forOutputNamed: $0.name, uid: $0.uid, current: saved) }
        if let profile = forOutput ?? saved ?? profiles.first {
            load(profile)
        }
        libraryWatcher = FileWatcher(url: store.profilesDirectory) { [weak self] in
            self?.libraryChanged()
        }

        audioSession.onDeviceChange = { [weak self] in
            Task { @MainActor in self?.scheduleRestart() }
        }
        deviceObserver = AudioDeviceCatalog.observeChanges { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
        Timer.publish(every: 1, tolerance: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshLoad() }
            .store(in: &timers)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.flushSave()
                self?.audioSession.stop()
            }
            .store(in: &timers)

        if selectedProfile != nil { startAudio() }
    }

    var selectedProfile: ManagedProfile? { profiles.first { $0.id == selectedProfileID } }

    /// The macOS sound output.
    var outputDevice: AudioDeviceInfo? { devices.first { $0.uid == defaultDeviceUID } }

    /// Switches the macOS output; processing follows via the default-device
    /// notification.
    func selectOutputDevice(_ uid: String) {
        guard uid != defaultDeviceUID else { return }
        do {
            try AudioDeviceCatalog.setDefaultOutputDevice(uid: uid)
            devicesChanged()
        } catch {
            alertMessage = "Could not switch the output device: \(error.localizedDescription)"
        }
    }

    /// Highest gain of the compiled response across channels.
    var peakGainDB: Double? {
        responses.flatMap { $0.map(\.magnitudeDB) }.max()
    }

    func deviceRule(for profile: ManagedProfile) -> ProfileDeviceRule {
        deviceRules[profile.id] ?? .anyDevice
    }

    /// False when the selected profile is for another output device: the
    /// current output then plays unprocessed.
    var selectedProfileApplies: Bool {
        guard let profile = selectedProfile, let output = outputDevice else { return true }
        return applies(profile, toOutputNamed: output.name, uid: output.uid)
    }

    /// A connected device the profile's `Device:` line matches.
    func connectedDevice(for profile: ManagedProfile) -> AudioDeviceInfo? {
        guard case .device(let value) = deviceRule(for: profile) else { return nil }
        return devices.first { DeviceSelector.matches(value, deviceName: $0.name, deviceUID: $0.uid) }
    }

    var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }

    // MARK: Profiles

    func selectProfile(_ id: UUID?) {
        guard id != selectedProfileID else { return }
        flushSave()
        guard let id, let profile = profiles.first(where: { $0.id == id }) else { return }
        load(profile)
        if isEnabled && engineStatus == .off { startAudio() } else { scheduleCompile() }
    }

    func createProfile() {
        perform {
            let profile = try store.create()
            refreshProfiles(select: profile)
        }
    }

    func importItems(_ urls: [URL]) {
        perform {
            var last: ManagedProfile?
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                last = isDirectory ? try store.importDirectory(url) : try store.importFile(url)
            }
            if let last { refreshProfiles(select: last) }
        }
    }

    func duplicate(_ profile: ManagedProfile) {
        flushSave()
        perform { refreshProfiles(select: try store.duplicate(profile)) }
    }

    func rename(_ profile: ManagedProfile, to name: String) {
        if profile.id == selectedProfileID { flushSave() }
        perform {
            let renamed = try store.rename(profile, to: name)
            profileByOutput = profileByOutput.mapValues { $0.caseInsensitiveCompare(profile.name) == .orderedSame ? renamed.name : $0 }
            profiles = store.list()
            if profile.id == selectedProfileID {
                // The folder moved: follow it without reloading the document.
                selectedProfileID = renamed.id
                defaults.set(renamed.name, forKey: Keys.profile)
                watchSelectedProfile()
            }
        }
    }

    /// Limits the profile to one output device with a leading `Device:`
    /// line, or removes the line (nil) so it applies to any device.
    func setOutputDevice(_ deviceName: String?, for profile: ManagedProfile) {
        if profile.id == selectedProfileID {
            guard let text = FilterEditorParser.settingDevice(deviceName, in: configurationText), text != configurationText else { return }
            applyVisualEdit(text, actionName: "Change Output Device", registerUndo: true, requireVisualEditor: false)
            return
        }
        perform {
            guard let text = FilterEditorParser.settingDevice(deviceName, in: try store.readConfiguration(profile)) else { return }
            try store.writeConfiguration(text, for: profile)
            deviceRules[profile.id] = FilterEditorParser.deviceRule(in: text)
        }
    }

    /// Selects the profile for the given output: one whose `Device:` line
    /// matches it, otherwise one without a device. With neither, the
    /// selection stays and the output plays unprocessed.
    func selectProfile(forOutputNamed name: String, uid: String) {
        followedOutput = (name, uid)
        refreshDeviceRules()
        if let profile = preferredProfile(forOutputNamed: name, uid: uid, current: selectedProfile) {
            selectProfile(profile.id)
        }
    }

    func revealProfilesFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.profilesDirectory])
    }

    func delete(_ profile: ManagedProfile) {
        perform {
            if profile.id == selectedProfileID {
                saveTask?.cancel()
                hasUnsavedChanges = false
            }
            try store.delete(profile)
            profiles = store.list()
            if profile.id == selectedProfileID {
                selectedProfileID = nil
                if let next = profileForOutput() ?? profiles.first {
                    selectProfile(next.id)
                } else {
                    clearDocument()
                    stopAudio(status: .off)
                }
            }
        }
    }

    func export(_ profile: ManagedProfile) {
        flushSave()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the “\(profile.name)” profile folder."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform {
            let exported = try store.export(profile, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([exported])
        }
    }

    func revealInFinder(_ profile: ManagedProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.configurationURL])
    }

    // MARK: Editing

    /// Source edits from the text editor: compile shortly after typing stops.
    func setSourceText(_ text: String) {
        guard text != configurationText else { return }
        setText(text)
        scheduleCompile(after: .milliseconds(250))
    }

    /// Applies a visual edit immediately.
    func updateFilter(_ filter: EditableFilter, registerUndo: Bool = true) {
        guard visualEditorAvailable, let lineIndex = filter.lineIndex else { return }
        var lines = FilterEditorParser.normalizedLines(configurationText)
        guard lines.indices.contains(lineIndex) else { return }
        let replacement = FilterEditorFormatter.line(for: filter)
        guard lines[lineIndex] != replacement else { return }
        lines[lineIndex] = replacement
        applyVisualEdit(lines.joined(separator: "\n"), actionName: "Edit Filter", registerUndo: registerUndo)
    }

    func addFilter(_ kind: VisualFilterKind, frequency: Double? = nil, gainDB: Double? = nil) {
        guard visualEditorAvailable else { return }
        var filter = EditableFilter(kind: kind, frequency: frequency ?? defaultFrequency(for: kind), gainDB: gainDB ?? 0)
        if kind == .preamp { filter.gainDB = -3 }
        var lines = FilterEditorParser.normalizedLines(configurationText)
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        if lines == [""] { lines = [] }
        if kind == .preamp {
            lines.insert(FilterEditorFormatter.line(for: filter), at: FilterEditorParser.preambleEnd(lines))
        } else {
            lines.append(FilterEditorFormatter.line(for: filter))
        }
        let addedLine = kind == .preamp ? nil : lines.count - 1
        applyVisualEdit(lines.joined(separator: "\n") + "\n", actionName: "Add Filter", registerUndo: true)
        if let addedLine {
            selectedFilterID = visualFilters.first { $0.lineIndex == addedLine }?.id
        } else {
            selectedFilterID = visualFilters.first { $0.kind == .preamp }?.id
        }
    }

    func deleteFilter(_ filter: EditableFilter) {
        guard visualEditorAvailable, let lineIndex = filter.lineIndex else { return }
        var lines = FilterEditorParser.normalizedLines(configurationText)
        guard lines.indices.contains(lineIndex) else { return }
        lines.remove(at: lineIndex)
        let position = visualFilters.firstIndex { $0.id == filter.id } ?? 0
        applyVisualEdit(lines.joined(separator: "\n"), actionName: "Delete Filter", registerUndo: true)
        if visualFilters.isEmpty {
            selectedFilterID = nil
        } else {
            selectedFilterID = visualFilters[min(position, visualFilters.count - 1)].id
        }
    }

    /// Sets (or inserts) a preamp that cancels the current positive peak.
    func applyHeadroomPreamp() {
        guard let peak = peakGainDB, peak > 0.05 else { return }
        let correction = -(peak * 10).rounded(.up) / 10
        if visualEditorAvailable, var preamp = visualFilters.first(where: { $0.kind == .preamp }) {
            preamp.gainDB += correction
            updateFilter(preamp)
            return
        }
        var lines = FilterEditorParser.normalizedLines(configurationText)
        lines.insert("Preamp: \(FilterEditorFormatter.decimal(correction, maximumFractionDigits: 1)) dB", at: FilterEditorParser.preambleEnd(lines))
        applyVisualEdit(lines.joined(separator: "\n"), actionName: "Add Preamp", registerUndo: true, requireVisualEditor: false)
    }

    // MARK: Audio

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Keys.enabled)
        if enabled { startAudio() } else { stopAudio(status: .off) }
    }

    func retryAudio() {
        if !isEnabled { setEnabled(true) } else { restartAudio() }
    }

    func openAudioCapturePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Private: document

    private func load(_ profile: ManagedProfile) {
        selectedProfileID = profile.id
        defaults.set(profile.name, forKey: Keys.profile)
        do {
            configurationText = try store.readConfiguration(profile)
        } catch {
            configurationText = ""
            alertMessage = "Could not read \(profile.name): \(error.localizedDescription)"
        }
        hasUnsavedChanges = false
        selectedFilterID = nil
        // Last known-good is per profile: never keep showing or playing the
        // previous profile while this one compiles (or if it fails to).
        currentGraph = nil
        responses = []
        nodeNames = []
        diagnostics = []
        refreshVisualEditor()
        undoManager?.removeAllActions()
        watchSelectedProfile()
        if let output = followedOutput, applies(profile, toOutputNamed: output.name, uid: output.uid) {
            profileByOutput[output.uid] = profile.name
        }
    }

    /// Watches the open profile's folder (atomic saves, included files) and
    /// its config.txt (editors that write in place).
    private func watchSelectedProfile() {
        profileWatchers = []
        guard let profile = selectedProfile else { return }
        supportingFilesSignature = store.supportingFilesSignature(for: profile)
        for url in [profile.directory, profile.configurationURL] {
            if let watcher = FileWatcher(url: url, handler: { [weak self] in self?.profileFilesChanged() }) {
                profileWatchers.append(watcher)
            }
        }
    }

    /// Picks up edits made outside APOMac, e.g. in a text editor.
    private func profileFilesChanged() {
        guard let profile = selectedProfile else { return }
        // An atomic save replaces config.txt, which ends the file watcher.
        defer { watchSelectedProfile() }
        guard !hasUnsavedChanges, let text = try? store.readConfiguration(profile) else { return }
        let signature = store.supportingFilesSignature(for: profile)
        if text != configurationText {
            configurationText = text
            refreshVisualEditor()
            scheduleCompile()
        } else if signature != supportingFilesSignature {
            scheduleCompile()
        }
    }

    /// Profiles added, removed or renamed in ~/APOMac outside the app.
    private func libraryChanged() {
        let updated = store.list()
        guard updated != profiles else { return }
        let previousIDs = Set(profiles.map(\.id))
        profiles = updated
        guard let selectedProfileID, !profiles.contains(where: { $0.id == selectedProfileID }) else { return }
        // The open profile's folder was renamed in Finder: exactly one folder
        // disappeared and one appeared. Follow it.
        let added = profiles.filter { !previousIDs.contains($0.id) }
        if added.count == 1, previousIDs.count == profiles.count {
            self.selectedProfileID = added[0].id
            defaults.set(added[0].name, forKey: Keys.profile)
            watchSelectedProfile()
            return
        }
        // The open profile's folder is gone.
        saveTask?.cancel()
        hasUnsavedChanges = false
        self.selectedProfileID = nil
        if let next = profileForOutput() ?? profiles.first {
            selectProfile(next.id)
        } else {
            clearDocument()
            profileWatchers = []
            stopAudio(status: .off)
        }
    }

    private func clearDocument() {
        configurationText = ""
        diagnostics = []
        nodeNames = []
        responses = []
        visualFilters = []
        currentGraph = nil
        hasUnsavedChanges = false
    }

    private func refreshProfiles(select profile: ManagedProfile) {
        profiles = store.list()
        selectProfile(profile.id)
    }

    private func setText(_ text: String) {
        configurationText = text
        hasUnsavedChanges = true
        refreshVisualEditor()
        scheduleSave()
    }

    private func applyVisualEdit(_ text: String, actionName: String, registerUndo: Bool, requireVisualEditor: Bool = true) {
        guard !requireVisualEditor || visualEditorAvailable else { return }
        let previous = configurationText
        if registerUndo, let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                model.applyVisualEdit(previous, actionName: actionName, registerUndo: true, requireVisualEditor: false)
            }
            undoManager.setActionName(actionName)
        }
        setText(text)
        scheduleCompile()
    }

    private func refreshVisualEditor() {
        let result = FilterEditorParser.parse(configurationText).reusingIdentifiers(from: visualFilters)
        visualFilters = result.filters
        visualEditorAvailable = result.isEditable
        visualEditorMessage = result.message
        if let selectedProfileID {
            let rule = FilterEditorParser.deviceRule(in: configurationText)
            if deviceRules[selectedProfileID] != rule { deviceRules[selectedProfileID] = rule }
        }
        if let selectedFilterID, !visualFilters.contains(where: { $0.id == selectedFilterID }) {
            self.selectedFilterID = nil
        }
    }

    // MARK: Private: output devices

    private var profileByOutput: [String: String] {
        get { defaults.dictionary(forKey: Keys.profileByOutput) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.profileByOutput) }
    }

    private func applies(_ profile: ManagedProfile, toOutputNamed name: String, uid: String) -> Bool {
        guard case .device(let value) = deviceRule(for: profile) else { return true }
        return DeviceSelector.matches(value, deviceName: name, deviceUID: uid)
    }

    /// Profiles for this device win over profiles for any device. Among
    /// several, keep the current one, else the one last used with the
    /// device, else the last selected one, else the first.
    func preferredProfile(forOutputNamed name: String, uid: String, current: ManagedProfile?) -> ManagedProfile? {
        let forDevice = profiles.filter {
            if case .device = deviceRule(for: $0) { return applies($0, toOutputNamed: name, uid: uid) }
            return false
        }
        let candidates = forDevice.isEmpty ? profiles.filter { if case .device = deviceRule(for: $0) { false } else { true } } : forDevice
        if let current, candidates.contains(current) { return current }
        for remembered in [profileByOutput[uid], defaults.string(forKey: Keys.profile)].compactMap({ $0 }) {
            if let profile = candidates.first(where: { $0.name.caseInsensitiveCompare(remembered) == .orderedSame }) {
                return profile
            }
        }
        return candidates.first
    }

    private func profileForOutput() -> ManagedProfile? {
        followedOutput.flatMap { preferredProfile(forOutputNamed: $0.name, uid: $0.uid, current: nil) }
    }

    /// Reads every profile's `Device:` line; the open one from the editor.
    private func refreshDeviceRules() {
        var rules: [UUID: ProfileDeviceRule] = [:]
        for profile in profiles {
            let text = profile.id == selectedProfileID ? configurationText : (try? store.readConfiguration(profile)) ?? ""
            rules[profile.id] = FilterEditorParser.deviceRule(in: text)
        }
        if rules != deviceRules { deviceRules = rules }
    }

    private func defaultFrequency(for kind: VisualFilterKind) -> Double {
        switch kind {
        case .lowShelf: return 105
        case .highShelf: return 8_000
        case .highPass: return 30
        case .lowPass: return 16_000
        default: return 1_000
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        guard hasUnsavedChanges, let profile = selectedProfile else { return }
        do {
            try store.writeConfiguration(configurationText, for: profile)
            hasUnsavedChanges = false
        } catch {
            alertMessage = "Could not save \(profile.name): \(error.localizedDescription)"
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { alertMessage = error.localizedDescription }
    }

    // MARK: Private: compile and install

    private func makeEnvironment() -> APOEnvironment {
        var environment: APOEnvironment
        if case .running(let format) = engineStatus {
            environment = APOEnvironment(
                sampleRate: format.sampleRate,
                inputChannelCount: format.channelCount,
                outputChannelCount: format.channelCount,
                deviceName: format.deviceName,
                deviceUID: format.deviceUID,
                maxFrameCount: 4_096
            )
        } else {
            let device = outputDevice ?? devices.first
            environment = APOEnvironment(
                sampleRate: device?.sampleRate ?? 48_000,
                inputChannelCount: max(1, device?.outputChannelCount ?? 2),
                outputChannelCount: max(1, device?.outputChannelCount ?? 2),
                deviceName: device?.name ?? "Output",
                deviceUID: device?.uid ?? "",
                maxFrameCount: 4_096
            )
        }
        // A profile for another device is shown as it sounds on that device;
        // installCurrentGraph keeps it off this one.
        if let profile = selectedProfile, case .device(let value) = deviceRule(for: profile),
           !applies(profile, toOutputNamed: environment.deviceName, uid: environment.deviceUID) {
            environment = APOEnvironment(
                sampleRate: environment.sampleRate,
                inputChannelCount: environment.inputChannelCount,
                outputChannelCount: environment.outputChannelCount,
                deviceName: value,
                maxFrameCount: environment.maxFrameCount
            )
        }
        return environment
    }

    private func scheduleCompile(after delay: Duration = .zero) {
        debounceTask?.cancel()
        guard let profile = selectedProfile else { return }
        compileGeneration += 1
        let generation = compileGeneration
        let text = configurationText
        let sourceURL = profile.configurationURL
        let environment = makeEnvironment()
        let compiler = self.compiler

        debounceTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            self?.isCompiling = true
            let outcome = await Task.detached(priority: .userInitiated) {
                let result = await compiler.compile(source: text, sourceURL: sourceURL, environment: environment)
                let responses = (try? result.get())?.frequencyResponses(pointCount: 320)
                return (result, responses)
            }.value
            self?.finishCompile(outcome.0, responses: outcome.1, generation: generation, environment: environment)
        }
    }

    private func finishCompile(
        _ result: Result<PreparedGraph, ConfigurationDiagnostics>,
        responses: [[APOFrequencyResponsePoint]]?,
        generation: Int,
        environment: APOEnvironment
    ) {
        if generation == compileGeneration { isCompiling = false }
        // Results can arrive out of order; never let an older one win.
        guard generation > appliedGeneration else { return }
        appliedGeneration = generation
        switch result {
        case .success(let graph):
            currentGraph = graph
            diagnostics = graph.diagnostics
            nodeNames = graph.nodeNames
            self.responses = responses ?? []
            responseChannelNames = environment.channelNames
            installCurrentGraph()
        case .failure(let errors):
            diagnostics = errors.diagnostics
            if currentGraph == nil {
                // Nothing valid yet for this profile: play unprocessed audio.
                installCurrentGraph()
            }
        }
    }

    private func installCurrentGraph() {
        guard case .running(let format) = engineStatus else { return }
        let applies = selectedProfile.map { self.applies($0, toOutputNamed: format.deviceName, uid: format.deviceUID) } ?? true
        if isBypassed || currentGraph == nil || !applies {
            audioSession.install(graph: .passthrough(channelCount: format.channelCount, maxFrameCount: 4_096, sampleRate: format.sampleRate))
        } else if let currentGraph, !audioSession.install(graph: currentGraph) {
            // Compiled for a previous device format; compile again.
            scheduleCompile()
        }
    }

    private func startAudio() {
        guard startsAudio, isEnabled, selectedProfile != nil else {
            scheduleCompile()
            return
        }
        do {
            let format = try audioSession.start(deviceUID: nil)
            engineStatus = .running(format)
        } catch {
            let permission = (error as? AudioSessionError)?.isLikelyPermissionDenied ?? false
            engineStatus = .failed(message: error.localizedDescription, permissionProblem: permission)
        }
        scheduleCompile()
    }

    private func stopAudio(status: EngineStatus) {
        audioSession.stop()
        engineStatus = status
        loadMeter.dspLoad = nil
    }

    private func restartAudio() {
        restartTask?.cancel()
        guard isEnabled else { return }
        stopAudio(status: .off)
        startAudio()
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.restartAudio()
        }
    }

    private func refreshDevices() {
        devices = AudioDeviceCatalog.outputDevices()
        defaultDeviceUID = AudioDeviceCatalog.defaultOutputDeviceUID()
    }

    private func devicesChanged() {
        let previousDefault = defaultDeviceUID
        let previousDevices = Set(devices.map(\.uid))
        refreshDevices()
        let deviceSetChanged = previousDevices != Set(devices.map(\.uid)) || previousDefault != defaultDeviceUID
        if previousDefault != defaultDeviceUID, let output = outputDevice {
            selectProfile(forOutputNamed: output.name, uid: output.uid)
        }
        guard isEnabled else { return }
        switch engineStatus {
        case .running(let format):
            if let defaultDeviceUID, format.deviceUID != defaultDeviceUID {
                scheduleRestart()
            }
        case .failed:
            if deviceSetChanged { scheduleRestart() }
        case .off:
            break
        }
    }

    private func refreshLoad() {
        guard isWindowVisible, case .running = engineStatus else { return }
        // Publish only when the displayed whole percentage changes: every
        // publish re-renders the window and the menu bar item.
        let load = (audioSession.dspLoad * 100).rounded() / 100
        if load != loadMeter.dspLoad { loadMeter.dspLoad = load }
    }
}

@MainActor
final class LoadMeter: ObservableObject {
    /// Fraction of the audio cycle spent processing; nil when not running.
    @Published var dspLoad: Double?
}
