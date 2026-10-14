import Foundation

enum VisualFilterKind: String, CaseIterable, Identifiable {
    case preamp
    case peaking
    case lowPass
    case highPass
    case bandPass
    case notch
    case allPass
    case lowShelf
    case highShelf
    case delay

    var id: Self { self }

    var displayName: String {
        switch self {
        case .preamp: return "Gain"
        case .peaking: return "Peaking EQ"
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

    var apoType: String? {
        switch self {
        case .preamp, .delay: return nil
        case .peaking: return "PK"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .bandPass: return "BP"
        case .notch: return "NO"
        case .allPass: return "AP"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        }
    }

    var symbolName: String {
        switch self {
        case .preamp: return "dial.medium"
        case .delay: return "clock.arrow.circlepath"
        case .peaking: return "waveform.path.ecg"
        case .lowPass, .highPass, .bandPass, .notch, .allPass, .lowShelf, .highShelf:
            return "slider.horizontal.2.square"
        }
    }

    var supportsGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf: return true
        default: return false
        }
    }

    var supportsQ: Bool {
        self != .preamp && self != .delay
    }
}

enum DelayUnit: String, CaseIterable, Identifiable {
    case milliseconds = "ms"
    case samples

    var id: Self { self }
}

struct EditableFilter: Identifiable, Equatable {
    let id: UUID
    var lineIndex: Int?
    var kind: VisualFilterKind
    var frequency: Double
    var gainDB: Double
    var q: Double
    var delayValue: Double
    var delayUnit: DelayUnit
    var sourceLine: String
    var isOff: Bool

    init(
        id: UUID = UUID(),
        lineIndex: Int? = nil,
        kind: VisualFilterKind,
        frequency: Double = 1_000,
        gainDB: Double = 0,
        q: Double = 1,
        delayValue: Double = 10,
        delayUnit: DelayUnit = .milliseconds,
        sourceLine: String = "",
        isOff: Bool = false
    ) {
        self.id = id
        self.lineIndex = lineIndex
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.delayValue = delayValue
        self.delayUnit = delayUnit
        self.sourceLine = sourceLine
        self.isOff = isOff
    }

    var title: String {
        switch kind {
        case .preamp: return "Gain"
        case .delay: return "Delay"
        default: return kind.displayName
        }
    }

    var detail: String {
        switch kind {
        case .preamp:
            return FilterEditorFormatter.decimal(gainDB) + " dB"
        case .delay:
            return FilterEditorFormatter.decimal(delayValue) + " " + delayUnit.rawValue
        default:
            let gain = kind.supportsGain ? " · " + FilterEditorFormatter.decimal(gainDB) + " dB" : ""
            return FilterEditorFormatter.frequency(frequency) + gain
        }
    }
}

struct VisualEditorParseResult {
    let filters: [EditableFilter]
    let isEditable: Bool
    let message: String?
}

enum FilterEditorParser {
    static func parse(_ text: String) -> VisualEditorParseResult {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var filters: [EditableFilter] = []

        for (lineIndex, rawLine) in lines.enumerated() {
            let uncommented = stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uncommented.isEmpty, !uncommented.hasPrefix("//") else { continue }
            guard let command = commandAndValue(uncommented) else { continue }
            let baseCommand = command.name.lowercased().split(separator: " ").first.map(String.init) ?? ""

            switch baseCommand {
            case "preamp":
                guard let gain = number(command.value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "") else {
                    return unavailable("A Preamp line has parameters that cannot be edited safely")
                }
                filters.append(EditableFilter(lineIndex: lineIndex, kind: .preamp, gainDB: gain, sourceLine: rawLine))
            case "filter":
                guard let filter = parseFilter(command.value, lineIndex: lineIndex, sourceLine: rawLine) else {
                    return unavailable("This profile contains a Filter form that is not representable in the visual editor")
                }
                filters.append(filter)
            case "delay":
                let tokens = tokens(command.value)
                guard let value = tokens.first.flatMap(number) else {
                    return unavailable("A Delay line has parameters that cannot be edited safely")
                }
                let unit: DelayUnit = tokens.dropFirst().first?.lowercased() == "ms" ? .milliseconds : .samples
                filters.append(EditableFilter(lineIndex: lineIndex, kind: .delay, delayValue: value, delayUnit: unit, sourceLine: rawLine))
            case "include", "if", "elseif", "else", "endif", "eval", "device", "stage", "copy", "graphiceq", "convolution", "vstplugin", "loudnesscorrection", "readregstring", "readregdword":
                return unavailable("This profile contains (command.name), so the source editor remains authoritative")
            default:
                return unavailable("This profile contains an unknown command, so visual edits are disabled")
            }
        }

        return VisualEditorParseResult(filters: filters, isEditable: true, message: nil)
    }

