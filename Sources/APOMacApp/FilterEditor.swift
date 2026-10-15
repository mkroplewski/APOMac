import Foundation

enum VisualFilterKind: String, CaseIterable, Identifiable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case bandPass
    case notch
    case allPass
    case preamp
    case delay

    var id: Self { self }

    static let bandKinds: [VisualFilterKind] = [.peaking, .lowShelf, .highShelf, .lowPass, .highPass, .bandPass, .notch, .allPass]

    var displayName: String {
        switch self {
        case .preamp: return "Preamp"
        case .peaking: return "Peak"
        case .lowPass: return "Low-pass"
        case .highPass: return "High-pass"
        case .bandPass: return "Band-pass"
        case .notch: return "Notch"
        case .allPass: return "All-pass"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .delay: return "Delay"
        }
    }

    /// Default Equalizer APO type token written for new filters.
    var apoType: String? {
        switch self {
        case .preamp, .delay: return nil
        case .peaking: return "PK"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .bandPass: return "BP"
        case .notch: return "NO"
        case .allPass: return "AP"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        }
    }

    var symbolName: String {
        switch self {
        case .preamp: return "speaker.wave.2"
        case .delay: return "clock"
        case .peaking: return "chart.line.uptrend.xyaxis"
        case .lowShelf, .highShelf: return "chart.line.flattrend.xyaxis"
        case .lowPass, .highPass, .bandPass, .notch, .allPass: return "line.diagonal"
        }
    }

    var isBand: Bool { self != .preamp && self != .delay }

    var supportsGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf, .preamp: return true
        default: return false
        }
    }

    var supportsQ: Bool { isBand }

    var defaultQ: Double {
        switch self {
        case .notch: return 30
        case .lowPass, .highPass, .bandPass: return 0.7071
        case .lowShelf, .highShelf: return 0.7071
        default: return 1
        }
    }

    fileprivate static func from(apoType: String) -> VisualFilterKind? {
        switch apoType.lowercased() {
        case "pk", "peq", "modal": return .peaking
        case "lp", "lpq": return .lowPass
        case "hp", "hpq": return .highPass
        case "bp": return .bandPass
        case "no": return .notch
        case "ap": return .allPass
        case "ls", "lsc": return .lowShelf
        case "hs", "hsc": return .highShelf
        default: return nil
        }
    }
}

enum DelayUnit: String, CaseIterable, Identifiable {
    case milliseconds = "ms"
    case samples

    var id: Self { self }
}

struct EditableFilter: Identifiable, Equatable {
    var id: UUID
    var lineIndex: Int?
    var kind: VisualFilterKind {
        didSet {
            if oldValue != kind {
                // A different filter type must not reuse e.g. an "LSC" token.
                typeToken = nil
                if kind.isBand && !oldValue.isBand { q = kind.defaultQ }
            }
        }
    }
    var frequency: Double
    var gainDB: Double
    var q: Double
    var delayValue: Double
    var delayUnit: DelayUnit
    var isOff: Bool
    /// Original command text before the colon, e.g. "Filter 3".
    var commandLabel: String?
    /// Original type token, e.g. "LSC"; kept so edits do not change semantics.
    var typeToken: String?
    /// Original trailing "# comment", including the leading whitespace.
    var trailingComment: String
    var sourceLine: String

    init(
        id: UUID = UUID(),
        lineIndex: Int? = nil,
        kind: VisualFilterKind,
        frequency: Double = 1_000,
        gainDB: Double = 0,
        q: Double? = nil,
        delayValue: Double = 10,
        delayUnit: DelayUnit = .milliseconds,
        isOff: Bool = false,
        commandLabel: String? = nil,
        typeToken: String? = nil,
        trailingComment: String = "",
        sourceLine: String = ""
    ) {
        self.id = id
        self.lineIndex = lineIndex
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q ?? kind.defaultQ
        self.delayValue = delayValue
        self.delayUnit = delayUnit
        self.isOff = isOff
        self.commandLabel = commandLabel
        self.typeToken = typeToken
        self.trailingComment = trailingComment
        self.sourceLine = sourceLine
    }

