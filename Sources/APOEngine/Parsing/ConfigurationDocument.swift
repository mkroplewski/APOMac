import Foundation

public struct APOConfigurationLine: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let file: URL
    public let lineNumber: Int
    public let rawText: String
    public let command: String?
    public let value: String?

    public init(file: URL, lineNumber: Int, rawText: String) {
        self.id = UUID()
        self.file = file
        self.lineNumber = lineNumber
        self.rawText = rawText
        if let separator = rawText.firstIndex(of: ":") {
            self.command = rawText[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            self.value = rawText[rawText.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.command = nil
            self.value = nil
        }
    }
}

public enum APOConfigurationNode: Sendable, Equatable {
    case blank(APOConfigurationLine)
    case comment(APOConfigurationLine)
    case command(APOConfigurationLine)
}

public struct APOConfigurationFile: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let url: URL
    public let lines: [APOConfigurationLine]

    public var nodes: [APOConfigurationNode] {
        lines.map { line in
            let trimmed = line.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .blank(line) }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { return .comment(line) }
            return .command(line)
        }
    }

    public init(url: URL, text: String) {
        self.id = UUID()
        self.url = url
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        self.lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
            APOConfigurationLine(file: url, lineNumber: $0.offset + 1, rawText: String($0.element))
        }
    }
}

public enum ConfigurationFileError: Error, LocalizedError {
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Unable to read configuration file \(url.path)"
        }
    }
}

public enum ConfigurationParser {
    public static func read(url: URL) throws -> APOConfigurationFile {
        guard let data = try? Data(contentsOf: url) else {
            throw ConfigurationFileError.unreadable(url)
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        return APOConfigurationFile(url: url, text: text)
    }
}

/// Public parser entry point. APOConfigurationFile is intentionally source
/// preserving: every line retains its original file, line number and raw
/// text so unsupported commands can be edited and diagnosed without loss.
public struct APOConfigurationParser: Sendable {
    public init() {}

    public func parse(url: URL) throws -> APOConfigurationFile {
        try ConfigurationParser.read(url: url)
    }

    public static func read(url: URL) throws -> APOConfigurationFile {
        try ConfigurationParser.read(url: url)
    }
}

internal struct SourceLine {
    let file: URL
    let number: Int
    let raw: String
    let command: String?
    let value: String?

    init(_ line: APOConfigurationLine) {
        file = line.file
        number = line.lineNumber
        raw = line.rawText
        command = line.command
        value = line.value
    }
}

internal enum CommandName {
    static let supported = Set([
        "PREAMP", "FILTER", "DELAY", "COPY", "GRAPHICEQ", "CONVOLUTION",
        "INCLUDE", "DEVICE", "CHANNEL", "STAGE", "IF", "ELSEIF", "ELSE",
        "ENDIF", "EVAL", "VSTPLUGIN", "LOUDNESSCORRECTION"
    ])
}

internal func splitWhitespace(_ value: String) -> [String] {
    value.split { $0 == " " || $0 == "\t" }.map(String.init)
}

internal func parseNumber(_ token: String) -> Double? {
    let normalized = token.replacingOccurrences(of: ",", with: ".")
    return Double(normalized)
}

internal func splitTopLevel(_ text: String, separator: Character) -> [String] {
    var result: [String] = []
    var current = ""
    var depth = 0
    var quoted = false
    var escaped = false
    for character in text {
        if escaped {
            current.append(character)
            escaped = false
            continue
        }
        if character == "\\" && quoted {
            current.append(character)
            escaped = true
            continue
        }
        if character == "\"" {
            quoted.toggle()
            current.append(character)
            continue
        }
        if !quoted {
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
        }
        if character == separator && !quoted && depth == 0 {
            result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        } else {
            current.append(character)
        }
    }
    result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
    return result
}