    private static func parseFilter(_ value: String, lineIndex: Int, sourceLine: String) -> EditableFilter? {
        var values = tokens(value)
        guard !values.isEmpty else { return nil }
        var isOff = false
        if values.first?.lowercased() == "on" { values.removeFirst() }
        else if values.first?.lowercased() == "off" { isOff = true; values.removeFirst() }
        guard let type = values.first?.lowercased(), let kind = kind(for: type), kind != .preamp, kind != .delay else { return nil }
        guard let frequency = labeledNumber("fc", in: values), frequency > 0 else { return nil }
        if values.contains(where: { $0.lowercased() == "bw" || $0.lowercased() == "oct" }) { return nil }
        let gain = labeledNumber("gain", in: values) ?? 0
        let q: Double
        if let parsedQ = labeledNumber("q", in: values) {
            q = parsedQ
        } else {
            switch kind {
            case .lowPass, .highPass, .bandPass: q = 1.0 / sqrt(2.0)
            case .notch: q = 30
            case .peaking, .allPass, .lowShelf, .highShelf: return nil
            case .preamp, .delay: return nil
            }
        }
        guard q > 0 else { return nil }
        return EditableFilter(
            lineIndex: lineIndex,
            kind: kind,
            frequency: frequency,
            gainDB: gain,
            q: q,
            sourceLine: sourceLine,
            isOff: isOff
        )
    }

    private static func kind(for type: String) -> VisualFilterKind? {
        switch type {
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
        let normalized = token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(normalized) { return value }
        for suffix in ["samples", "sample", "khz", "hz", "db", "ms", "oct", "s"] {
            if normalized.hasSuffix(suffix), let value = Double(normalized.dropLast(suffix.count)) { return value }
        }
        return nil
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

    private static func stripComment(_ line: String) -> String {
        var quoted = false
        for (index, character) in line.enumerated() {
            if character == "\"" { quoted.toggle() }
            if !quoted && character == "#" { return String(line.prefix(index)) }
        }
        return line
    }

    private static func unavailable(_ message: String) -> VisualEditorParseResult {
        VisualEditorParseResult(filters: [], isEditable: false, message: message)
    }
}

enum FilterEditorFormatter {
    static func line(for filter: EditableFilter) -> String {
        switch filter.kind {
        case .preamp:
            return "Preamp: \(decimal(filter.gainDB)) dB"
        case .delay:
            return "Delay: \(decimal(filter.delayValue)) \(filter.delayUnit.rawValue)"
        default:
            let state = filter.isOff ? "OFF" : "ON"
            let apoType = filter.kind.apoType ?? "PK"
            var line = "Filter: \(state) \(apoType) Fc \(decimal(filter.frequency)) Hz"
            if filter.kind.supportsGain { line += " Gain \(decimal(filter.gainDB)) dB" }
            if filter.kind.supportsQ { line += " Q \(decimal(filter.q))" }
            return line
        }
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.4g", value)
    }

    static func frequency(_ value: Double) -> String {
        if value >= 1_000 { return decimal(value / 1_000) + " kHz" }
        return decimal(value) + " Hz"
    }
}
