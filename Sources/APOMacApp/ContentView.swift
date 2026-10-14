import APOAudioRuntime
import APOEngine
import SwiftUI
import UniformTypeIdentifiers

enum EditorTab: String, CaseIterable, Identifiable {
    case filters = "Filters"
    case source = "Source"
    var id: Self { self }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @Binding var isImporterPresented: Bool
    @State private var renaming: ManagedProfile?
    @State private var renameText = ""
    @State private var deleting: ManagedProfile?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                model: model,
                onImport: { isImporterPresented = true },
                onRename: { profile in
                    renameText = profile.name
                    renaming = profile
                },
                onDelete: { deleting = $0 }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if model.selectedProfile != nil {
                DetailView(model: model)
            } else {
                ContentUnavailableView {
                    Label("No Profile", systemImage: "slider.vertical.3")
                } description: {
                    Text("Create a profile, or import an Equalizer APO profile folder or an AutoEQ ParametricEQ.txt file.")
                } actions: {
                    Button("New Profile") { model.createProfile() }
                    Button("Import…") { isImporterPresented = true }
                }
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle(model.selectedProfile?.name ?? "APOMac")
        .navigationSubtitle(statusSubtitle)
        .frame(minWidth: 900, minHeight: 600)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder, .plainText, .text], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importItems(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importItems(urls)
            return !urls.isEmpty
        }
        .alert("Rename Profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let renaming { model.rename(renaming, to: renameText) } }
        }
        .confirmationDialog(
            "Move “\(deleting?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { if let deleting { model.delete(deleting) } }
        } message: {
            Text("The profile folder and its files are moved to the Trash.")
        }
        .alert("APOMac", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onAppear {
            model.undoManager = undoManager
            model.isWindowVisible = true
        }
        .onDisappear { model.isWindowVisible = false }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    private var statusSubtitle: String {
        switch model.engineStatus {
        case .off:
            return model.isEnabled ? "Not processing" : "Processing off"
        case .failed:
            return "Not processing"
        case .running(let format):
            let rate = FilterEditorFormatter.decimal(format.sampleRate / 1_000, maximumFractionDigits: 1)
            return "\(format.deviceName) · \(rate) kHz · \(format.channelCount) ch"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            OutputDevicePicker(model: model)
                .pickerStyle(.menu)
                .help("macOS sound output — APOMac processes whatever plays through it")
                .frame(minWidth: 170)

            Toggle(isOn: $model.isBypassed) {
                Label("Bypass", systemImage: model.isBypassed ? "speaker.slash" : "speaker.wave.2")
            }
            .help("Bypass the equalizer to compare with the unprocessed sound (⌘B)")
            .disabled(model.selectedProfile == nil)

            Toggle(isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })) {
                Label("Processing", systemImage: "power")
            }
            .help(model.isEnabled ? "Stop processing system audio" : "Start processing system audio")

            OpenSettingsButton(title: "Settings", systemImage: "gearshape")
                .help("Settings (⌘,)")
        }
    }

}

