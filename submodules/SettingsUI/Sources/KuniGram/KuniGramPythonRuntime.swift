import Foundation
import CryptoKit

public enum KuniPyValue {
    case none
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case list([KuniPyValue])
    case dict([String: KuniPyValue])
    case function(KuniPyCallable)
    case nativeFunction(([KuniPyValue], [String: KuniPyValue]) throws -> KuniPyValue)
    case object([String: KuniPyValue])

    public var isTruthy: Bool {
        switch self {
        case .none:
            return false
        case let .bool(v):
            return v
        case let .int(v):
            return v != 0
        case let .double(v):
            return v != 0.0
        case let .string(v):
            return !v.isEmpty
        case let .list(v):
            return !v.isEmpty
        case let .dict(v):
            return !v.isEmpty
        case .function, .nativeFunction, .object:
            return true
        }
    }

    public var stringValue: String {
        switch self {
        case .none:
            return "None"
        case let .bool(v):
            return v ? "True" : "False"
        case let .int(v):
            return String(v)
        case let .double(v):
            return String(v)
        case let .string(v):
            return v
        case let .list(v):
            return "[" + v.map { $0.reprValue }.joined(separator: ", ") + "]"
        case let .dict(v):
            let pairs = v.map { "\"\($0.key)\": \($0.value.reprValue)" }.joined(separator: ", ")
            return "{\(pairs)}"
        case .function:
            return "<function>"
        case .nativeFunction:
            return "<built-in function>"
        case .object:
            return "<object>"
        }
    }

    public var reprValue: String {
        switch self {
        case let .string(v):
            return "\"\(v)\""
        default:
            return self.stringValue
        }
    }

    public var intValue: Int64? {
        switch self {
        case let .int(v):
            return v
        case let .double(v):
            return Int64(v)
        case let .bool(v):
            return v ? 1 : 0
        case let .string(v):
            return Int64(v)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .double(v):
            return v
        case let .int(v):
            return Double(v)
        case let .bool(v):
            return v ? 1.0 : 0.0
        case let .string(v):
            return Double(v)
        default:
            return nil
        }
    }

    public func toJSONObject() -> Any {
        switch self {
        case .none:
            return NSNull()
        case let .bool(v):
            return v
        case let .int(v):
            return v
        case let .double(v):
            return v
        case let .string(v):
            return v
        case let .list(v):
            return v.map { $0.toJSONObject() }
        case let .dict(v):
            var result: [String: Any] = [:]
            for (k, val) in v {
                result[k] = val.toJSONObject()
            }
            return result
        case .function, .nativeFunction, .object:
            return self.stringValue
        }
    }

    public static func fromJSONObject(_ obj: Any?) -> KuniPyValue {
        guard let obj = obj, !(obj is NSNull) else {
            return .none
        }
        if let b = obj as? Bool {
            // Note: NSNumber(1) can bridge as Bool/Int; check CFBooleanGetTypeID if NSNumber
            if let num = obj as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                return .int(num.int64Value)
            }
            return .bool(b)
        }
        if let i = obj as? Int64 {
            return .int(i)
        }
        if let i = obj as? Int {
            return .int(Int64(i))
        }
        if let d = obj as? Double {
            return .double(d)
        }
        if let s = obj as? String {
            return .string(s)
        }
        if let arr = obj as? [Any] {
            return .list(arr.map { fromJSONObject($0) })
        }
        if let dict = obj as? [String: Any] {
            var res: [String: KuniPyValue] = [:]
            for (k, v) in dict {
                res[k] = fromJSONObject(v)
            }
            return .dict(res)
        }
        return .string(String(describing: obj))
    }
}

public final class KuniPyCallable {
    public let name: String
    public let params: [String]
    public let defaults: [String: KuniPyExpr]
    public let body: [KuniPyStmt]
    public weak var closureEnv: KuniPyEnv?

    public init(name: String, params: [String], defaults: [String: KuniPyExpr], body: [KuniPyStmt], closureEnv: KuniPyEnv?) {
        self.name = name
        self.params = params
        self.defaults = defaults
        self.body = body
        self.closureEnv = closureEnv
    }
}

public enum KuniPyError: Error, LocalizedError {
    case syntax(String, Int)
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case let .syntax(msg, line):
            return "SyntaxError (line \(line)): \(msg)"
        case let .runtime(msg):
            return "RuntimeError: \(msg)"
        }
    }
}

public final class KuniPyEnv {
    private var vars: [String: KuniPyValue] = [:]
    public let parent: KuniPyEnv?

    public init(parent: KuniPyEnv? = nil) {
        self.parent = parent
    }

    public func get(_ name: String) -> KuniPyValue? {
        if let val = self.vars[name] {
            return val
        }
        return self.parent?.get(name)
    }

    public func set(_ name: String, _ value: KuniPyValue) {
        self.vars[name] = value
    }

    public func assign(_ name: String, _ value: KuniPyValue) {
        if self.vars[name] != nil {
            self.vars[name] = value
        } else if let parent = self.parent, parent.exists(name) {
            parent.assign(name, value)
        } else {
            self.vars[name] = value
        }
    }

    public func exists(_ name: String) -> Bool {
        if self.vars[name] != nil {
            return true
        }
        return self.parent?.exists(name) ?? false
    }
}

// MARK: - Lexer

private enum KuniPyTokenKind: Equatable {
    case ident(String)
    case int(Int64)
    case double(Double)
    case string(String)
    case fstring(String)
    case kwDef, kwReturn, kwIf, kwElif, kwElse, kwFor, kwIn, kwWhile
    case kwBreak, kwContinue, kwPass, kwTrue, kwFalse, kwNone
    case kwAnd, kwOr, kwNot, kwImport, kwFrom, kwAs, kwTry, kwExcept, kwRaise
    case plus, minus, star, slash, doubleSlash, percent, doubleStar
    case eq, eqEq, notEq, lt, lte, gt, gte
    case plusEq, minusEq, starEq, slashEq
    case lparen, rparen, lbracket, rbracket, lbrace, rbrace
    case comma, colon, dot
    case newline, indent, dedent, eof
}

private struct KuniPyToken {
    let kind: KuniPyTokenKind
    let line: Int
}

