import AVFoundation
import Foundation

public struct DefaultAPOCompiler: APOCompiler {
    public init() {}

    public func compile(
        profileRoot: URL,
        environment: APOEnvironment
    ) async -> Result<PreparedGraph, ConfigurationDiagnostics> {
        await Task.detached(priority: .userInitiated) {
            var worker = CompilerWorker(profileRoot: profileRoot, environment: environment)
            return worker.run(rootSource: nil)
        }.value
    }

    /// Compiles unsaved text as if it were stored at `sourceURL`, so relative
    /// Include and Convolution paths resolve against the profile directory.
    public func compile(
        source: String,
        sourceURL: URL,
        environment: APOEnvironment
    ) async -> Result<PreparedGraph, ConfigurationDiagnostics> {
        await Task.detached(priority: .userInitiated) {
            var worker = CompilerWorker(profileRoot: sourceURL, environment: environment)
            return worker.run(rootSource: source)
        }.value
    }
}

private struct ConditionalFrame {
    let parentActive: Bool
    var branchTaken: Bool
    var active: Bool
}

private struct CompilerWorker {
    let profileRoot: URL
    let environment: APOEnvironment
    var nodes: [RenderNode] = []
    var diagnostics: [ConfigurationDiagnostic] = []
    var includeStack: [URL] = []
    var conditionalStack: [ConditionalFrame] = []
    var selectedChannels: [Int]
    var deviceMatches = true
    var stageMatches = true
    var expression: ExpressionEvaluator

    init(profileRoot: URL, environment: APOEnvironment) {
        self.profileRoot = profileRoot
        self.environment = environment
        self.selectedChannels = Array(0..<max(1, environment.outputChannelCount))
        self.expression = ExpressionEvaluator(context: ExpressionContext(environment: environment))
    }

    mutating func run(rootSource: String?) -> Result<PreparedGraph, ConfigurationDiagnostics> {
        let configURL: URL
        if profileRoot.pathExtension.lowercased() == "txt" {
            configURL = profileRoot
        } else {
            configURL = profileRoot.appendingPathComponent("config.txt")
        }

        if let rootSource {
            process(document: APOConfigurationFile(url: configURL, text: rootSource), url: configURL)
        } else {
            process(file: configURL)
        }
        if !conditionalStack.isEmpty {
            diagnostics.append(ConfigurationDiagnostic(
                severity: .error,
                file: configURL,
                line: 1,
                message: "Unclosed If block",
                code: "unclosed-if"
            ))
        }

        if diagnostics.contains(where: { $0.severity == .error }) {
            return .failure(ConfigurationDiagnostics(diagnostics))
        }
        return .success(PreparedGraph(
            channelCount: max(1, environment.outputChannelCount),
            maxFrameCount: environment.maxFrameCount,
            sampleRate: environment.sampleRate,
            nodes: nodes,
            diagnostics: diagnostics
        ))
    }

    private var active: Bool {
        conditionalStack.allSatisfy(\.active)
    }

    private var processingActive: Bool {
        active && deviceMatches && stageMatches
    }

    private mutating func process(file url: URL) {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if includeStack.contains(canonicalURL) {
            diagnostics.append(ConfigurationDiagnostic(
                severity: .error,
                file: url,
                line: 1,
                message: "Include cycle detected: \(includeStack.map(\.lastPathComponent).joined(separator: " -> ")) -> \(url.lastPathComponent)",
                code: "include-cycle"
            ))
            return
        }

        let document: APOConfigurationFile
        do {
            document = try ConfigurationParser.read(url: url)
        } catch {
            diagnostics.append(ConfigurationDiagnostic(
                severity: .error,
                file: url,
                line: 1,
                message: error.localizedDescription,
                code: "include-read"
            ))
            return
        }
        process(document: document, url: url)
    }

    private mutating func process(document: APOConfigurationFile, url: URL) {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        includeStack.append(canonicalURL)
        for line in document.lines {
            process(line: SourceLine(line), currentFile: url)
        }
        _ = includeStack.popLast()
    }