    var title: String { kind.displayName }

    var detail: String {
        switch kind {
        case .preamp:
            return FilterEditorFormatter.signedDecimal(gainDB) + " dB"
        case .delay:
            return FilterEditorFormatter.decimal(delayValue) + " " + delayUnit.rawValue
        default:
            var parts = [FilterEditorFormatter.frequency(frequency)]
            if kind.supportsGain { parts.append(FilterEditorFormatter.signedDecimal(gainDB, maximumFractionDigits: 1) + " dB") }
            parts.append("Q " + FilterEditorFormatter.decimal(q, maximumFractionDigits: 2))
            return parts.joined(separator: " · ")
        }
    }
}

struct VisualEditorParseResult {
    var filters: [EditableFilter]
    let isEditable: Bool
    let message: String?

    /// Keeps identifiers stable across re-parses so selection and in-flight
    /// edits survive source changes.
    func reusingIdentifiers(from previous: [EditableFilter]) -> VisualEditorParseResult {
        var result = self
        for index in result.filters.indices where index < previous.count {
            result.filters[index].id = previous[index].id
        }
        return result
    }
}

/// The output device a profile is limited to.
enum ProfileDeviceRule: Equatable {
    case anyDevice
    /// A `Device:` value, normally a device name.
    case device(String)
    /// `Device:` lines the app doesn't manage, such as sections for several
    /// devices; the compiler applies them as written.
    case custom
}

enum FilterEditorParser {
    static func parse(_ text: String) -> VisualEditorParseResult {
        let lines = normalizedLines(text)
        let deviceLine = deviceLineIndex(in: lines)
        var filters: [EditableFilter] = []

        for (lineIndex, rawLine) in lines.enumerated() where lineIndex != deviceLine {
            let (code, comment) = splitComment(rawLine)
            let uncommented = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uncommented.isEmpty, !uncommented.hasPrefix("//") else { continue }
            guard let command = commandAndValue(uncommented) else { continue }
            let baseCommand = command.name.lowercased().split(separator: " ").first.map(String.init) ?? ""

            switch baseCommand {
            case "preamp":
                guard let gain = number(command.value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "") else {
                    return unavailable("A Preamp line has parameters the visual editor cannot represent.")
                }
                filters.append(EditableFilter(lineIndex: lineIndex, kind: .preamp, gainDB: gain, commandLabel: command.name, trailingComment: comment, sourceLine: rawLine))
            case "filter":
                guard let filter = parseFilter(command, lineIndex: lineIndex, comment: comment, sourceLine: rawLine) else {
                    return unavailable("Line \(lineIndex + 1) uses a Filter form the visual editor cannot represent.")
                }
                filters.append(filter)
            case "delay":
                let tokens = tokens(command.value)
                guard let value = tokens.first.flatMap(number) else {
                    return unavailable("A Delay line has parameters the visual editor cannot represent.")
                }
                let unit: DelayUnit = tokens.dropFirst().first?.lowercased() == "ms" ? .milliseconds : .samples
                filters.append(EditableFilter(lineIndex: lineIndex, kind: .delay, delayValue: value, delayUnit: unit, commandLabel: command.name, trailingComment: comment, sourceLine: rawLine))
            case "include", "if", "elseif", "else", "endif", "eval", "device", "stage", "channel", "copy",
                 "graphiceq", "convolution", "vstplugin", "loudnesscorrection", "readregstring", "readregdword":
                return unavailable("This profile uses \(command.name), so it is edited as source.")
            default:
                return unavailable("This profile contains “\(command.name)”, so it is edited as source.")
            }
        }

        return VisualEditorParseResult(filters: filters, isEditable: true, message: nil)
    }