private func tokenizePython(_ source: String) throws -> [KuniPyToken] {
    var tokens: [KuniPyToken] = []
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var indentStack: [Int] = [0]
    var parenDepth = 0

    let keywords: [String: KuniPyTokenKind] = [
        "def": .kwDef, "return": .kwReturn, "if": .kwIf, "elif": .kwElif, "else": .kwElse,
        "for": .kwFor, "in": .kwIn, "while": .kwWhile, "break": .kwBreak, "continue": .kwContinue,
        "pass": .kwPass, "True": .kwTrue, "False": .kwFalse, "None": .kwNone,
        "and": .kwAnd, "or": .kwOr, "not": .kwNot, "import": .kwImport, "from": .kwFrom,
        "as": .kwAs, "try": .kwTry, "except": .kwExcept, "raise": .kwRaise
    ]

    var lineIndex = 0
    while lineIndex < lines.count {
        let rawLine = lines[lineIndex]
        let lineNum = lineIndex + 1
        lineIndex += 1

        let chars = Array(rawLine)
        var i = 0
        var spaces = 0
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") {
            spaces += (chars[i] == "\t") ? 4 : 1
            i += 1
        }

        if i >= chars.count || chars[i] == "#" {
            continue
        }

        if parenDepth == 0 {
            let currentIndent = indentStack.last ?? 0
            if spaces > currentIndent {
                indentStack.append(spaces)
                tokens.append(KuniPyToken(kind: .indent, line: lineNum))
            } else if spaces < currentIndent {
                while let top = indentStack.last, top > spaces {
                    indentStack.removeLast()
                    tokens.append(KuniPyToken(kind: .dedent, line: lineNum))
                }
            }
        }

        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" {
                i += 1
                continue
            }
            if c == "#" {
                break
            }

            // f-string or string
            let isFString = (c == "f" || c == "F") && i + 1 < chars.count && (chars[i + 1] == "\"" || chars[i + 1] == "'")
            if isFString || c == "\"" || c == "'" {
                if isFString { i += 1 }
                let quote = chars[i]
                var isTriple = false
                if i + 2 < chars.count && chars[i + 1] == quote && chars[i + 2] == quote {
                    isTriple = true
                    i += 3
                } else {
                    i += 1
                }

                var str = ""
                if isTriple {
                    var closed = false
                    while !closed {
                        while i < chars.count {
                            if i + 2 < chars.count && chars[i] == quote && chars[i + 1] == quote && chars[i + 2] == quote {
                                i += 3
                                closed = true
                                break
                            }
                            str.append(chars[i])
                            i += 1
                        }
                        if !closed {
                            if lineIndex < lines.count {
                                str.append("\n")
                                let nextChars = Array(lines[lineIndex])
                                lineIndex += 1
                                i = 0
                                // replace chars reference by continuing via nested loop
                                var subClosed = false
                                var j = 0
                                while j < nextChars.count {
                                    if j + 2 < nextChars.count && nextChars[j] == quote && nextChars[j + 1] == quote && nextChars[j + 2] == quote {
                                        j += 3
                                        subClosed = true
                                        break
                                    }
                                    str.append(nextChars[j])
                                    j += 1
                                }
                                if subClosed {
                                    // Remainder of that line is ignored or handled cleanly
                                    closed = true
                                    i = chars.count
                                }
                            } else {
                                break
                            }
                        }
                    }
                } else {
                    while i < chars.count && chars[i] != quote {
                        if chars[i] == "\\" && i + 1 < chars.count {
                            i += 1
                            switch chars[i] {
                            case "n": str.append("\n")
                            case "t": str.append("\t")
                            case "r": str.append("\r")
                            case "\\": str.append("\\")
                            case "\"": str.append("\"")
                            case "'": str.append("'")
                            default: str.append(chars[i])
                            }
                        } else {
                            str.append(chars[i])
                        }
                        i += 1
                    }
                    if i < chars.count && chars[i] == quote {
                        i += 1
                    }
                }

                tokens.append(KuniPyToken(kind: isFString ? .fstring(str) : .string(str), line: lineNum))
                continue
            }

            // Number
            if c.isNumber {
                var numStr = ""
                var isDouble = false
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") {
                    if chars[i] == "." {
                        if isDouble { break }
                        isDouble = true
                    }
                    numStr.append(chars[i])
                    i += 1
                }
                if isDouble, let d = Double(numStr) {
                    tokens.append(KuniPyToken(kind: .double(d), line: lineNum))
                } else if let n = Int64(numStr) {
                    tokens.append(KuniPyToken(kind: .int(n), line: lineNum))
                }
                continue
            }

            // Identifier / keyword
            if c.isLetter || c == "_" {
                var id = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    id.append(chars[i])
                    i += 1
                }
                if let kw = keywords[id] {
                    tokens.append(KuniPyToken(kind: kw, line: lineNum))
                } else {
                    tokens.append(KuniPyToken(kind: .ident(id), line: lineNum))
                }
                continue
            }

            // Two-char operators
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
            switch (c, next) {
            case ("=", "="): tokens.append(KuniPyToken(kind: .eqEq, line: lineNum)); i += 2; continue
            case ("!", "="): tokens.append(KuniPyToken(kind: .notEq, line: lineNum)); i += 2; continue
            case ("<", "="): tokens.append(KuniPyToken(kind: .lte, line: lineNum)); i += 2; continue
            case (">", "="): tokens.append(KuniPyToken(kind: .gte, line: lineNum)); i += 2; continue
            case ("+", "="): tokens.append(KuniPyToken(kind: .plusEq, line: lineNum)); i += 2; continue
            case ("-", "="): tokens.append(KuniPyToken(kind: .minusEq, line: lineNum)); i += 2; continue
            case ("*", "="): tokens.append(KuniPyToken(kind: .starEq, line: lineNum)); i += 2; continue
            case ("/", "="): tokens.append(KuniPyToken(kind: .slashEq, line: lineNum)); i += 2; continue
            case ("/", "/"): tokens.append(KuniPyToken(kind: .doubleSlash, line: lineNum)); i += 2; continue
            case ("*", "*"): tokens.append(KuniPyToken(kind: .doubleStar, line: lineNum)); i += 2; continue
            default: break
            }

            // Single-char operators & punctuation
            i += 1
            switch c {
            case "+": tokens.append(KuniPyToken(kind: .plus, line: lineNum))
            case "-": tokens.append(KuniPyToken(kind: .minus, line: lineNum))
            case "*": tokens.append(KuniPyToken(kind: .star, line: lineNum))
            case "/": tokens.append(KuniPyToken(kind: .slash, line: lineNum))
            case "%": tokens.append(KuniPyToken(kind: .percent, line: lineNum))
            case "=": tokens.append(KuniPyToken(kind: .eq, line: lineNum))
            case "<": tokens.append(KuniPyToken(kind: .lt, line: lineNum))
            case ">": tokens.append(KuniPyToken(kind: .gt, line: lineNum))
            case "(": parenDepth += 1; tokens.append(KuniPyToken(kind: .lparen, line: lineNum))
            case ")": parenDepth = max(0, parenDepth - 1); tokens.append(KuniPyToken(kind: .rparen, line: lineNum))
            case "[": parenDepth += 1; tokens.append(KuniPyToken(kind: .lbracket, line: lineNum))
            case "]": parenDepth = max(0, parenDepth - 1); tokens.append(KuniPyToken(kind: .rbracket, line: lineNum))
            case "{": parenDepth += 1; tokens.append(KuniPyToken(kind: .lbrace, line: lineNum))
            case "}": parenDepth = max(0, parenDepth - 1); tokens.append(KuniPyToken(kind: .rbrace, line: lineNum))
            case ",": tokens.append(KuniPyToken(kind: .comma, line: lineNum))
            case ":": tokens.append(KuniPyToken(kind: .colon, line: lineNum))
            case ".": tokens.append(KuniPyToken(kind: .dot, line: lineNum))
            default: break
            }
        }

        if parenDepth == 0 {
            tokens.append(KuniPyToken(kind: .newline, line: lineNum))
        }
    }

    while indentStack.count > 1 {
        indentStack.removeLast()
        tokens.append(KuniPyToken(kind: .dedent, line: lines.count))
    }
    tokens.append(KuniPyToken(kind: .eof, line: lines.count))
    return tokens
}