    private mutating func process(line source: SourceLine, currentFile: URL) {
        let uncommented = stripComment(source.raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uncommented.isEmpty else { return }

        let commandAndValue: (String, String)
        if let command = source.command {
            let value = source.value ?? ""
            commandAndValue = (command.trimmingCharacters(in: .whitespacesAndNewlines), value)
        } else {
            let pieces = splitWhitespace(uncommented)
            guard let command = pieces.first else { return }
            commandAndValue = (command, pieces.dropFirst().joined(separator: " "))
        }

        let command = commandAndValue.0
        let value = commandAndValue.1
        let lowerCommand = command.lowercased()
        let baseCommand = lowerCommand.split(separator: " ").first.map(String.init) ?? lowerCommand

        switch baseCommand {
        case "if":
            beginIf(value, source: source)
        case "elseif":
            continueIf(value, source: source)
        case "else":
            beginElse(source: source)
        case "endif":
            endIf(source: source)
        default:
            processNonConditional(command: command, baseCommand: baseCommand, value: value, source: source, currentFile: currentFile)
        }
    }

    private mutating func beginIf(_ text: String, source: SourceLine) {
        let parentActive = active
        let condition = parentActive ? evaluateCondition(text, source: source) : false
        conditionalStack.append(ConditionalFrame(parentActive: parentActive, branchTaken: condition, active: parentActive && condition))
    }

    private mutating func continueIf(_ text: String, source: SourceLine) {
        guard !conditionalStack.isEmpty else {
            addError("ElseIf without If", source: source, code: "conditional-order")
            return
        }
        var frame = conditionalStack.removeLast()
        let condition = frame.parentActive && !frame.branchTaken ? evaluateCondition(text, source: source) : false
        frame.active = frame.parentActive && !frame.branchTaken && condition
        frame.branchTaken = frame.branchTaken || condition
        conditionalStack.append(frame)
    }

    private mutating func beginElse(source: SourceLine) {
        guard !conditionalStack.isEmpty else {
            addError("Else without If", source: source, code: "conditional-order")
            return
        }
        var frame = conditionalStack.removeLast()
        frame.active = frame.parentActive && !frame.branchTaken
        frame.branchTaken = true
        conditionalStack.append(frame)
    }

    private mutating func endIf(source: SourceLine) {
        guard conditionalStack.popLast() != nil else {
            addError("EndIf without If", source: source, code: "conditional-order")
            return
        }
    }

    private mutating func evaluateCondition(_ raw: String, source: SourceLine) -> Bool {
        do {
            return try expression.evaluate(expandEnvironmentPlaceholders(raw)).booleanValue
        } catch {
            addError("Invalid condition: \(error.localizedDescription)", source: source, code: "expression")
            return false
        }
    }

    private mutating func processNonConditional(
        command: String,
        baseCommand: String,
        value rawValue: String,
        source: SourceLine,
        currentFile: URL
    ) {
        let value: String
        do {
            value = try expandInlineExpressions(rawValue, source: source)
        } catch {
            addError("Invalid inline expression: \(error.localizedDescription)", source: source, code: "expression")
            return
        }

        switch baseCommand {
        case "include":
            guard processingActive else { return }
            let includePath = unquote(value.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !includePath.isEmpty else {
                addError("Include path is empty", source: source, code: "include-path")
                return
            }
            process(file: resolvePath(includePath, currentFile: currentFile, source: source))
        case "device":
            // A Device line inside an inactive If branch must not change the selection.
            guard active else { return }
            let candidates = splitTopLevel(value, separator: ";")
            let metadata = [environment.deviceName, environment.connectionName, environment.deviceUID].joined(separator: " ").lowercased()
            deviceMatches = candidates.contains { candidate in
                let pattern = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return pattern == "all" || splitWhitespace(pattern).allSatisfy { metadata.contains($0) }
            }
        case "channel":
            guard active && deviceMatches && stageMatches else { return }
            let tokens = value.replacingOccurrences(of: ",", with: " ").split { $0 == " " || $0 == "\t" }.map(String.init)
            if tokens.contains(where: { $0.lowercased() == "all" }) {
                selectedChannels = Array(0..<max(1, environment.outputChannelCount))
            } else {
                let indexes = tokens.compactMap { ChannelLayout.index(for: $0, names: environment.channelNames) }
                if indexes.count != tokens.count {
                    addWarning("One or more Channel positions are unknown for this device layout", source: source, code: "channel-layout")
                }
                selectedChannels = indexes
            }
        case "stage":
            guard active && deviceMatches else { return }
            let requested = splitWhitespace(value.lowercased()).map { $0.replacingOccurrences(of: "_", with: "-") }
            let normalizedCurrent = environment.stage.rawValue.lowercased()
            stageMatches = requested.isEmpty || requested.contains(normalizedCurrent)
            if requested.contains(where: { $0 == "pre-mix" || $0 == "capture" }) {
                addWarning("Core Audio taps expose post-mix system output; this stage is preserved but not executed", source: source, code: "unsupported-stage")
            }
        case "eval":
            guard processingActive else { return }
            do {
                _ = try expression.evaluateStatements(expandEnvironmentPlaceholders(value))
            } catch {
                addError("Invalid Eval expression: \(error.localizedDescription)", source: source, code: "expression")
            }
        case "preamp":
            guard processingActive else { return }
            guard let gain = firstNumber(in: value) else {
                addError("Preamp requires a numeric dB value", source: source, code: "preamp")
                return
            }
            add(PreampNode(gainDB: gain), scoped: true)
        case "filter":
            guard processingActive else { return }
            if let node = parseFilter(value, source: source) { add(node, scoped: true) }
        case "delay":
            guard processingActive else { return }
            guard let node = parseDelay(value, source: source) else { return }
            add(node, scoped: true)
        case "copy":
            guard processingActive else { return }
            guard let node = parseCopy(value, source: source) else { return }
            // Equalizer APO's Copy filter requests all channels explicitly;
            // Channel scopes do not narrow its source/output graph.
            add(node, scoped: false)
        case "graphiceq":
            guard processingActive else { return }
            guard let node = parseGraphicEQ(value, source: source) else { return }
            // The node carries its own per-channel filters for the Channel scope.
            add(node, scoped: false)
        case "convolution":
            guard processingActive else { return }
            guard let node = parseConvolution(value, source: source, currentFile: currentFile) else { return }
            add(node, scoped: false)
        case "vstplugin":
            addWarning("VSTPlugin is preserved but not executed in APOMac v1", source: source, code: "unsupported-vst")
        case "loudnesscorrection":
            addWarning("Equalizer APO loudness correction is preserved but not executed in APOMac v1", source: source, code: "unsupported-loudness")
        case "readregstring", "readregdword":
            addError("Windows registry functions have no macOS adapter", source: source, code: "unsupported-registry")
        default:
            addWarning("Unknown command '\(command)' was preserved and ignored", source: source, code: "unknown-command")
        }
    }

    private mutating func parseFilter(_ value: String, source: SourceLine) -> RenderNode? {
        var tokens = splitWhitespace(value.replacingOccurrences(of: ",", with: "."))
        guard !tokens.isEmpty else {
            addError("Filter requires parameters", source: source, code: "filter")
            return nil
        }
        if tokens.first?.lowercased() == "off" { return nil }
        if tokens.first?.lowercased() == "on" { tokens.removeFirst() }
        guard let rawType = tokens.first?.lowercased() else {
            addError("Filter type is missing", source: source, code: "filter")
            return nil
        }

        if rawType == "iir" {
            guard let orderIndex = index(of: "order", in: tokens), orderIndex + 1 < tokens.count,
                  let order = Int(tokens[orderIndex + 1]), order > 0,
                  let coefficientIndex = index(of: "coefficients", in: tokens) else {
                addError("IIR requires Order and Coefficients", source: source, code: "iir")
                return nil
            }
            let coefficients = tokens[(coefficientIndex + 1)...].compactMap(parseNumber)
            guard coefficients.count == (order + 1) * 2 else {
                addError("IIR expected \((order + 1) * 2) coefficients, found \(coefficients.count)", source: source, code: "iir")
                return nil
            }
            return IIRNode(coefficients: coefficients, channelCount: max(1, environment.outputChannelCount))
        }

        let type = rawType
        if type == "none" { return nil }
        let kind: BiquadKind
        switch type {
        case "pk", "peq", "modal": kind = .peaking
        case "lp", "lpq": kind = .lowPass
        case "hp", "hpq": kind = .highPass
        case "bp": kind = .bandPass
        case "no": kind = .notch
        case "ap": kind = .allPass
        case "ls", "lsc": kind = .lowShelf
        case "hs", "hsc": kind = .highShelf
        default:
            addError("Unsupported Filter type '\(rawType)'", source: source, code: "filter-type")
            return nil
        }

        guard let frequency = labeledNumber("fc", in: tokens) else {
            addError("Filter requires Fc", source: source, code: "filter")
            return nil
        }
        let gain = labeledNumber("gain", in: tokens) ?? 0
        let q = labeledNumber("q", in: tokens)
        let bandwidth = labeledNumber("bw", in: tokens) ?? labeledNumberAfterTwoPartLabel("bw", second: "oct", in: tokens)
        var isBandwidthOrS = bandwidth != nil
        var bandwidthOrQOrS = bandwidth ?? q ?? 0
        var isCornerFrequency = false

        if kind == .lowShelf || kind == .highShelf {
            let compactType = type == "ls" || type == "hs"
            let explicitSlope = shelfSlope(type: type, tokens: tokens)
            if let explicitSlope {
                bandwidthOrQOrS = explicitSlope
                isBandwidthOrS = true
            } else if bandwidthOrQOrS == 0 {
                bandwidthOrQOrS = 0.9
                isBandwidthOrS = true
            } else if isBandwidthOrS {
                bandwidthOrQOrS /= 12.0
            }
            isCornerFrequency = compactType
        } else if bandwidthOrQOrS == 0 {
            switch kind {
            case .peaking, .allPass:
                addError("Filter requires Q or BW Oct", source: source, code: "filter")
                return nil
            case .lowPass, .highPass, .bandPass: bandwidthOrQOrS = 1.0 / sqrt(2.0)
            case .notch: bandwidthOrQOrS = 30.0
            case .lowShelf, .highShelf: break
            }
        }

        let actualFrequency = isCornerFrequency ? FilterMath.adjustedCornerFrequency(
            frequency: frequency,
            gainDB: gain,
            bandwidthOrQOrS: bandwidthOrQOrS,
            isBandwidthOrS: isBandwidthOrS,
            kind: kind
        ) : frequency
        let coefficients = FilterMath.coefficients(
            kind: kind,
            gainDB: gain,
            frequency: min(max(actualFrequency, 1.0), environment.sampleRate / 2.0 - 1.0),
            sampleRate: environment.sampleRate,
            bandwidthOrQOrS: max(1.0e-6, bandwidthOrQOrS),
            isBandwidthOrS: isBandwidthOrS
        )
        return BiquadNode(coefficients: coefficients, channelCount: max(1, environment.outputChannelCount))
    }

    private mutating func parseDelay(_ value: String, source: SourceLine) -> RenderNode? {
        let tokens = splitWhitespace(value)
        guard let amount = tokens.first.flatMap(parseNumber), amount >= 0 else {
            addError("Delay requires a non-negative numeric value", source: source, code: "delay")
            return nil
        }
        let unit = tokens.dropFirst().first?.lowercased() ?? "samples"
        let samples: Int
        if unit == "ms" {
            samples = Int((amount * environment.sampleRate / 1000.0).rounded())
        } else if unit == "samples" {
            samples = Int(amount.rounded())
        } else {
            addError("Delay unit must be ms or samples", source: source, code: "delay")
            return nil
        }
        return DelayNode(delaySamples: samples, channelCount: max(1, environment.outputChannelCount))
    }

    private mutating func parseCopy(_ value: String, source: SourceLine) -> RenderNode? {
        var assignments: [CopyAssignment] = []
        for assignmentText in splitWhitespace(value) {
            let parts = assignmentText.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let target = ChannelLayout.index(for: parts[0], names: environment.channelNames) else {
                addError("Invalid Copy assignment '\(assignmentText)'", source: source, code: "copy")
                return nil
            }
            let summands = parts[1].split(separator: "+", omittingEmptySubsequences: false).compactMap { parseSummand(String($0)) }
            guard !summands.isEmpty else {
                addError("Copy assignment '\(assignmentText)' has no source", source: source, code: "copy")
                return nil
            }
            assignments.append(CopyAssignment(targetChannel: target, summands: summands))
        }
        guard !assignments.isEmpty else {
            addError("Copy requires at least one assignment", source: source, code: "copy")
            return nil
        }
        return CopyNode(assignments: assignments, channelCount: max(1, environment.outputChannelCount))
    }

    private func parseSummand(_ text: String) -> CopySummand? {
        let pieces = text.split(separator: "*", maxSplits: 1).map(String.init)
        if pieces.count == 2 {
            guard let factor = factorValue(pieces[0]), let channel = ChannelLayout.index(for: pieces[1], names: environment.channelNames) else { return nil }
            return CopySummand(channel: channel, factor: Float(factor))
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let channel = ChannelLayout.index(for: token, names: environment.channelNames) {
            return CopySummand(channel: channel, factor: 1)
        }
        guard token == "0" || token.contains(".") || token.lowercased().hasSuffix("db"), let constant = factorValue(token) else { return nil }
        return CopySummand(channel: nil, factor: Float(constant))
    }

    private func factorValue(_ token: String) -> Double? {
        let lower = token.lowercased()
        if lower.hasSuffix("db") {
            guard let db = Double(token.dropLast(2)) else { return nil }
            return pow(10.0, db / 20.0)
        }
        return Double(token)
    }

    private mutating func parseGraphicEQ(_ value: String, source: SourceLine) -> RenderNode? {
        let bands = splitTopLevel(value, separator: ";").compactMap { item -> GraphicEQBand? in
            let tokens = splitWhitespace(item)
            guard tokens.count >= 2, let frequency = parseNumber(tokens[0]), let gain = parseNumber(tokens[1]) else { return nil }
            return GraphicEQBand(frequency: frequency, gainDB: gain)
        }
        guard !bands.isEmpty else {
            addError("GraphicEQ requires frequency/gain pairs", source: source, code: "graphiceq")
            return nil
        }
        let impulse = GraphicEQBuilder.impulseResponse(bands: bands, sampleRate: environment.sampleRate)
        let count = max(1, environment.outputChannelCount)
        var filters = [[Float]?](repeating: nil, count: count)
        for channel in selectedChannels where channel >= 0 && channel < count {
            filters[channel] = impulse
        }
        return ConvolutionNode(filters: filters, channelCount: count, displayName: "GraphicEQ" + channelSuffix())
    }

    private mutating func parseConvolution(_ value: String, source: SourceLine, currentFile: URL) -> RenderNode? {
        let path = unquote(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !path.isEmpty else {
            addError("Convolution requires an impulse response file", source: source, code: "convolution")
            return nil
        }
        let url = resolvePath(path, currentFile: currentFile, source: source)
        do {
            let impulse = try ImpulseResponseLoader.load(url: url, targetSampleRate: environment.sampleRate)
            if impulse.wasResampled {
                addWarning("Resampled \(url.lastPathComponent) from \(Int(impulse.sourceSampleRate)) Hz to \(Int(environment.sampleRate)) Hz", source: source, code: "convolution-rate")
            }
            let count = max(1, environment.outputChannelCount)
            var filters = [[Float]?](repeating: nil, count: count)
            for (position, channel) in selectedChannels.enumerated() where channel >= 0 && channel < count {
                filters[channel] = impulse.channels[position % impulse.channels.count]
            }
            return ConvolutionNode(filters: filters, channelCount: count, displayName: "Convolution \(url.lastPathComponent)" + channelSuffix())
        } catch {
            addError("Unable to load convolution impulse response: \(error.localizedDescription)", source: source, code: "convolution")
            return nil
        }
    }

    /// " [L, R]" when a Channel scope narrows processing, otherwise "".
    private func channelSuffix() -> String {
        let all = Array(0..<max(1, environment.outputChannelCount))
        guard selectedChannels != all else { return "" }
        let names = selectedChannels.map { environment.channelNames.indices.contains($0) ? environment.channelNames[$0] : String($0 + 1) }
        return " [\(names.joined(separator: ", "))]"
    }

    private mutating func add(_ node: RenderNode, scoped: Bool) {
        let allChannels = Array(0..<max(1, environment.outputChannelCount))
        if scoped && selectedChannels != allChannels {
            let names = selectedChannels.map { environment.channelNames.indices.contains($0) ? environment.channelNames[$0] : String($0 + 1) }
            nodes.append(ScopedNode(inner: node, selectedChannels: selectedChannels, channelNames: names, channelCount: allChannels.count, maxFrameCount: environment.maxFrameCount))
        } else {
            nodes.append(node)
        }
    }

    private func index(of label: String, in tokens: [String]) -> Int? {
        tokens.firstIndex { $0.lowercased() == label.lowercased() }
    }

    private func labeledNumber(_ label: String, in tokens: [String]) -> Double? {
        guard let index = index(of: label, in: tokens), index + 1 < tokens.count else { return nil }
        return parseNumber(tokens[index + 1])
    }

    private func labeledNumberAfterTwoPartLabel(_ first: String, second: String, in tokens: [String]) -> Double? {
        guard let index = index(of: first, in: tokens), index + 2 < tokens.count,
              tokens[index + 1].lowercased() == second.lowercased() else { return nil }
        return parseNumber(tokens[index + 2])
    }

    private func shelfSlope(type: String, tokens: [String]) -> Double? {
        if let index = tokens.firstIndex(where: { $0.lowercased().hasSuffix("db") }), let value = Double(tokens[index].dropLast(2)) {
            return value / 12.0
        }
        if type == "lsc" || type == "hsc" {
            if let index = tokens.firstIndex(where: { parseNumber($0) != nil }), index < (tokens.firstIndex { $0.lowercased() == "fc" } ?? tokens.count) {
                return parseNumber(tokens[index]).map { $0 / 12.0 }
            }
        }
        return nil
    }

    private func firstNumber(in value: String) -> Double? {
        splitWhitespace(value).compactMap(parseNumber).first
    }

    private func stripComment(_ raw: String) -> String {
        var quoted = false
        for (index, character) in raw.enumerated() {
            if character == "\"" { quoted.toggle() }
            if !quoted && character == "#" { return String(raw.prefix(index)) }
        }
        return raw
    }

    private mutating func expandInlineExpressions(_ raw: String, source: SourceLine) throws -> String {
        var value = raw
        while let start = value.firstIndex(of: "`") {
            guard let end = value[value.index(after: start)...].firstIndex(of: "`") else {
                throw ExpressionError.invalid("unterminated inline expression")
            }
            let expressionText = String(value[value.index(after: start)..<end])
            let evaluated = try expression.evaluate(expandEnvironmentPlaceholders(expressionText)).stringValue
            value.replaceSubrange(start...end, with: evaluated)
        }
        return value
    }

    private func expandEnvironmentPlaceholders(_ text: String) -> String {
        var result = text
        let names = ["sampleRate", "inputChannelCount", "outputChannelCount", "deviceName", "connectionName", "deviceGuid", "stage"]
        for name in names {
            result = result.replacingOccurrences(of: "%\(name)%", with: name)
        }
        return result
    }

    /// Equalizer APO profiles are written on Windows: separators are
    /// backslashes and absolute paths usually point into the APO config
    /// directory. Map those onto the imported profile directory.
    private mutating func resolvePath(_ rawPath: String, currentFile: URL, source: SourceLine) -> URL {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        let baseDirectory = currentFile.deletingLastPathComponent()
        let isWindowsAbsolute = path.count >= 3
            && path[path.startIndex].isLetter
            && path[path.index(after: path.startIndex)] == ":"
        guard isWindowsAbsolute else {
            return URL(fileURLWithPath: path, relativeTo: baseDirectory).standardizedFileURL
        }

        let components = path.dropFirst(2).split(separator: "/").map(String.init)
        let profileDirectory = profileRoot.pathExtension.lowercased() == "txt" ? profileRoot.deletingLastPathComponent() : profileRoot
        var candidates: [URL] = []
        if let configIndex = components.lastIndex(where: { $0.lowercased() == "config" }), configIndex + 1 < components.count {
            candidates.append(components[(configIndex + 1)...].reduce(profileDirectory) { $0.appendingPathComponent($1) })
        }
        if let last = components.last {
            candidates.append(baseDirectory.appendingPathComponent(last))
        }
        let mapped = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates.first ?? baseDirectory
        addWarning("Windows path '\(rawPath)' was mapped to \(mapped.lastPathComponent) in this profile", source: source, code: "windows-path")
        return mapped.standardizedFileURL
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private mutating func addError(_ message: String, source: SourceLine, code: String) {
        diagnostics.append(ConfigurationDiagnostic(severity: .error, file: source.file, line: source.number, message: message, code: code))
    }

    private mutating func addWarning(_ message: String, source: SourceLine, code: String) {
        diagnostics.append(ConfigurationDiagnostic(severity: .warning, file: source.file, line: source.number, message: message, code: code))
    }
}
