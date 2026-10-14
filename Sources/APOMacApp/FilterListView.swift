import SwiftUI

struct FilterListView: View {
    @ObservedObject var model: AppModel
    let showSource: () -> Void

    var body: some View {
        if model.visualEditorAvailable {
            editor
        } else {
            EffectiveChainView(message: model.visualEditorMessage, nodeNames: model.nodeNames, showSource: showSource)
        }
    }

    private var bandNumbers: [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        for (index, filter) in model.visualFilters.filter(\.kind.isBand).enumerated() {
            numbers[filter.id] = index + 1
        }
        return numbers
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("").frame(width: FilterRowLayout.badge + FilterRowLayout.toggle + 8, alignment: .leading)
                Text("Type").frame(width: FilterRowLayout.type, alignment: .leading)
                Text("Frequency").frame(width: FilterRowLayout.frequency, alignment: .leading)
                Text("Gain").frame(width: FilterRowLayout.gain, alignment: .leading)
                Text("Q").frame(width: FilterRowLayout.q, alignment: .leading)
                Spacer()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()

            if model.visualFilters.isEmpty {
                ContentUnavailableView {
                    Label("Flat response", systemImage: "waveform.path")
                } description: {
                    Text("Add a filter, or double-click the graph to place a peak filter.")
                } actions: {
                    AddFilterMenu(model: model)
                }
                .frame(maxHeight: .infinity)
            } else {
                let numbers = bandNumbers
                List(selection: $model.selectedFilterID) {
                    ForEach(model.visualFilters) { filter in
                        FilterRowView(
                            filter: filter,
                            number: numbers[filter.id],
                            onChange: { model.updateFilter($0) },
                            onDelete: { model.deleteFilter(filter) }
                        )
                        .tag(filter.id)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                .onDeleteCommand {
                    if let id = model.selectedFilterID, let filter = model.visualFilters.first(where: { $0.id == id }) {
                        model.deleteFilter(filter)
                    }
                }
            }
        }
    }
}

struct AddFilterMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(VisualFilterKind.bandKinds) { kind in
                Button(kind.displayName, systemImage: kind.symbolName) { model.addFilter(kind) }
            }
            Divider()
            Button("Preamp", systemImage: VisualFilterKind.preamp.symbolName) { model.addFilter(.preamp) }
                .disabled(model.visualFilters.contains { $0.kind == .preamp })
            Button("Delay", systemImage: VisualFilterKind.delay.symbolName) { model.addFilter(.delay) }
        } label: {
            Label("Add Filter", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .fixedSize()
        .help("Add a filter, or double-click the graph to place a peak filter")
    }
}

private enum FilterRowLayout {
    static let badge: CGFloat = 22
    static let toggle: CGFloat = 22
    static let type: CGFloat = 132
    static let frequency: CGFloat = 104
    static let gain: CGFloat = 92
    static let q: CGFloat = 80
}