// MARK: - AST

public indirect enum KuniPyExpr {
    case literal(KuniPyValue)
    case fstring(String)
    case ident(String)
    case list([KuniPyExpr])
    case dict([(KuniPyExpr, KuniPyExpr)])
    case unary(String, KuniPyExpr)
    case binary(String, KuniPyExpr, KuniPyExpr)
    case attr(KuniPyExpr, String)
    case index(KuniPyExpr, KuniPyExpr)
    case call(KuniPyExpr, [KuniPyExpr], [(String, KuniPyExpr)])
}

public indirect enum KuniPyStmt {
    case expr(KuniPyExpr)
    case assign(KuniPyExpr, KuniPyExpr)
    case augAssign(KuniPyExpr, String, KuniPyExpr)
    case defFunc(String, [String], [String: KuniPyExpr], [KuniPyStmt])
    case returnStmt(KuniPyExpr?)
    case ifStmt([(KuniPyExpr, [KuniPyStmt])], [KuniPyStmt]?)
    case forStmt(String, KuniPyExpr, [KuniPyStmt])
    case whileStmt(KuniPyExpr, [KuniPyStmt])
    case tryStmt([KuniPyStmt], String?, [KuniPyStmt])
    case importStmt(String, String?)
    case fromImportStmt(String, [(String, String?)])
    case breakStmt
    case continueStmt
    case passStmt
}

private final class KuniPyParser {
    private let tokens: [KuniPyToken]
    private var pos = 0

    init(tokens: [KuniPyToken]) {
        self.tokens = tokens
    }

    private var current: KuniPyToken {
        return self.pos < self.tokens.count ? self.tokens[self.pos] : KuniPyToken(kind: .eof, line: 0)
    }

    private func advance() -> KuniPyToken {
        let t = self.current
        self.pos += 1
        return t
    }

    private func skipNewlines() {
        while self.current.kind == .newline {
            self.pos += 1
        }
    }

    func parseProgram() throws -> [KuniPyStmt] {
        var stmts: [KuniPyStmt] = []
        self.skipNewlines()
        while self.current.kind != .eof {
            stmts.append(try self.parseStatement())
            self.skipNewlines()
        }
        return stmts
    }

    private func parseBlock() throws -> [KuniPyStmt] {
        guard self.current.kind == .colon else {
            throw KuniPyError.syntax("Expected ':'", self.current.line)
        }
        _ = self.advance()
        self.skipNewlines()
        guard self.current.kind == .indent else {
            return [try self.parseStatement()]
        }
        _ = self.advance()
        var stmts: [KuniPyStmt] = []
        while self.current.kind != .dedent && self.current.kind != .eof {
            self.skipNewlines()
            if self.current.kind == .dedent || self.current.kind == .eof { break }
            stmts.append(try self.parseStatement())
            self.skipNewlines()
        }
        if self.current.kind == .dedent {
            _ = self.advance()
        }
        return stmts
    }

    private func parseStatement() throws -> KuniPyStmt {
        switch self.current.kind {
        case .kwPass:
            _ = self.advance()
            return .passStmt
        case .kwBreak:
            _ = self.advance()
            return .breakStmt
        case .kwContinue:
            _ = self.advance()
            return .continueStmt
        case .kwReturn:
            _ = self.advance()
            if self.current.kind == .newline || self.current.kind == .eof {
                return .returnStmt(nil)
            }
            return .returnStmt(try self.parseExpr())
        case .kwDef:
            return try self.parseDef()
        case .kwIf:
            return try self.parseIf()
        case .kwFor:
            return try self.parseFor()
        case .kwWhile:
            return try self.parseWhile()
        case .kwTry:
            return try self.parseTry()
        case .kwImport:
            return try self.parseImport()
        case .kwFrom:
            return try self.parseFromImport()
        default:
            let expr = try self.parseExpr()
            switch self.current.kind {
            case .eq:
                _ = self.advance()
                let rhs = try self.parseExpr()
                return .assign(expr, rhs)
            case .plusEq:
                _ = self.advance()
                return .augAssign(expr, "+", try self.parseExpr())
            case .minusEq:
                _ = self.advance()
                return .augAssign(expr, "-", try self.parseExpr())
            case .starEq:
                _ = self.advance()
                return .augAssign(expr, "*", try self.parseExpr())
            case .slashEq:
                _ = self.advance()
                return .augAssign(expr, "/", try self.parseExpr())
            default:
                return .expr(expr)
            }
        }
    }

