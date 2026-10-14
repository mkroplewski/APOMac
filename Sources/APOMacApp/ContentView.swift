import APOAudioRuntime
import APOEngine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingImporter = false
    @State private var showingAddFilter = false
    @State private var showingRename = false
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedProfileID) {
                if model.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No profiles", systemImage: "slider.horizontal.3")
                    } description: {
                        Text("Create a profile or import an Equalizer APO profile directory.")
                    } actions: {
                        Button("New Profile", systemImage: "plus") { model.createProfile() }
                    }
                } else {
                    Section("Profiles") {
                        ForEach(model.profiles) { profile in
                            Label(profile.name, systemImage: "slider.horizontal.3")
                                .tag(profile.id)
                                .contextMenu {
                                    Button("Rename", systemImage: "pencil") {
                                        renameText = profile.name
                                        model.selectedProfileID = profile.id
                                        showingRename = true
                                    }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        model.selectedProfileID = profile.id
                                        model.deleteSelectedProfile()
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("APOMac")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .onChange(of: model.selectedProfileID) { _, id in
                if let id { model.selectProfile(id) }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Button { model.createProfile() } label: {
                        Image(systemName: "plus")
                    }
                    .help("New profile")
                    Spacer()
                    Button { 
                        guard let profile = model.selectedProfile else { return }
                        renameText = profile.name
                        showingRename = true
                    } label: { Image(systemName: "pencil") }
                    .help("Rename profile")
                    .disabled(model.selectedProfile == nil)
                    Button(role: .destructive) {
                        model.deleteSelectedProfile()
                    } label: { Image(systemName: "trash") }
                    .help("Delete profile")
                    .disabled(model.selectedProfile == nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(10)
                .background(.bar)
            }
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    chainPanel
                    Divider()
                    inspector
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                sourcePanel
            }
            .frame(minWidth: 980, minHeight: 700)
        }
        .task { await model.reload() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importProfile(from: url)
            }
        }
        .sheet(isPresented: $showingAddFilter) {
            NewFilterSheet { filter in
                model.addFilter(filter)
                showingAddFilter = false
            }
        }
        .alert("Rename Profile", isPresented: $showingRename) {
            TextField("Profile name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.renameSelectedProfile(to: renameText) }
        } message: {
            Text("Choose a name for this profile.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: model.isBypassed ? "pause.circle.fill" : "waveform.circle.fill")
                    .foregroundStyle(model.isBypassed ? .orange : .green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedProfile?.name ?? "No profile").font(.headline)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.isBypassed ? .orange : (model.isConfigurationDirty ? .yellow : .green))
                            .frame(width: 6, height: 6)
                        Text(model.isConfigurationDirty ? "Unsaved changes" : model.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Picker("Output", selection: $model.selectedDeviceUID) {
                    ForEach(model.devices) { device in Text(device.name).tag(device.uid) }
                }
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
                .onChange(of: model.selectedDeviceUID) { _, _ in
                    model.stop()
                    Task { await model.reload() }
                }
                Button(model.isBypassed ? "Enable" : "Bypass", systemImage: model.isBypassed ? "play.fill" : "pause.fill") {
                    model.toggleBypass()
                }
                .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 8) {
                if model.isConfigurationDirty {
                    Label("Changes are not saved", systemImage: "pencil.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Import", systemImage: "square.and.arrow.down") { showingImporter = true }
                Button("Export", systemImage: "square.and.arrow.up") { model.exportSelectedProfile() }
                Button("Apply & Reload", systemImage: "arrow.clockwise") { Task { await model.saveAndReload() } }
                    .disabled(model.selectedProfile == nil || model.isCompiling)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Source configuration", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Equalizer APO syntax")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SourceEditor(text: Binding(
                get: { model.configurationText },
                set: { model.updateConfigurationText($0) }
            ))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 210)
        .background(.bar)
    }

    private var chainPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.visualEditorAvailable ? "Filter chain" : "Effective chain")
                    .font(.headline)
                Spacer()
                if model.isCompiling { ProgressView().controlSize(.small) }
            }
            if model.visualEditorAvailable {
                if model.visualFilters.isEmpty {
                    ContentUnavailableView("Pass-through", systemImage: "waveform", description: Text("Add a filter to begin shaping the output"))
                } else {
                    List(selection: $model.selectedFilterID) {
                        ForEach(model.visualFilters) { filter in
                            FilterRow(filter: filter)
                                .tag(filter.id)
                                .contextMenu {
                                    Button("Delete Filter", systemImage: "trash", role: .destructive) {
                                        model.deleteFilter(filter)
                                    }
                                }
                        }
                    }
                    .listStyle(.inset)
                }
                Button("Add Filter", systemImage: "plus") { showingAddFilter = true }
                    .buttonStyle(.bordered)
                    .disabled(!model.visualEditorAvailable)
            } else {
                Text(model.visualEditorMessage ?? "This profile is source-driven.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                List(model.nodeNames, id: \.self) { name in
                    HStack {
                        Image(systemName: name.localizedCaseInsensitiveContains("convolution") ? "waveform.path.ecg" : "slider.horizontal.2.square")
                            .foregroundStyle(.tint)
                        Text(name)
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .background(
                        model.selectedNodeName == name
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .onTapGesture { model.selectedNodeName = name }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Response").font(.headline)
            ResponseGraph(
                points: model.response,
                approximate: model.responseIsApproximate,
                isPreview: model.responseIsPreview
            )
                .frame(height: 200)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Label("Gain / headroom", systemImage: "gauge.with.dots.needle.33percent")
                Spacer()
                if let peak = model.response.map(\.magnitudeDB).max() {
                    Text(String(format: "Peak %+0.1f dB", peak)).foregroundStyle(.secondary)
                } else {
                    Text("No active response").foregroundStyle(.secondary)
                }
            }
            if model.visualEditorAvailable, let selectedFilter = model.visualFilters.first(where: { $0.id == model.selectedFilterID }) {
                FilterInspector(
                    filter: selectedFilter,
                    onUpdate: { model.updateFilter($0) },
                    onDelete: { model.deleteFilter(selectedFilter) }
                )
            } else if let selectedNodeName = model.selectedNodeName {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected filter").font(.subheadline.weight(.semibold))
                    Text(selectedNodeName).font(.callout)
                    Text("This effective graph is read-only because the profile contains source-level logic or an unsupported directive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            Text("Diagnostics").font(.headline)
            if model.diagnostics.isEmpty {
                Label("Configuration is valid", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.diagnostics) { diagnostic in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(diagnostic.message, systemImage: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                                    .font(.callout)
                                Text("\(diagnostic.file.lastPathComponent):\(diagnostic.line)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(minWidth: 400, idealWidth: 500, maxWidth: .infinity)
    }
}

private struct ResponseGraph: View {
    let points: [APOFrequencyResponsePoint]
    let approximate: Bool
    let isPreview: Bool

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Canvas { context, size in
                    guard let first = points.first, let last = points.last, points.count > 1 else {
                        var emptyGrid = Path()
                        emptyGrid.addRect(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
                        context.stroke(emptyGrid, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                        return
                    }
                    let minimumFrequency = max(first.frequency, 1)
                    let maximumFrequency = max(last.frequency, minimumFrequency * 1.01)
                    let values = points.map(\.magnitudeDB)
                    let minimumDB = min(-12.0, floor((values.min() ?? -12.0) / 6.0) * 6.0)
                    let maximumDB = max(12.0, ceil((values.max() ?? 12.0) / 6.0) * 6.0)
                    let dBRange = max(1.0, maximumDB - minimumDB)
                    let frequencyRange = max(log(maximumFrequency / minimumFrequency), 1.0e-9)

                    var grid = Path()
                    for dB in stride(from: minimumDB, through: maximumDB, by: 6.0) {
                        let y = size.height * CGFloat((maximumDB - dB) / dBRange)
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 1)

                    var response = Path()
                    for (index, point) in points.enumerated() {
                        let x = size.width * CGFloat(log(max(point.frequency, minimumFrequency) / minimumFrequency) / frequencyRange)
                        let y = size.height * CGFloat((maximumDB - point.magnitudeDB) / dBRange)
                        let position = CGPoint(x: x, y: y)
                        if index == 0 { response.move(to: position) } else { response.addLine(to: position) }
                    }
                    context.stroke(response, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    let zeroY = size.height * CGFloat(maximumDB / dBRange)
                    var zero = Path()
                    zero.move(to: CGPoint(x: 0, y: zeroY))
                    zero.addLine(to: CGPoint(x: size.width, y: zeroY))
                    context.stroke(zero, with: .color(.secondary.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                if points.count < 2 {
                    Text("Apply a profile to see its response")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(formatFrequency(points.first?.frequency ?? 20))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(formatFrequency(points.last?.frequency ?? 20_000))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                    Text(isPreview ? "Preview · Apply to activate" : (approximate ? "Approximate" : "Compiled response"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private func formatFrequency(_ frequency: Double) -> String {
        if frequency >= 1_000 { return String(format: "%.0f kHz", frequency / 1_000) }
        return String(format: "%.0f Hz", frequency)
    }
}

private struct FilterRow: View {
    let filter: EditableFilter

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: filter.kind.symbolName)
                .foregroundStyle(filter.isOff ? Color.secondary : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(filter.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(filter.isOff ? .secondary : .primary)
                Text(filter.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if filter.isOff {
                Text("Off")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

private struct FilterInspector: View {
    let filter: EditableFilter
    let onUpdate: (EditableFilter) -> Void
    let onDelete: () -> Void

    @State private var draft: EditableFilter
    @State private var frequencyText: String
    @State private var gainText: String
    @State private var qText: String
    @State private var delayText: String
    @State private var errorMessage: String?

    init(filter: EditableFilter, onUpdate: @escaping (EditableFilter) -> Void, onDelete: @escaping () -> Void) {
        self.filter = filter
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _draft = State(initialValue: filter)
        _frequencyText = State(initialValue: FilterEditorFormatter.decimal(filter.frequency))
        _gainText = State(initialValue: FilterEditorFormatter.decimal(filter.gainDB))
        _qText = State(initialValue: FilterEditorFormatter.decimal(filter.q))
        _delayText = State(initialValue: FilterEditorFormatter.decimal(filter.delayValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filter inspector").font(.headline)
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
            }

            Picker("Type", selection: $draft.kind) {
                ForEach(VisualFilterKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            FilterParameterFields(
                draft: $draft,
                frequencyText: $frequencyText,
                gainText: $gainText,
                qText: $qText,
                delayText: $delayText
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text(filter.sourceLine.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Apply", systemImage: "checkmark") { applyChanges() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: filter.id) { _, _ in reset(from: filter) }
    }

    private func applyChanges() {
        guard let gain = Double(gainText), let frequency = Double(frequencyText),
              let q = Double(qText), let delay = Double(delayText),
              frequency > 0, q > 0, delay >= 0 else {
            errorMessage = "Enter valid numeric values."
            return
        }
        draft.frequency = frequency
        draft.gainDB = gain
        draft.q = q
        draft.delayValue = delay
        errorMessage = nil
        onUpdate(draft)
    }

    private func reset(from filter: EditableFilter) {
        draft = filter
        frequencyText = FilterEditorFormatter.decimal(filter.frequency)
        gainText = FilterEditorFormatter.decimal(filter.gainDB)
        qText = FilterEditorFormatter.decimal(filter.q)
        delayText = FilterEditorFormatter.decimal(filter.delayValue)
        errorMessage = nil
    }
}

private struct FilterParameterFields: View {
    @Binding var draft: EditableFilter
    @Binding var frequencyText: String
    @Binding var gainText: String
    @Binding var qText: String
    @Binding var delayText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.kind == .preamp {
                LabeledContent("Gain") {
                    TextField("dB", text: $gainText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            } else if draft.kind == .delay {
                LabeledContent("Delay") {
                    HStack(spacing: 6) {
                        TextField("Amount", text: $delayText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Picker("Unit", selection: $draft.delayUnit) {
                            ForEach(DelayUnit.allCases) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                }
            } else {
                LabeledContent("Frequency") {
                    TextField("Hz", text: $frequencyText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                if draft.kind.supportsGain {
                    LabeledContent("Gain") {
                        TextField("dB", text: $gainText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }
                if draft.kind.supportsQ {
                    LabeledContent("Q") {
                        TextField("Q", text: $qText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }
                Toggle("Enabled", isOn: Binding(
                    get: { !draft.isOff },
                    set: { draft.isOff = !$0 }
                ))
            }
        }
    }
}

private struct NewFilterSheet: View {
    let onAdd: (EditableFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = EditableFilter(kind: .peaking)
    @State private var frequencyText = "1000"
    @State private var gainText = "0"
    @State private var qText = "1"
    @State private var delayText = "10"
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add filter").font(.title2.weight(.semibold))
            Text("This writes a standard Equalizer APO command into the profile source.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Type", selection: $draft.kind) {
                ForEach(VisualFilterKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            FilterParameterFields(
                draft: $draft,
                frequencyText: $frequencyText,
                gainText: $gainText,
                qText: $qText,
                delayText: $delayText
            )
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add", systemImage: "plus") { add() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 390)
    }

    private func add() {
        guard let gain = Double(gainText), let frequency = Double(frequencyText),
              let q = Double(qText), let delay = Double(delayText),
              frequency > 0, q > 0, delay >= 0 else {
            errorMessage = "Enter valid numeric values."
            return
        }
        draft.frequency = frequency
        draft.gainDB = gain
        draft.q = q
        draft.delayValue = delay
        onAdd(draft)
        dismiss()
    }
}