private struct FilterRowView: View {
    let filter: EditableFilter
    let number: Int?
    let onChange: (EditableFilter) -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            badge.frame(width: FilterRowLayout.badge)
            Group {
                if filter.kind.isBand {
                    Toggle("Enabled", isOn: Binding(get: { !filter.isOff }, set: { change { $0.isOff = !$1 }($0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help(filter.isOff ? "Turn on" : "Turn off")
                } else {
                    Color.clear
                }
            }
            .frame(width: FilterRowLayout.toggle)
            .padding(.leading, 8)

            switch filter.kind {
            case .preamp:
                Text("Preamp").frame(width: FilterRowLayout.type + FilterRowLayout.frequency, alignment: .leading)
                NumberField(value: filter.gainDB, unit: "dB", format: { FilterEditorFormatter.decimal($0, maximumFractionDigits: 2) }, step: { $0 + Double($1) * ($2 ? 1 : 0.1) }, range: -60...30) { value in
                    change { $0.gainDB = $1 }(value)
                }
                .frame(width: FilterRowLayout.gain, alignment: .leading)
            case .delay:
                Text("Delay").frame(width: FilterRowLayout.type, alignment: .leading)
                NumberField(value: filter.delayValue, unit: nil, format: { FilterEditorFormatter.decimal($0, maximumFractionDigits: 3) }, step: { max(0, $0 + Double($1) * ($2 ? 10 : 1)) }, range: 0...10_000) { value in
                    change { $0.delayValue = $1 }(value)
                }
                .frame(width: FilterRowLayout.frequency - 8, alignment: .leading)
                Picker("Unit", selection: Binding(get: { filter.delayUnit }, set: { change { $0.delayUnit = $1 }($0) })) {
                    ForEach(DelayUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            default:
                Picker("Type", selection: Binding(get: { filter.kind }, set: { change { $0.kind = $1 }($0) })) {
                    ForEach(VisualFilterKind.bandKinds) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: FilterRowLayout.type - 10, alignment: .leading)
                .padding(.trailing, 10)
                NumberField(value: filter.frequency, unit: "Hz", format: { FilterEditorFormatter.decimal($0, maximumFractionDigits: $0 < 100 ? 1 : 0) }, step: { $0 * pow(2, Double($1) / ($2 ? 6 : 24)) }, range: 10...22_000) { value in
                    change { $0.frequency = $1 }(value)
                }
                .frame(width: FilterRowLayout.frequency, alignment: .leading)
                Group {
                    if filter.kind.supportsGain {
                        NumberField(value: filter.gainDB, unit: "dB", format: { FilterEditorFormatter.decimal($0, maximumFractionDigits: 1) }, step: { $0 + Double($1) * ($2 ? 1 : 0.1) }, range: -30...30) { value in
                            change { $0.gainDB = $1 }(value)
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary).padding(.leading, 8)
                    }
                }
                .frame(width: FilterRowLayout.gain, alignment: .leading)
                NumberField(value: filter.q, unit: nil, format: { FilterEditorFormatter.decimal($0, maximumFractionDigits: 3) }, step: { $0 * pow($2 ? 1.25 : 1.05, Double($1)) }, range: 0.01...100) { value in
                    change { $0.q = $1 }(value)
                }
                .frame(width: FilterRowLayout.q, alignment: .leading)
            }

            Spacer(minLength: 8)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete filter")
            .opacity(isHovering ? 1 : 0)
        }
        .opacity(filter.isOff ? 0.55 : 1)
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var badge: some View {
        if let number {
            ZStack {
                Circle().fill(filter.isOff ? Color.secondary.opacity(0.3) : BandPalette.color(number - 1))
                Text("\(number)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
        } else {
            Image(systemName: filter.kind.symbolName).foregroundStyle(.secondary)
        }
    }

    /// Builds a setter that applies `mutation` to a copy and reports it.
    private func change<Value>(_ mutation: @escaping (inout EditableFilter, Value) -> Void) -> (Value) -> Void {
        { value in
            var updated = filter
            mutation(&updated, value)
            if updated != filter { onChange(updated) }
        }
    }
}

/// A compact numeric field: commits on Return or when focus leaves, accepts
/// "2,5" and "1.2k", and nudges the value with ↑/↓ (⇧ for larger steps).
struct NumberField: View {
    let value: Double
    let unit: String?
    let format: (Double) -> String
    let step: (_ value: Double, _ direction: Int, _ large: Bool) -> Double
    let range: ClosedRange<Double>
    let onCommit: (Double) -> Void

    @State private var text = ""
    @State private var isInvalid = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 3) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($isFocused)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: isInvalid ? 1 : 0))
                .onSubmit(commit)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    let direction = press.key == .upArrow ? 1 : -1
                    let next = clamp(step(FilterEditorParser.userNumber(text) ?? value, direction, press.modifiers.contains(.shift)))
                    text = format(next)
                    onCommit(next)
                    return .handled
                }
            if let unit {
                Text(unit).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
        .padding(.trailing, 8)
        .onAppear { text = format(value) }
        .onChange(of: value) { _, newValue in
            if !isFocused { text = format(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        guard let parsed = FilterEditorParser.userNumber(text) else {
            isInvalid = !text.isEmpty
            if text.isEmpty { text = format(value) }
            return
        }
        isInvalid = false
        let clamped = clamp(parsed)
        text = format(clamped)
        if abs(clamped - value) > 1e-9 { onCommit(clamped) }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct EffectiveChainView: View {
    let message: String?
    let nodeNames: [String]
    let showSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Source-driven profile").font(.headline)
                    Text(message ?? "This profile uses commands that are edited as source.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Edit Source", action: showSource)
            }
            .padding([.horizontal, .top], 14)

            Text("Effective processing chain").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 14)
            List {
                ForEach(Array(nodeNames.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        Text(name)
                    }
                }
                if nodeNames.isEmpty {
                    Text("No active processing").foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }
}