    private func parseDef() throws -> KuniPyStmt {
        _ = self.advance()
        guard case let .ident(name) = self.current.kind else {
            throw KuniPyError.syntax("Expected function name", self.current.line)
        }
        _ = self.advance()
        guard self.current.kind == .lparen else {
            throw KuniPyError.syntax("Expected '('", self.current.line)
        }
        _ = self.advance()
        var params: [String] = []
        var defaults: [String: KuniPyExpr] = [:]
        while self.current.kind != .rparen && self.current.kind != .eof {
            if case let .ident(p) = self.current.kind {
                _ = self.advance()
                params.append(p)
                if self.current.kind == .eq {
                    _ = self.advance()
                    defaults[p] = try self.parseExpr()
                }
            } else {
                _ = self.advance()
            }
            if self.current.kind == .comma { _ = self.advance() }
        }
        if self.current.kind == .rparen { _ = self.advance() }
        let body = try self.parseBlock()
        return .defFunc(name, params, defaults, body)
    }

    private func parseIf() throws -> KuniPyStmt {
        _ = self.advance()
        var branches: [(KuniPyExpr, [KuniPyStmt])] = []
        let cond = try self.parseExpr()
        branches.append((cond, try self.parseBlock()))
        self.skipNewlines()
        while self.current.kind == .kwElif {
            _ = self.advance()
            let c = try self.parseExpr()
            branches.append((c, try self.parseBlock()))
            self.skipNewlines()
        }
        var elseBlock: [KuniPyStmt]? = nil
        if self.current.kind == .kwElse {
            _ = self.advance()
            elseBlock = try self.parseBlock()
        }
        return .ifStmt(branches, elseBlock)
    }

    private func parseFor() throws -> KuniPyStmt {
        _ = self.advance()
        guard case let .ident(varName) = self.current.kind else {
            throw KuniPyError.syntax("Expected loop variable", self.current.line)
        }
        _ = self.advance()
        guard self.current.kind == .kwIn else {
            throw KuniPyError.syntax("Expected 'in'", self.current.line)
        }
        _ = self.advance()
        let iter = try self.parseExpr()
        let body = try self.parseBlock()
        return .forStmt(varName, iter, body)
    }

    private func parseWhile() throws -> KuniPyStmt {
        _ = self.advance()
        let cond = try self.parseExpr()
        let body = try self.parseBlock()
        return .whileStmt(cond, body)
    }

    private func parseTry() throws -> KuniPyStmt {
        _ = self.advance()
        let tryBody = try self.parseBlock()
        self.skipNewlines()
        var errName: String? = nil
        var exceptBody: [KuniPyStmt] = []
        if self.current.kind == .kwExcept {
            _ = self.advance()
            while self.current.kind != .colon && self.current.kind != .eof {
                if self.current.kind == .kwAs {
                    _ = self.advance()
                    if case let .ident(name) = self.current.kind {
                        errName = name
                        _ = self.advance()
                    }
                } else {
                    _ = self.advance()
                }
            }
            exceptBody = try self.parseBlock()
        }
        return .tryStmt(tryBody, errName, exceptBody)
    }

    private func parseImport() throws -> KuniPyStmt {
        _ = self.advance()
        var mod = ""
        while case let .ident(part) = self.current.kind {
            mod += part
            _ = self.advance()
            if self.current.kind == .dot {
                mod += "."
                _ = self.advance()
            } else {
                break
            }
        }
        var alias: String? = nil
        if self.current.kind == .kwAs {
            _ = self.advance()
            if case let .ident(a) = self.current.kind {
                alias = a
                _ = self.advance()
            }
        }
        return .importStmt(mod, alias)
    }

    private func parseFromImport() throws -> KuniPyStmt {
        _ = self.advance()
        var mod = ""
        while case let .ident(part) = self.current.kind {
            mod += part
            _ = self.advance()
            if self.current.kind == .dot {
                mod += "."
                _ = self.advance()
            } else {
                break
            }
        }
        if self.current.kind == .kwImport { _ = self.advance() }
        var items: [(String, String?)] = []
        while case let .ident(name) = self.current.kind {
            _ = self.advance()
            var alias: String? = nil
            if self.current.kind == .kwAs {
                _ = self.advance()
                if case let .ident(a) = self.current.kind {
                    alias = a
                    _ = self.advance()
                }
            }
            items.append((name, alias))
            if self.current.kind == .comma { _ = self.advance() } else { break }
        }
        return .fromImportStmt(mod, items)
    }

    private func parseExpr() throws -> KuniPyExpr {
        return try self.parseOr()
    }

    private func parseOr() throws -> KuniPyExpr {
        var left = try self.parseAnd()
        while self.current.kind == .kwOr {
            _ = self.advance()
            left = .binary("or", left, try self.parseAnd())
        }
        return left
    }

    private func parseAnd() throws -> KuniPyExpr {
        var left = try self.parseNot()
        while self.current.kind == .kwAnd {
            _ = self.advance()
            left = .binary("and", left, try self.parseNot())
        }
        return left
    }

    private func parseNot() throws -> KuniPyExpr {
        if self.current.kind == .kwNot {
            _ = self.advance()
            return .unary("not", try self.parseNot())
        }
        return try self.parseCompare()
    }

    private func parseCompare() throws -> KuniPyExpr {
        var left = try self.parseAdd()
        while true {
            let op: String?
            switch self.current.kind {
            case .eqEq: op = "=="
            case .notEq: op = "!="
            case .lt: op = "<"
            case .lte: op = "<="
            case .gt: op = ">"
            case .gte: op = ">="
            case .kwIn: op = "in"
            default: op = nil
            }
            guard let operatorStr = op else { break }
            _ = self.advance()
            left = .binary(operatorStr, left, try self.parseAdd())
        }
        return left
    }

