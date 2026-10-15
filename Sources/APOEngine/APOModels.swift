import Foundation

public enum APOStage: String, Sendable, Equatable, CaseIterable {
    case preMix = "pre-mix"
    case postMix = "post-mix"
    case capture
}

public struct APOEnvironment: Sendable, Equatable {
    public static let defaultConnectionName = "Core Audio output"

    public let sampleRate: Double
    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let deviceName: String
    public let connectionName: String
    public let deviceUID: String
    public let channelNames: [String]
    public let stage: APOStage
    public let maxFrameCount: Int

    public init(
        sampleRate: Double,
        inputChannelCount: Int,
        outputChannelCount: Int,
        deviceName: String,
        connectionName: String = APOEnvironment.defaultConnectionName,
        deviceUID: String = "",
        channelNames: [String] = [],
        stage: APOStage = .postMix,
        maxFrameCount: Int = 4096
    ) {
        self.sampleRate = sampleRate
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.deviceName = deviceName
        self.connectionName = connectionName
        self.deviceUID = deviceUID
        self.channelNames = channelNames.isEmpty
            ? ChannelLayout.defaultNames(for: max(inputChannelCount, outputChannelCount))
            : channelNames
        self.stage = stage
        self.maxFrameCount = max(1, maxFrameCount)
    }
}

/// Equalizer APO's `Device:` selection. The value lists alternatives
/// separated by ";"; one matches when each of its words occurs in the
/// device's name, connection name or identifier (case-insensitive), or when
/// it is "all".
public enum DeviceSelector {
    public static func matches(
        _ value: String,
        deviceName: String,
        connectionName: String = APOEnvironment.defaultConnectionName,
        deviceUID: String
    ) -> Bool {
        let metadata = [deviceName, connectionName, deviceUID].joined(separator: " ").lowercased()
        return splitTopLevel(value, separator: ";").contains { candidate in
            let pattern = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return pattern == "all" || splitWhitespace(pattern).allSatisfy { metadata.contains($0) }
        }
    }
}

public enum DiagnosticSeverity: String, Sendable, Equatable {
    case warning
    case error
}

public struct ConfigurationDiagnostic: Sendable, Equatable, Identifiable {
    public typealias Severity = DiagnosticSeverity
    public let id: UUID
    public let severity: DiagnosticSeverity
    public let file: URL
    public let line: Int
    public let column: Int?
    public let message: String
    public let code: String?

    public init(
        severity: DiagnosticSeverity,
        file: URL,
        line: Int,
        column: Int? = nil,
        message: String,
        code: String? = nil
    ) {
        self.id = UUID()
        self.severity = severity
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.code = code
    }
}

/// Result's failure type must conform to Error. This collection keeps all
/// diagnostics from one compile pass without throwing away the list shape.
public struct ConfigurationDiagnostics: Error, Sendable, Equatable, RandomAccessCollection, CustomStringConvertible {
    public typealias Index = Int
    private let values: [ConfigurationDiagnostic]

    public init(_ values: [ConfigurationDiagnostic]) {
        self.values = values
    }

    public var diagnostics: [ConfigurationDiagnostic] { values }
    public var startIndex: Int { values.startIndex }
    public var endIndex: Int { values.endIndex }
    public func index(after index: Int) -> Int { values.index(after: index) }
    public func index(before index: Int) -> Int { values.index(before: index) }
    public subscript(position: Int) -> ConfigurationDiagnostic { values[position] }
    public var description: String { values.map(\.message).joined(separator: "\n") }
}

public struct APOCompileOutput: Sendable {
    public let graph: PreparedGraph?
    public let diagnostics: [ConfigurationDiagnostic]

    public init(graph: PreparedGraph?, diagnostics: [ConfigurationDiagnostic]) {
        self.graph = graph
        self.diagnostics = diagnostics
    }

    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

public struct APOFrequencyResponsePoint: Sendable, Equatable {
    public let frequency: Double
    public let magnitudeDB: Double

    public init(frequency: Double, magnitudeDB: Double) {
        self.frequency = frequency
        self.magnitudeDB = magnitudeDB
    }
}

public protocol APOCompiler: Sendable {
    func compile(
        profileRoot: URL,
        environment: APOEnvironment
    ) async -> Result<PreparedGraph, ConfigurationDiagnostics>

    func compile(
        source: String,
        sourceURL: URL,
        environment: APOEnvironment
    ) async -> Result<PreparedGraph, ConfigurationDiagnostics>
}

public enum ChannelLayout {
    public static func defaultNames(for channelCount: Int) -> [String] {
        switch channelCount {
        case 1: return ["C"]
        case 2: return ["L", "R"]
        case 4: return ["L", "R", "RL", "RR"]
        case 6: return ["L", "R", "C", "LFE", "SL", "SR"]
        case 8: return ["L", "R", "C", "LFE", "RL", "RR", "SL", "SR"]
        default: return (1...max(0, channelCount)).map(String.init)
        }
    }

    public static func index(for token: String, names: [String]) -> Int? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized == "ALL" { return nil }
        if let number = Int(normalized), number > 0, number <= names.count {
            return number - 1
        }
        return names.firstIndex { $0.uppercased() == normalized }
    }
}

public struct ProfileManifest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