/// Shows and changes the macOS sound output (shared by the toolbar and menu bar).
struct OutputDevicePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Picker(selection: Binding(get: { model.defaultDeviceUID ?? "" }, set: { model.selectOutputDevice($0) })) {
            ForEach(model.devices) { device in
                Text(device.name).tag(device.uid)
            }
            if model.devices.isEmpty {
                Text("No output devices").tag("")
            }
        } label: {
            Label("Output", systemImage: "hifispeaker")
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var model: AppModel
    let onImport: () -> Void
    let onRename: (ManagedProfile) -> Void
    let onDelete: (ManagedProfile) -> Void

    var body: some View {
        List(selection: Binding(get: { model.selectedProfileID }, set: { model.selectProfile($0) })) {
            Section("Profiles") {
                ForEach(model.profiles) { profile in
                    HStack {
                        Label(profile.name, systemImage: "slider.vertical.3")
                            .lineLimit(1)
                        Spacer()
                        if profile.id == model.selectedProfileID, case .running = model.engineStatus, !model.isBypassed {
                            ActivityBars()
                                .help("Playing through this profile")
                        }
                    }
                    .tag(profile.id)
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let profile = model.profiles.first(where: { $0.id == id }) {
                Button("Rename…") { onRename(profile) }
                Button("Duplicate") { model.duplicate(profile) }
                Button("Export…") { model.export(profile) }
                Button("Show in Finder") { model.revealInFinder(profile) }
                Divider()
                Button("Move to Trash…", role: .destructive) { onDelete(profile) }
            }
        }
        .overlay {
            if model.profiles.isEmpty {
                Text("No profiles yet").foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Menu {
                    Button("New Profile", systemImage: "plus") { model.createProfile() }
                    Button("Import Folder or File…", systemImage: "square.and.arrow.down") { onImport() }
                    Divider()
                    Button("Show Profiles Folder", systemImage: "folder") { model.revealProfilesFolder() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a profile")
                Spacer()
                if let profile = model.selectedProfile {
                    Menu {
                        Button("Rename…") { onRename(profile) }
                        Button("Duplicate") { model.duplicate(profile) }
                        Button("Export…") { model.export(profile) }
                        Button("Show in Finder") { model.revealInFinder(profile) }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { onDelete(profile) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Profile actions")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private struct DetailView: View {
    @ObservedObject var model: AppModel
    @SceneStorage("editorTab") private var tab: EditorTab = .filters
    @State private var revealLine: Int?

    var body: some View {
        VStack(spacing: 0) {
            EngineBanner(model: model)
            VSplitView {
                graphPanel
                    .frame(minHeight: 220, idealHeight: 320)
                editorPanel
                    .frame(minHeight: 200)
            }
        }
    }

    private var graphPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Frequency Response").font(.headline)
                if model.isCompiling {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                DSPLoadLabel(meter: model.loadMeter)
                HeadroomIndicator(model: model)
            }
            ResponseGraphView(
                responses: model.responses,
                channelNames: model.responseChannelNames,
                filters: model.visualFilters,
                selectedFilterID: model.selectedFilterID,
                isBypassed: model.isBypassed,
                isEditable: model.visualEditorAvailable,
                onSelect: { model.selectedFilterID = $0 },
                onDrag: { filter, frequency, gain, isFirst in
                    guard var current = model.visualFilters.first(where: { $0.id == filter.id }) else { return }
                    current.frequency = frequency
                    current.gainDB = gain
                    model.updateFilter(current, registerUndo: isFirst)
                },
                onAdd: { frequency, gain in model.addFilter(.peaking, frequency: frequency, gainDB: gain) }
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var editorPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Editor", selection: $tab) {
                    ForEach(EditorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if tab == .filters && model.visualEditorAvailable {
                    AddFilterMenu(model: model)
                }
                DiagnosticsSummary(model: model) { tab = .source }
                Spacer()
                if model.hasUnsavedChanges {
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .filters:
                FilterListView(model: model) { tab = .source }
            case .source:
                sourcePanel
            }
        }
    }

    private var sourcePanel: some View {
        VStack(spacing: 0) {
            SourceEditor(
                text: model.configurationText,
                onChange: { model.setSourceText($0) },
                errorLines: lines(of: .error),
                warningLines: lines(of: .warning),
                revealLine: $revealLine
            )
            if !model.diagnostics.isEmpty {
                Divider()
                DiagnosticsList(model: model) { revealLine = $0 }
                    .frame(maxHeight: 130)
            }
        }
    }

    private func lines(of severity: DiagnosticSeverity) -> Set<Int> {
        guard let configURL = model.selectedProfile?.configurationURL.standardizedFileURL else { return [] }
        return Set(model.diagnostics.filter { $0.severity == severity && $0.file.standardizedFileURL == configURL }.map(\.line))
    }
}

private struct EngineBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.engineStatus {
        case .failed(let message, let permissionProblem):
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: permissionProblem ? "APOMac needs permission to process system audio" : "System audio is not being processed",
                detail: permissionProblem
                    ? "Allow APOMac under Privacy & Security → Screen & System Audio Recording, then try again."
                    : message
            ) {
                if permissionProblem {
                    Button("Open Settings") { model.openAudioCapturePrivacySettings() }
                }
                Button("Try Again") { model.retryAudio() }
                    .buttonStyle(.borderedProminent)
            }
        case .off where !model.isEnabled && model.selectedProfile != nil:
            banner(icon: "power", tint: .secondary, title: "Processing is off", detail: "Other apps play unprocessed audio.") {
                Button("Turn On") { model.setEnabled(true) }
                    .buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }

    private func banner<Actions: View>(icon: String, tint: Color, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                actions()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(tint.opacity(0.08))
            Divider()
        }
    }
}

private struct DSPLoadLabel: View {
    @ObservedObject var meter: LoadMeter

    var body: some View {
        if let load = meter.dspLoad {
            Text("DSP \(Int((load * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Share of each audio cycle spent processing")
        }
    }
}

private struct HeadroomIndicator: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let peak = model.peakGainDB {
            if peak > 0.05 && !model.isBypassed {
                HStack(spacing: 8) {
                    Label("Peak \(FilterEditorFormatter.signedDecimal(peak, maximumFractionDigits: 1)) dB — may clip", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Add Preamp") { model.applyHeadroomPreamp() }
                        .controlSize(.small)
                        .help("Lower the preamp by \(FilterEditorFormatter.decimal(peak, maximumFractionDigits: 1)) dB so the response peaks at 0 dB")
                }
                .font(.caption)
            } else {
                Label("Peak \(FilterEditorFormatter.signedDecimal(peak, maximumFractionDigits: 1)) dB", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DiagnosticsSummary: View {
    @ObservedObject var model: AppModel
    let showSource: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if model.errorCount > 0 {
                Button(action: showSource) {
                    Label("\(model.errorCount) error\(model.errorCount == 1 ? "" : "s")", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                .help("The last valid version keeps playing until the errors are fixed")
            }
            if model.warningCount > 0 {
                Button(action: showSource) {
                    Label("\(model.warningCount) warning\(model.warningCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

private struct DiagnosticsList: View {
    @ObservedObject var model: AppModel
    let reveal: (Int) -> Void

    var body: some View {
        List(model.diagnostics) { diagnostic in
            Button {
                if diagnostic.file.standardizedFileURL == model.selectedProfile?.configurationURL.standardizedFileURL {
                    reveal(diagnostic.line)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                    Text(diagnostic.message)
                    Spacer()
                    Text("\(diagnostic.file.lastPathComponent):\(diagnostic.line)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }
}