    private func parseAdd() throws -> KuniPyExpr {
        var left = try self.parseMul()
        while self.current.kind == .plus || self.current.kind == .minus {
            let op = self.advance().kind == .plus ? "+" : "-"
            left = .binary(op, left, try self.parseMul())
        }
        return left
    }

    private func parseMul() throws -> KuniPyExpr {
        var left = try self.parseUnary()
        while true {
            let op: String?
            switch self.current.kind {
            case .star: op = "*"
            case .slash: op = "/"
            case .doubleSlash: op = "//"
            case .percent: op = "%"
            case .doubleStar: op = "**"
            default: op = nil
            }
            guard let operatorStr = op else { break }
            _ = self.advance()
            left = .binary(operatorStr, left, try self.parseUnary())
        }
        return left
    }

    private func parseUnary() throws -> KuniPyExpr {
        if self.current.kind == .minus {
            _ = self.advance()
            return .unary("-", try self.parseUnary())
        }
        return try self.parsePostfix()
    }

    private func parsePostfix() throws -> KuniPyExpr {
        var expr = try self.parsePrimary()
        while true {
            if self.current.kind == .dot {
                _ = self.advance()
                if case let .ident(attr) = self.current.kind {
                    _ = self.advance()
                    expr = .attr(expr, attr)
                }
            } else if self.current.kind == .lbracket {
                _ = self.advance()
                let idx = try self.parseExpr()
                if self.current.kind == .rbracket { _ = self.advance() }
                expr = .index(expr, idx)
            } else if self.current.kind == .lparen {
                _ = self.advance()
                var args: [KuniPyExpr] = []
                var kwargs: [(String, KuniPyExpr)] = []
                while self.current.kind != .rparen && self.current.kind != .eof {
                    if case let .ident(k) = self.current.kind,
                       self.pos + 1 < self.tokens.count,
                       self.tokens[self.pos + 1].kind == .eq {
                        _ = self.advance()
                        _ = self.advance()
                        kwargs.append((k, try self.parseExpr()))
                    } else {
                        args.append(try self.parseExpr())
                    }
                    if self.current.kind == .comma { _ = self.advance() } else { break }
                }
                if self.current.kind == .rparen { _ = self.advance() }
                expr = .call(expr, args, kwargs)
            } else {
                break
            }
        }
        return expr
    }

    private func parsePrimary() throws -> KuniPyExpr {
        let t = self.advance()
        switch t.kind {
        case let .int(v): return .literal(.int(v))
        case let .double(v): return .literal(.double(v))
        case let .string(v): return .literal(.string(v))
        case let .fstring(v): return .fstring(v)
        case .kwTrue: return .literal(.bool(true))
        case .kwFalse: return .literal(.bool(false))
        case .kwNone: return .literal(.none)
        case let .ident(name): return .ident(name)
        case .lparen:
            let e = try self.parseExpr()
            if self.current.kind == .rparen { _ = self.advance() }
            return e
        case .lbracket:
            var items: [KuniPyExpr] = []
            while self.current.kind != .rbracket && self.current.kind != .eof {
                items.append(try self.parseExpr())
                if self.current.kind == .comma { _ = self.advance() } else { break }
            }
            if self.current.kind == .rbracket { _ = self.advance() }
            return .list(items)
        case .lbrace:
            var pairs: [(KuniPyExpr, KuniPyExpr)] = []
            while self.current.kind != .rbrace && self.current.kind != .eof {
                let k = try self.parseExpr()
                if self.current.kind == .colon { _ = self.advance() }
                let v = try self.parseExpr()
                pairs.append((k, v))
                if self.current.kind == .comma { _ = self.advance() } else { break }
            }
            if self.current.kind == .rbrace { _ = self.advance() }
            return .dict(pairs)
        default:
            throw KuniPyError.syntax("Unexpected token", t.line)
        }
    }
}

// MARK: - Interpreter

private enum KuniPySignal: Error {
    case returnValue(KuniPyValue)
    case breakLoop
    case continueLoop
}

public final class KuniPyInterpreter {
    public let globalEnv = KuniPyEnv()
    private var modules: [String: KuniPyValue] = [:]
    private let logHandler: (String) -> Void

    public init(apiObject: KuniPyValue, logHandler: @escaping (String) -> Void) {
        self.logHandler = logHandler
        self.registerBuiltins(apiObject: apiObject)
    }

    public func registerModule(name: String, value: KuniPyValue) {
        self.modules[name] = value
    }

    public func execute(source: String) throws {
        let tokens = try tokenizePython(source)
        let parser = KuniPyParser(tokens: tokens)
        let stmts = try parser.parseProgram()
        _ = try self.execBlock(stmts, env: self.globalEnv)
    }

    @discardableResult
    public func callFunction(_ name: String, args: [KuniPyValue] = [], kwargs: [String: KuniPyValue] = [:]) throws -> KuniPyValue {
        guard let fn = self.globalEnv.get(name) else {
            return .none
        }
        return try self.invoke(fn, args: args, kwargs: kwargs)
    }

    public func hasFunction(_ name: String) -> Bool {
        guard let val = self.globalEnv.get(name) else { return false }
        switch val {
        case .function, .nativeFunction:
            return true
        default:
            return false
        }
    }

    private func execBlock(_ stmts: [KuniPyStmt], env: KuniPyEnv) throws -> KuniPyValue {
        var last: KuniPyValue = .none
        for stmt in stmts {
            last = try self.execStmt(stmt, env: env)
        }
        return last
    }