    private static func parseFilter(_ command: (name: String, value: String), lineIndex: Int, comment: String, sourceLine: String) -> EditableFilter? {
        var values = tokens(command.value)
        guard !values.isEmpty else { return nil }
        var isOff = false
        if values.first?.lowercased() == "on" { values.removeFirst() }
        else if values.first?.lowercased() == "off" { isOff = true; values.removeFirst() }
        guard let typeToken = values.first, let kind = VisualFilterKind.from(apoType: typeToken) else { return nil }
        guard let fcIndex = values.firstIndex(where: { $0.lowercased() == "fc" }) else { return nil }
        // Shelf slopes ("LSC 12 dB Fc …") and bandwidths are not representable.
        if fcIndex != 1 { return nil }
        if values.contains(where: { $0.lowercased() == "bw" || $0.lowercased() == "oct" }) { return nil }
        guard let frequency = labeledNumber("fc", in: values), frequency > 0 else { return nil }
        let gain = labeledNumber("gain", in: values) ?? 0
        let q: Double
        if let parsedQ = labeledNumber("q", in: values) {
            q = parsedQ
        } else {
            switch kind {
            case .lowPass, .highPass, .bandPass, .notch: q = kind.defaultQ
            default: return nil
            }
        }
        guard q > 0 else { return nil }
        return EditableFilter(
            lineIndex: lineIndex,
            kind: kind,
            frequency: frequency,
            gainDB: gain,
            q: q,
            isOff: isOff,
            commandLabel: command.name,
            typeToken: typeToken,
            trailingComment: comment,
            sourceLine: sourceLine
        )
    }

