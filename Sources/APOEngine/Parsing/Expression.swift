import Foundation

internal enum ExpressionValue: Equatable {
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case string(String)
    case array([ExpressionValue])

    var numberValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        case .boolean(let value): return value ? 1 : 0
        case .string(let value): return Double(value)
        case .array: return nil
        }
    }

    var booleanValue: Bool {
        switch self {
        case .boolean(let value): return value
        case .number(let value): return value != 0
        case .integer(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        }
    }

    var stringValue: String {
        switch self {
        case .number(let value): return String(value)
        case .integer(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .string(let value): return value
        case .array(let value): return "{" + value.map(\.stringValue).joined(separator: ",") + "}"
        }
    }
}

internal struct ExpressionContext {
    var values: [String: ExpressionValue] = [:]
    var diagnostics: [String] = []

    init(environment: APOEnvironment) {
        values = [
            "e": .number(exp(1.0)),
            "pi": .number(Double.pi),
            "inputChannelCount": .integer(environment.inputChannelCount),
            "outputChannelCount": .integer(environment.outputChannelCount),
            "sampleRate": .number(environment.sampleRate),
            "deviceName": .string(environment.deviceName),
            "connectionName": .string(environment.connectionName),
            "deviceGuid": .string(environment.deviceUID),
            "stage": .string(environment.stage.rawValue)
        ]
    }
}

private enum ExpressionToken: Equatable {
    case number(Double)
    case identifier(String)
    case string(String)
    case symbol(String)
    case end
}

private struct ExpressionLexer {
    let input: Array<Character>
    var index = 0

    init(_ input: String) { self.input = Array(input) }

    mutating func tokenize() throws -> [ExpressionToken] {
        var result: [ExpressionToken] = []
        while index < input.count {
            let character = input[index]
            if character.isWhitespace { index += 1; continue }
            if character == "\"" {
                result.append(.string(try readString()))
                continue
            }
            if character.isNumber || character == "." {
                result.append(.number(try readNumber()))
                continue
            }
            if character.isLetter || character == "_" {
                let start = index
                index += 1
                while index < input.count && (input[index].isLetter || input[index].isNumber || input[index] == "_") {
                    index += 1
                }
                let identifier = String(input[start..<index])
                switch identifier.lowercased() {
                case "and", "or", "xor": result.append(.symbol(identifier.lowercased()))
                default: result.append(.identifier(identifier))
                }
                continue
            }

            let twoCharacter = index + 1 < input.count ? String(input[index...index + 1]) : ""
            if ["==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "<<", ">>"].contains(twoCharacter) {
                result.append(.symbol(twoCharacter))
                index += 2
            } else {
                result.append(.symbol(String(character)))
                index += 1
            }
        }
        result.append(.end)
        return result
    }

    private mutating func readString() throws -> String {
        index += 1
        var value = ""
        while index < input.count {
            let character = input[index]
            index += 1
            if character == "\"" { return value }
            if character == "\\" {
                guard index < input.count else { throw ExpressionError.invalid("unterminated escape") }
                let escaped = input[index]
                index += 1
                switch escaped {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                default: value.append(escaped)
                }
            } else {
                value.append(character)
            }
        }
        throw ExpressionError.invalid("unterminated string")
    }

    private mutating func readNumber() throws -> Double {
        let start = index
        while index < input.count && (input[index].isNumber || input[index] == "." || input[index] == "e" || input[index] == "E" || input[index] == "+" || input[index] == "-") {
            if (input[index] == "+" || input[index] == "-") && index > start && input[index - 1] != "e" && input[index - 1] != "E" { break }
            index += 1
        }
        let token = String(input[start..<index])
        guard let value = Double(token) else { throw ExpressionError.invalid("invalid number \(token)") }
        return value
    }
}

internal enum ExpressionError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

internal struct ExpressionEvaluator {
    var context: ExpressionContext
    private var tokens: [ExpressionToken] = []
    private var index = 0

    init(context: ExpressionContext) {
        self.context = context
    }

    mutating func evaluate(_ text: String) throws -> ExpressionValue {
        var lexer = ExpressionLexer(text)
        tokens = try lexer.tokenize()
        index = 0
        let value = try parseExpression(minimumPrecedence: 0)
        if case .end = current { return value }
        throw ExpressionError.invalid("unexpected token in expression")
    }

    mutating func evaluateStatements(_ text: String) throws -> ExpressionValue {
        let statements = splitTopLevel(text, separator: ";")
        var result: ExpressionValue = .boolean(false)
        for statement in statements where !statement.isEmpty {
            if let assignment = assignmentParts(statement) {
                let rhs = try evaluate(assignment.rhs)
                let value: ExpressionValue
                if assignment.operator == "=" {
                    value = rhs
                } else {
                    guard let old = context.values[assignment.name], let lhs = old.numberValue, let number = rhs.numberValue else {
                        throw ExpressionError.invalid("compound assignment requires numeric values")
                    }
                    switch assignment.operator {
                    case "+=": value = .number(lhs + number)
                    case "-=": value = .number(lhs - number)
                    case "*=": value = .number(lhs * number)
                    case "/=": value = .number(number == 0 ? 0 : lhs / number)
                    default: throw ExpressionError.invalid("unsupported assignment")
                    }
                }
                context.values[assignment.name] = value
                result = value
            } else {
                result = try evaluate(statement)
            }
        }
        return result
    }

    private func assignmentParts(_ statement: String) -> (name: String, operator: String, rhs: String)? {
        let characters = Array(statement)
        var quoted = false
        var depth = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" { quoted.toggle(); index += 1; continue }
            if !quoted {
                if character == "(" || character == "[" || character == "{" { depth += 1 }
                if character == ")" || character == "]" || character == "}" { depth -= 1 }
                if depth == 0 && character == "=" {
                    if index + 1 < characters.count && characters[index + 1] == "=" { index += 2; continue }
                    if index > 0 && ["!", "<", ">", "="].contains(characters[index - 1]) { index += 1; continue }
                    var operatorIndex = index - 1
                    while operatorIndex >= 0 && characters[operatorIndex].isWhitespace { operatorIndex -= 1 }
                    let hasCompoundOperator = operatorIndex >= 0 && ["+", "-", "*", "/"].contains(characters[operatorIndex])
                    let op = hasCompoundOperator ? String(characters[operatorIndex]) + "=" : "="
                    let lhsEnd = hasCompoundOperator ? operatorIndex : index
                    let name = String(characters[..<lhsEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let rhsStart = index + 1
                    guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), let first = name.first, first.isLetter || first == "_" else { return nil }
                    return (name, op, String(characters[rhsStart...]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            index += 1
        }
        return nil
    }

    private var current: ExpressionToken { tokens[index] }

    private mutating func advance() {
        if index < tokens.count - 1 { index += 1 }
    }

    private mutating func parseExpression(minimumPrecedence: Int) throws -> ExpressionValue {
        var left = try parsePrefix()
        while case .symbol(let symbol) = current, let precedence = precedence(of: symbol), precedence >= minimumPrecedence {
            advance()
            if symbol == "?" {
                let thenValue = try parseExpression(minimumPrecedence: 0)
                guard case .symbol(":") = current else { throw ExpressionError.invalid("expected ':'") }
                advance()
                let elseValue = try parseExpression(minimumPrecedence: precedence)
                left = left.booleanValue ? thenValue : elseValue
                continue
            }
            let right = try parseExpression(minimumPrecedence: precedence + (isRightAssociative(symbol) ? 0 : 1))
            left = try apply(symbol: symbol, left: left, right: right)
        }
        return left
    }

    private mutating func parsePrefix() throws -> ExpressionValue {
        switch current {
        case .number(let value): advance(); return .number(value)
        case .string(let value): advance(); return .string(value)
        case .identifier(let name):
            advance()
            if name.lowercased() == "true" { return .boolean(true) }
            if name.lowercased() == "false" { return .boolean(false) }
            let value: ExpressionValue
            if case .symbol("(") = current {
                advance()
                var arguments: [ExpressionValue] = []
                if case .symbol(")") = current {
                    advance()
                } else {
                    while true {
                        arguments.append(try parseExpression(minimumPrecedence: 0))
                        if case .symbol(",") = current { advance(); continue }
                        guard case .symbol(")") = current else { throw ExpressionError.invalid("expected ')' in function call") }
                        advance()
                        break
                    }
                }
                value = try function(name: name, arguments: arguments)
            } else if let contextValue = context.values[name] {
                value = contextValue
            } else if let contextValue = context.values[name.lowercased()] {
                value = contextValue
            } else {
                throw ExpressionError.invalid("unknown identifier \(name)")
            }
            return try parseSubscripts(value)
        case .symbol("-"):
            advance()
            guard let value = try parsePrefix().numberValue else { throw ExpressionError.invalid("unary '-' requires a number") }
            return .number(-value)
        case .symbol("+"):
            advance(); return try parsePrefix()
        case .symbol("!"):
            advance(); return .boolean(!(try parsePrefix()).booleanValue)
        case .symbol("("):
            advance()
            if case .identifier(let castName) = current,
               castName.lowercased() == "float" || castName.lowercased() == "int" {
                advance()
                guard case .symbol(")") = current else { throw ExpressionError.invalid("expected ')' after type conversion") }
                advance()
                let converted = try parsePrefix()
                guard let number = converted.numberValue else { throw ExpressionError.invalid("type conversion requires a number") }
                return castName.lowercased() == "int" ? .integer(Int(number.rounded())) : .number(number)
            }
            let value = try parseExpression(minimumPrecedence: 0)
            guard case .symbol(")") = current else { throw ExpressionError.invalid("expected ')'") }
            advance()
            return try parseSubscripts(value)
        case .symbol("{"):
            advance()
            var values: [ExpressionValue] = []
            if case .symbol("}") = current {
                advance()
                return .array(values)
            }
            while true {
                values.append(try parseExpression(minimumPrecedence: 0))
                if case .symbol(",") = current { advance(); continue }
                guard case .symbol("}") = current else { throw ExpressionError.invalid("expected '}'") }
                advance()
                break
            }
            return .array(values)
        default:
            throw ExpressionError.invalid("expected expression")
        }
    }

    private mutating func parseSubscripts(_ initialValue: ExpressionValue) throws -> ExpressionValue {
        var value = initialValue
        while case .symbol("[") = current {
            advance()
            let indexValue = try parseExpression(minimumPrecedence: 0)
            guard case .symbol("]") = current else { throw ExpressionError.invalid("expected ']'") }
            advance()
            guard case .array(let values) = value, let number = indexValue.numberValue else {
                throw ExpressionError.invalid("array access requires an array and integer index")
            }
            let index = Int(number.rounded())
            guard values.indices.contains(index) else { throw ExpressionError.invalid("array index out of range") }
            value = values[index]
        }
        return value
    }

    private func precedence(of symbol: String) -> Int? {
        switch symbol {
        case "=", "+=", "-=", "*=", "/=": return 1
        case "?": return 2
        case "or": return 3
        case "xor": return 4
        case "and": return 5
        case "|": return 6
        case "&": return 7
        case "<<", ">>": return 8
        case "==", "!=", "<", ">", "<=", ">=": return 9
        case "+", "-": return 10
        case "*", "/": return 11
        case "^": return 12
        default: return nil
        }
    }

    private func isRightAssociative(_ symbol: String) -> Bool { symbol == "^" || symbol == "=" }

    private mutating func apply(symbol: String, left: ExpressionValue, right: ExpressionValue) throws -> ExpressionValue {
        if ["=", "+=", "-=", "*=", "/="].contains(symbol) {
            guard case .identifier = tokens[max(0, index - 1)] else {
                throw ExpressionError.invalid("assignment requires a variable")
            }
        }
        if symbol == "+", case .string = left { return .string(left.stringValue + right.stringValue) }
        if symbol == "+", case .string = right { return .string(left.stringValue + right.stringValue) }
        if symbol == "and" { return .boolean(left.booleanValue && right.booleanValue) }
        if symbol == "or" { return .boolean(left.booleanValue || right.booleanValue) }
        if symbol == "xor" { return .boolean(left.booleanValue != right.booleanValue) }
        if ["&", "|", "<<", ">>"].contains(symbol) {
            guard let lhs = left.numberValue, let rhs = right.numberValue else {
                throw ExpressionError.invalid("operator \(symbol) requires integer values")
            }
            let leftInteger = Int(lhs.rounded())
            let rightInteger = Int(rhs.rounded())
            switch symbol {
            case "&": return .integer(leftInteger & rightInteger)
            case "|": return .integer(leftInteger | rightInteger)
            case "<<": return .integer(leftInteger << max(0, rightInteger))
            case ">>": return .integer(leftInteger >> max(0, rightInteger))
            default: break
            }
        }
        guard let lhs = left.numberValue, let rhs = right.numberValue else {
            switch symbol {
            case "==": return .boolean(left == right)
            case "!=": return .boolean(left != right)
            default: throw ExpressionError.invalid("operator \(symbol) requires numeric values")
            }
        }
        switch symbol {
        case "+": return .number(lhs + rhs)
        case "-": return .number(lhs - rhs)
        case "*": return .number(lhs * rhs)
        case "/": return .number(rhs == 0 ? 0 : lhs / rhs)
        case "^": return .number(pow(lhs, rhs))
        case "==": return .boolean(lhs == rhs)
        case "!=": return .boolean(lhs != rhs)
        case "<": return .boolean(lhs < rhs)
        case ">": return .boolean(lhs > rhs)
        case "<=": return .boolean(lhs <= rhs)
        case ">=": return .boolean(lhs >= rhs)
        default: throw ExpressionError.invalid("unsupported operator \(symbol)")
        }
    }

    private func function(name: String, arguments: [ExpressionValue]) throws -> ExpressionValue {
        let lower = name.lowercased()
        func oneNumber() throws -> Double {
            guard arguments.count == 1, let value = arguments[0].numberValue else { throw ExpressionError.invalid("\(name) expects one number") }
            return value
        }
        switch lower {
        case "abs": return .number(abs(try oneNumber()))
        case "sin": return .number(sin(try oneNumber()))
        case "cos": return .number(cos(try oneNumber()))
        case "tan": return .number(tan(try oneNumber()))
        case "sinh": return .number(sinh(try oneNumber()))
        case "cosh": return .number(cosh(try oneNumber()))
        case "tanh": return .number(tanh(try oneNumber()))
        case "ln": return .number(log(try oneNumber()))
        case "log": return .number(log(try oneNumber()))
        case "log10": return .number(log10(try oneNumber()))
        case "exp": return .number(exp(try oneNumber()))
        case "sqrt": return .number(sqrt(try oneNumber()))
        case "min": return .number(arguments.compactMap(\.numberValue).min() ?? 0)
        case "max": return .number(arguments.compactMap(\.numberValue).max() ?? 0)
        case "sum": return .number(arguments.compactMap(\.numberValue).reduce(0, +))
        case "str2dbl":
            guard arguments.count == 1, let value = Double(arguments[0].stringValue) else { throw ExpressionError.invalid("str2dbl expects a numeric string") }
            return .number(value)
        case "strlen":
            guard arguments.count == 1 else { throw ExpressionError.invalid("strlen expects one string") }
            return .integer(arguments[0].stringValue.count)
        case "tolower": return .string(arguments.first?.stringValue.lowercased() ?? "")
        case "toupper": return .string(arguments.first?.stringValue.uppercased() ?? "")
        case "sizeof":
            guard let value = arguments.first else { return .integer(0) }
            if case .array(let values) = value { return .integer(values.count) }
            return .integer(value.stringValue.count)
        case "regexsearch":
            guard arguments.count == 2 else { throw ExpressionError.invalid("regexSearch expects pattern and string") }
            let regex = try NSRegularExpression(pattern: arguments[0].stringValue)
            let source = arguments[1].stringValue
            guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return .array([]) }
            var values: [ExpressionValue] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                if let swiftRange = Range(range, in: source) { values.append(.string(String(source[swiftRange]))) }
            }
            return .array(values)
        case "regexreplace":
            guard arguments.count == 3 else { throw ExpressionError.invalid("regexReplace expects pattern, string, replacement") }
            let regex = try NSRegularExpression(pattern: arguments[0].stringValue)
            let range = NSRange(arguments[1].stringValue.startIndex..., in: arguments[1].stringValue)
            return .string(regex.stringByReplacingMatches(in: arguments[1].stringValue, range: range, withTemplate: arguments[2].stringValue))
        case "readregstring", "readregdword":
            throw ExpressionError.invalid("\(name) is Windows-only and has no macOS registry adapter")
        default:
            throw ExpressionError.invalid("unknown function \(name)")
        }
    }
}