    private func execStmt(_ stmt: KuniPyStmt, env: KuniPyEnv) throws -> KuniPyValue {
        switch stmt {
        case .passStmt:
            return .none
        case .breakStmt:
            throw KuniPySignal.breakLoop
        case .continueStmt:
            throw KuniPySignal.continueLoop
        case let .returnStmt(expr):
            let val = try expr.map { try self.evalExpr($0, env: env) } ?? .none
            throw KuniPySignal.returnValue(val)
        case let .expr(e):
            return try self.evalExpr(e, env: env)
        case let .assign(target, rhs):
            let val = try self.evalExpr(rhs, env: env)
            try self.assignTarget(target, value: val, env: env)
            return val
        case let .augAssign(target, op, rhs):
            let current = try self.evalExpr(target, env: env)
            let right = try self.evalExpr(rhs, env: env)
            let updated = try self.applyBinary(op, current, right)
            try self.assignTarget(target, value: updated, env: env)
            return updated
        case let .defFunc(name, params, defaults, body):
            let fn = KuniPyCallable(name: name, params: params, defaults: defaults, body: body, closureEnv: env)
            env.set(name, .function(fn))
            return .none
        case let .ifStmt(branches, elseBlock):
            for (condExpr, body) in branches {
                let cond = try self.evalExpr(condExpr, env: env)
                if cond.isTruthy {
                    return try self.execBlock(body, env: env)
                }
            }
            if let elseBlock = elseBlock {
                return try self.execBlock(elseBlock, env: env)
            }
            return .none
        case let .forStmt(varName, iterExpr, body):
            let iterVal = try self.evalExpr(iterExpr, env: env)
            let items: [KuniPyValue]
            switch iterVal {
            case let .list(arr): items = arr
            case let .dict(d): items = d.keys.map { .string($0) }
            case let .string(s): items = s.map { .string(String($0)) }
            default: items = []
            }
            for item in items {
                env.set(varName, item)
                do {
                    _ = try self.execBlock(body, env: env)
                } catch KuniPySignal.continueLoop {
                    continue
                } catch KuniPySignal.breakLoop {
                    break
                }
            }
            return .none
        case let .whileStmt(condExpr, body):
            var guardCount = 0
            while try self.evalExpr(condExpr, env: env).isTruthy {
                guardCount += 1
                if guardCount > 100_000 {
                    throw KuniPyError.runtime("Loop iteration limit exceeded (100000)")
                }
                do {
                    _ = try self.execBlock(body, env: env)
                } catch KuniPySignal.continueLoop {
                    continue
                } catch KuniPySignal.breakLoop {
                    break
                }
            }
            return .none
        case let .tryStmt(tryBody, errName, exceptBody):
            do {
                return try self.execBlock(tryBody, env: env)
            } catch let signal as KuniPySignal {
                throw signal
            } catch {
                if let errName = errName {
                    env.set(errName, .string(error.localizedDescription))
                }
                return try self.execBlock(exceptBody, env: env)
            }
        case let .importStmt(mod, alias):
            let key = alias ?? mod.components(separatedBy: ".").first ?? mod
            if let m = self.modules[mod] ?? self.modules[key] {
                env.set(key, m)
            } else {
                env.set(key, .object([:]))
            }
            return .none
        case let .fromImportStmt(mod, items):
            let moduleObj = self.modules[mod]
            for (name, alias) in items {
                let targetName = alias ?? name
                if case let .object(dict) = moduleObj, let val = dict[name] {
                    env.set(targetName, val)
                } else {
                    env.set(targetName, .none)
                }
            }
            return .none
        }
    }

    private func assignTarget(_ target: KuniPyExpr, value: KuniPyValue, env: KuniPyEnv) throws {
        switch target {
        case let .ident(name):
            env.assign(name, value)
        case let .index(containerExpr, keyExpr):
            if case let .ident(name) = containerExpr, let current = env.get(name) {
                let key = try self.evalExpr(keyExpr, env: env)
                switch current {
                case var .dict(d):
                    d[key.stringValue] = value
                    env.assign(name, .dict(d))
                case var .list(arr):
                    if let idx = key.intValue, idx >= 0, Int(idx) < arr.count {
                        arr[Int(idx)] = value
                        env.assign(name, .list(arr))
                    }
                default:
                    break
                }
            }
        default:
            break
        }
    }

    private func evalExpr(_ expr: KuniPyExpr, env: KuniPyEnv) throws -> KuniPyValue {
        switch expr {
        case let .literal(v):
            return v
        case let .fstring(template):
            return .string(self.evalFString(template, env: env))
        case let .ident(name):
            return env.get(name) ?? .none
        case let .list(items):
            return .list(try items.map { try self.evalExpr($0, env: env) })
        case let .dict(pairs):
            var res: [String: KuniPyValue] = [:]
            for (kExpr, vExpr) in pairs {
                let k = try self.evalExpr(kExpr, env: env).stringValue
                let v = try self.evalExpr(vExpr, env: env)
                res[k] = v
            }
            return .dict(res)
        case let .unary(op, inner):
            let v = try self.evalExpr(inner, env: env)
            if op == "not" {
                return .bool(!v.isTruthy)
            } else if op == "-" {
                if let i = v.intValue, case .int = v { return .int(-i) }
                if let d = v.doubleValue { return .double(-d) }
            }
            return .none
        case let .binary(op, leftExpr, rightExpr):
            if op == "and" {
                let l = try self.evalExpr(leftExpr, env: env)
                return l.isTruthy ? try self.evalExpr(rightExpr, env: env) : l
            }
            if op == "or" {
                let l = try self.evalExpr(leftExpr, env: env)
                return l.isTruthy ? l : try self.evalExpr(rightExpr, env: env)
            }
            let l = try self.evalExpr(leftExpr, env: env)
            let r = try self.evalExpr(rightExpr, env: env)
            return try self.applyBinary(op, l, r)
        case let .attr(objExpr, attr):
            let obj = try self.evalExpr(objExpr, env: env)
            return self.resolveAttr(obj, attr: attr)
        case let .index(objExpr, idxExpr):
            let obj = try self.evalExpr(objExpr, env: env)
            let idx = try self.evalExpr(idxExpr, env: env)
            switch obj {
            case let .dict(d):
                return d[idx.stringValue] ?? .none
            case let .list(arr):
                if let i = idx.intValue {
                    let resolved = i < 0 ? arr.count + Int(i) : Int(i)
                    if resolved >= 0 && resolved < arr.count {
                        return arr[resolved]
                    }
                }
                return .none
            case let .string(s):
                if let i = idx.intValue {
                    let chars = Array(s)
                    let resolved = i < 0 ? chars.count + Int(i) : Int(i)
                    if resolved >= 0 && resolved < chars.count {
                        return .string(String(chars[resolved]))
                    }
                }
                return .none
            default:
                return .none
            }
        case let .call(calleeExpr, argExprs, kwExprs):
            let callee = try self.evalExpr(calleeExpr, env: env)
            let args = try argExprs.map { try self.evalExpr($0, env: env) }
            var kwargs: [String: KuniPyValue] = [:]
            for (k, vExpr) in kwExprs {
                kwargs[k] = try self.evalExpr(vExpr, env: env)
            }
            return try self.invoke(callee, args: args, kwargs: kwargs)
        }
    }