    /// Parses numbers typed by the user: accepts decimal commas, unit
    /// suffixes and a "k" multiplier ("2,5", "1.2k", "80 Hz").
    static func userNumber(_ text: String) -> Double? {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "−", with: "-")
        for suffix in ["samples", "sample", "hz", "db", "ms"] where normalized.hasSuffix(suffix) {
            normalized.removeLast(suffix.count)
        }
        var multiplier = 1.0
        if normalized.hasSuffix("k") {
            multiplier = 1_000
            normalized.removeLast()
        }
        if normalized.hasPrefix("+") { normalized.removeFirst() }
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value * multiplier
    }

    // MARK: Profile device

    static func deviceRule(in text: String) -> ProfileDeviceRule {
        let lines = normalizedLines(text)
        if let index = deviceLineIndex(in: lines), let value = command(in: lines[index])?.value {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value.lowercased() == "all" ? .anyDevice : .device(value)
        }
        return lines.contains { command(in: $0).map(isDevice) == true } ? .custom : .anyDevice
    }

    /// Sets the profile's leading `Device:` line to `deviceName`, or removes
    /// it (nil). Returns nil when the profile has `Device:` lines of its own.
    static func settingDevice(_ deviceName: String?, in text: String) -> String? {
        var lines = normalizedLines(text)
        if let index = deviceLineIndex(in: lines) {
            if let deviceName {
                lines[index] = "Device: \(sanitizedDeviceValue(deviceName))" + splitComment(lines[index]).comment
            } else {
                lines.remove(at: index)
            }
        } else if lines.contains(where: { command(in: $0).map(isDevice) == true }) {
            return nil
        } else if let deviceName {
            // Ahead of every command, after leading comments.
            let end = lines.last == "" ? lines.count - 1 : lines.count
            let index = lines.firstIndex { command(in: $0) != nil } ?? max(0, end)
            lines.insert("Device: \(sanitizedDeviceValue(deviceName))", at: index)
        }
        return lines.joined(separator: "\n")
    }

    /// Where a Preamp goes: ahead of the filters, after leading comments and
    /// the profile's `Device:` line.
    static func preambleEnd(_ lines: [String]) -> Int {
        if let deviceLine = deviceLineIndex(in: lines) { return deviceLine + 1 }
        return lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? lines.count
    }

    /// The profile's device line: a `Device:` line ahead of every other
    /// command that is the profile's only `Device:` line.
    private static func deviceLineIndex(in lines: [String]) -> Int? {
        var firstCommand: Int?
        var deviceLines: [Int] = []
        for (index, line) in lines.enumerated() {
            guard let command = command(in: line) else { continue }
            if firstCommand == nil { firstCommand = index }
            if isDevice(command) { deviceLines.append(index) }
        }
        guard deviceLines.count == 1, deviceLines.first == firstCommand else { return nil }
        return firstCommand
    }

    private static func command(in line: String) -> (name: String, value: String)? {
        let code = splitComment(line).code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !code.hasPrefix("//") else { return nil }
        return commandAndValue(code)
    }

    private static func isDevice(_ command: (name: String, value: String)) -> Bool {
        command.name.lowercased().split(separator: " ").first == "device"
    }

    /// ";" separates alternatives, "#" starts a comment and backticks an
    /// inline expression.
    private static func sanitizedDeviceValue(_ name: String) -> String {
        name.replacingOccurrences(of: "[;#`]", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func labeledNumber(_ label: String, in values: [String]) -> Double? {
        guard let index = values.firstIndex(where: { $0.lowercased() == label }), index + 1 < values.count else { return nil }
        return number(values[index + 1])
    }

    private static func tokens(_ value: String) -> [String] {
        value.replacingOccurrences(of: ",", with: ".")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func number(_ token: String) -> Double? {
        Double(token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func commandAndValue(_ line: String) -> (name: String, value: String)? {
        if let colon = line.firstIndex(of: ":") {
            return (
                String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines),
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let pieces = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let name = pieces.first else { return nil }
        return (String(name), pieces.dropFirst().first.map(String.init) ?? "")
    }

    /// Splits a line into code and its trailing comment (with the whitespace
    /// before "#"), ignoring "#" inside quotes.
    private static func splitComment(_ line: String) -> (code: String, comment: String) {
        var quoted = false
        for index in line.indices {
            let character = line[index]
            if character == "\"" { quoted.toggle() }
            if !quoted && character == "#" {
                let code = line[..<index]
                let trimmedCode = code.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                let whitespace = String(code.dropFirst(trimmedCode.count))
                return (String(code), whitespace + String(line[index...]))
            }
        }
        return (line, "")
    }

    private static func unavailable(_ message: String) -> VisualEditorParseResult {
        VisualEditorParseResult(filters: [], isEditable: false, message: message)
    }
}

enum FilterEditorFormatter {
    static func line(for filter: EditableFilter) -> String {
        let line: String
        switch filter.kind {
        case .preamp:
            line = "\(label(filter, default: "Preamp")): \(decimal(filter.gainDB, maximumFractionDigits: 2)) dB"
        case .delay:
            line = "\(label(filter, default: "Delay")): \(decimal(filter.delayValue, maximumFractionDigits: 3)) \(filter.delayUnit.rawValue)"
        default:
            let state = filter.isOff ? "OFF" : "ON"
            let token = filter.typeToken.flatMap { VisualFilterKind.from(apoType: $0) == filter.kind ? $0 : nil }
                ?? filter.kind.apoType ?? "PK"
            var text = "\(label(filter, default: "Filter")): \(state) \(token) Fc \(decimal(filter.frequency, maximumFractionDigits: 2)) Hz"
            if filter.kind.supportsGain { text += " Gain \(decimal(filter.gainDB, maximumFractionDigits: 2)) dB" }
            if filter.kind.supportsQ { text += " Q \(decimal(filter.q, maximumFractionDigits: 4))" }
            line = text
        }
        return line + filter.trailingComment
    }

    private static func label(_ filter: EditableFilter, default defaultLabel: String) -> String {
        guard let label = filter.commandLabel, !label.isEmpty else { return defaultLabel }
        return label
    }

    /// Plain decimal notation (never scientific), "." separator, no trailing zeros.
    static func decimal(_ value: Double, maximumFractionDigits: Int = 3) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.\(maximumFractionDigits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    static func signedDecimal(_ value: Double, maximumFractionDigits: Int = 2) -> String {
        let text = decimal(value, maximumFractionDigits: maximumFractionDigits)
        return value > 0 && text != "0" ? "+" + text : text
    }

    static func frequency(_ value: Double) -> String {
        if value >= 1_000 { return decimal(value / 1_000, maximumFractionDigits: 2) + " kHz" }
        return decimal(value, maximumFractionDigits: value < 100 ? 1 : 0) + " Hz"
    }
}