    private func invoke(_ callee: KuniPyValue, args: [KuniPyValue], kwargs: [String: KuniPyValue]) throws -> KuniPyValue {
        switch callee {
        case let .nativeFunction(fn):
            return try fn(args, kwargs)
        case let .function(callable):
            let localEnv = KuniPyEnv(parent: callable.closureEnv ?? self.globalEnv)
            for (index, param) in callable.params.enumerated() {
                if index < args.count {
                    localEnv.set(param, args[index])
                } else if let kwVal = kwargs[param] {
                    localEnv.set(param, kwVal)
                } else if let defExpr = callable.defaults[param] {
                    localEnv.set(param, try self.evalExpr(defExpr, env: localEnv))
                } else {
                    localEnv.set(param, .none)
                }
            }
            do {
                _ = try self.execBlock(callable.body, env: localEnv)
                return .none
            } catch let KuniPySignal.returnValue(val) {
                return val
            }
        default:
            return .none
        }
    }

    private func resolveAttr(_ obj: KuniPyValue, attr: String) -> KuniPyValue {
        switch obj {
        case let .object(dict):
            return dict[attr] ?? .none
        case let .dict(d):
            switch attr {
            case "get":
                return .nativeFunction { args, _ in
                    guard let key = args.first?.stringValue else { return .none }
                    return d[key] ?? (args.count > 1 ? args[1] : .none)
                }
            case "keys":
                return .nativeFunction { _, _ in .list(d.keys.map { .string($0) }) }
            case "values":
                return .nativeFunction { _, _ in .list(Array(d.values)) }
            default:
                return d[attr] ?? .none
            }
        case let .string(s):
            switch attr {
            case "lower": return .nativeFunction { _, _ in .string(s.lowercased()) }
            case "upper": return .nativeFunction { _, _ in .string(s.uppercased()) }
            case "strip": return .nativeFunction { _, _ in .string(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
            case "split":
                return .nativeFunction { args, _ in
                    let sep = args.first?.stringValue ?? " "
                    return .list(s.components(separatedBy: sep).map { .string($0) })
                }
            case "startswith":
                return .nativeFunction { args, _ in .bool(s.hasPrefix(args.first?.stringValue ?? "")) }
            case "endswith":
                return .nativeFunction { args, _ in .bool(s.hasSuffix(args.first?.stringValue ?? "")) }
            case "replace":
                return .nativeFunction { args, _ in
                    guard args.count >= 2 else { return .string(s) }
                    return .string(s.replacingOccurrences(of: args[0].stringValue, with: args[1].stringValue))
                }
            case "join":
                return .nativeFunction { args, _ in
                    if case let .list(items) = args.first ?? .none {
                        return .string(items.map { $0.stringValue }.joined(separator: s))
                    }
                    return .string("")
                }
            default: return .none
            }
        case let .list(arr):
            switch attr {
            case "append":
                return .nativeFunction { _, _ in .none }
            default: return .none
            }
        default:
            return .none
        }
    }

    private func applyBinary(_ op: String, _ l: KuniPyValue, _ r: KuniPyValue) throws -> KuniPyValue {
        switch op {
        case "+":
            if case let .string(a) = l, case let .string(b) = r { return .string(a + b) }
            if case let .list(a) = l, case let .list(b) = r { return .list(a + b) }
            if case let .int(a) = l, case let .int(b) = r { return .int(a + b) }
            if let a = l.doubleValue, let b = r.doubleValue { return .double(a + b) }
            return .string(l.stringValue + r.stringValue)
        case "-":
            if case let .int(a) = l, case let .int(b) = r { return .int(a - b) }
            if let a = l.doubleValue, let b = r.doubleValue { return .double(a - b) }
        case "*":
            if case let .string(a) = l, let b = r.intValue { return .string(String(repeating: a, count: max(0, Int(b)))) }
            if case let .int(a) = l, case let .int(b) = r { return .int(a * b) }
            if let a = l.doubleValue, let b = r.doubleValue { return .double(a * b) }
        case "/":
            if let a = l.doubleValue, let b = r.doubleValue, b != 0 { return .double(a / b) }
        case "//":
            if case let .int(a) = l, case let .int(b) = r, b != 0 { return .int(a / b) }
        case "%":
            if case let .int(a) = l, case let .int(b) = r, b != 0 { return .int(a % b) }
        case "**":
            if let a = l.doubleValue, let b = r.doubleValue { return .double(pow(a, b)) }
        case "==":
            return .bool(self.valuesEqual(l, r))
        case "!=":
            return .bool(!self.valuesEqual(l, r))
        case "<":
            if let a = l.doubleValue, let b = r.doubleValue { return .bool(a < b) }
            return .bool(l.stringValue < r.stringValue)
        case "<=":
            if let a = l.doubleValue, let b = r.doubleValue { return .bool(a <= b) }
            return .bool(l.stringValue <= r.stringValue)
        case ">":
            if let a = l.doubleValue, let b = r.doubleValue { return .bool(a > b) }
            return .bool(l.stringValue > r.stringValue)
        case ">=":
            if let a = l.doubleValue, let b = r.doubleValue { return .bool(a >= b) }
            return .bool(l.stringValue >= r.stringValue)
        case "in":
            switch r {
            case let .string(s): return .bool(s.contains(l.stringValue))
            case let .list(arr): return .bool(arr.contains { self.valuesEqual($0, l) })
            case let .dict(d): return .bool(d[l.stringValue] != nil)
            default: return .bool(false)
            }
        default:
            break
        }
        return .none
    }

    private func valuesEqual(_ l: KuniPyValue, _ r: KuniPyValue) -> Bool {
        switch (l, r) {
        case (.none, .none): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)): return Double(a) == b
        case let (.double(a), .int(b)): return a == Double(b)
        case let (.string(a), .string(b)): return a == b
        default: return false
        }
    }

    private func evalFString(_ template: String, env: KuniPyEnv) -> String {
        var result = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                if i + 1 < chars.count && chars[i + 1] == "{" {
                    result.append("{")
                    i += 2
                    continue
                }
                i += 1
                var exprStr = ""
                var depth = 1
                while i < chars.count && depth > 0 {
                    if chars[i] == "{" { depth += 1 }
                    else if chars[i] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    exprStr.append(chars[i])
                    i += 1
                }
                if i < chars.count && chars[i] == "}" { i += 1 }
                if let tokens = try? tokenizePython(exprStr),
                   let stmts = try? KuniPyParser(tokens: tokens).parseProgram(),
                   case let .expr(e)? = stmts.first,
                   let val = try? self.evalExpr(e, env: env) {
                    result.append(val.stringValue)
                }
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    private func registerBuiltins(apiObject: KuniPyValue) {
        self.globalEnv.set("api", apiObject)
        self.globalEnv.set("print", .nativeFunction { [weak self] args, _ in
            let line = args.map { $0.stringValue }.joined(separator: " ")
            self?.logHandler(line)
            return .none
        })
        self.globalEnv.set("len", .nativeFunction { args, _ in
            guard let first = args.first else { return .int(0) }
            switch first {
            case let .string(s): return .int(Int64(s.count))
            case let .list(a): return .int(Int64(a.count))
            case let .dict(d): return .int(Int64(d.count))
            default: return .int(0)
            }
        })
        self.globalEnv.set("str", .nativeFunction { args, _ in .string(args.first?.stringValue ?? "") })
        self.globalEnv.set("int", .nativeFunction { args, _ in .int(args.first?.intValue ?? 0) })
        self.globalEnv.set("float", .nativeFunction { args, _ in .double(args.first?.doubleValue ?? 0.0) })
        self.globalEnv.set("bool", .nativeFunction { args, _ in .bool(args.first?.isTruthy ?? false) })
        self.globalEnv.set("range", .nativeFunction { args, _ in
            let start: Int64 = args.count >= 2 ? (args[0].intValue ?? 0) : 0
            let end: Int64 = args.count >= 2 ? (args[1].intValue ?? 0) : (args.first?.intValue ?? 0)
            let step: Int64 = args.count >= 3 ? (args[2].intValue ?? 1) : 1
            guard step != 0 else { return .list([]) }
            var out: [KuniPyValue] = []
            var cur = start
            while (step > 0 && cur < end) || (step < 0 && cur > end) {
                out.append(.int(cur))
                cur += step
                if out.count > 100_000 { break }
            }
            return .list(out)
        })
        self.globalEnv.set("abs", .nativeFunction { args, _ in
            if case let .int(i)? = args.first { return .int(abs(i)) }
            if let d = args.first?.doubleValue { return .double(abs(d)) }
            return .int(0)
        })

        // Standard virtual modules
        let jsonModule = KuniPyValue.object([
            "dumps": .nativeFunction { args, _ in
                guard let first = args.first else { return .string("null") }
                let obj = first.toJSONObject()
                if JSONSerialization.isValidJSONObject(obj),
                   let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
                   let s = String(data: data, encoding: .utf8) {
                    return .string(s)
                }
                return .string(first.stringValue)
            },
            "loads": .nativeFunction { args, _ in
                guard let s = args.first?.stringValue,
                      let data = s.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    return .none
                }
                return KuniPyValue.fromJSONObject(obj)
            }
        ])
        self.modules["json"] = jsonModule

        let timeModule = KuniPyValue.object([
            "time": .nativeFunction { _, _ in .double(Date().timeIntervalSince1970) },
            "sleep": .nativeFunction { args, _ in
                if let sec = args.first?.doubleValue, sec > 0 && sec <= 10 {
                    Thread.sleep(forTimeInterval: sec)
                }
                return .none
            }
        ])
        self.modules["time"] = timeModule

        let mathModule = KuniPyValue.object([
            "pi": .double(Double.pi),
            "e": .double(M_E),
            "sqrt": .nativeFunction { args, _ in .double(sqrt(args.first?.doubleValue ?? 0)) },
            "floor": .nativeFunction { args, _ in .int(Int64(floor(args.first?.doubleValue ?? 0))) },
            "ceil": .nativeFunction { args, _ in .int(Int64(ceil(args.first?.doubleValue ?? 0))) }
        ])
        self.modules["math"] = mathModule

        let randomModule = KuniPyValue.object([
            "random": .nativeFunction { _, _ in .double(Double.random(in: 0..<1)) },
            "randint": .nativeFunction { args, _ in
                let a = args.count > 0 ? (args[0].intValue ?? 0) : 0
                let b = args.count > 1 ? (args[1].intValue ?? 1) : 1
                return .int(Int64.random(in: min(a, b)...max(a, b)))
            },
            "choice": .nativeFunction { args, _ in
                if case let .list(arr)? = args.first, !arr.isEmpty {
                    return arr[Int.random(in: 0..<arr.count)]
                }
                return .none
            }
        ])
        self.modules["random"] = randomModule

        let base64Module = KuniPyValue.object([
            "b64encode": .nativeFunction { args, _ in
                let str = args.first?.stringValue ?? ""
                return .string(Data(str.utf8).base64EncodedString())
            },
            "b64decode": .nativeFunction { args, _ in
                let str = args.first?.stringValue ?? ""
                if let data = Data(base64Encoded: str), let out = String(data: data, encoding: .utf8) {
                    return .string(out)
                }
                return .string("")
            }
        ])
        self.modules["base64"] = base64Module

        let hashlibModule = KuniPyValue.object([
            "sha256": .nativeFunction { args, _ in
                let data = Data((args.first?.stringValue ?? "").utf8)
                let digest = SHA256.hash(data: data)
                return .string(digest.map { String(format: "%02x", $0) }.joined())
            }
        ])
        self.modules["hashlib"] = hashlibModule
    }
}
