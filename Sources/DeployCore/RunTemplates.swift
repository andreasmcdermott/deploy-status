import Foundation

// Match runner-rendered text against its source. Unknown expressions can fill a
// slot but cannot provide evidence for an input. Never execute workflow code.
struct RunTemplate {
    enum Part { case literal(String), expression(String) }
    let parts: [Part]

    init(_ template: String) {
        var rest = template[...]
        var result: [Part] = []
        while let open = rest.range(of: "${{"), let close = rest[open.upperBound...].range(of: "}}") {
            result.append(.literal(String(rest[..<open.lowerBound])))
            result.append(.expression(rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)))
            rest = rest[close.upperBound...]
        }
        result.append(.literal(String(rest)))
        parts = result
    }

    func match(_ text: String, inputs: [WorkflowInput], context: [String: String]) -> [String: String]? {
        guard text.utf8.count <= 8192, parts.count <= 17 else { return nil }
        var pattern = "^"
        var captures: [(WorkflowInput, String?)] = []
        var openSlots = 0
        var unknownExpression = false
        var previousVariable = false
        var ambiguousBoundary = false
        for part in parts {
            switch part {
            case .literal(let s):
                pattern += NSRegularExpression.escapedPattern(for: s)
                if !s.isEmpty { previousVariable = false }
            case .expression(let expr):
                if let known = context[expr] {
                    pattern += NSRegularExpression.escapedPattern(for: known)
                    if !known.isEmpty { previousVariable = false }
                    continue
                }
                ambiguousBoundary = ambiguousBoundary || previousVariable
                previousVariable = true
                let operands = expr.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let spec = inputs.first(where: { ["inputs." + $0.id, "github.event.inputs." + $0.id].contains(operands[0]) }),
                      operands.count == 1 || (operands.count == 2 && operands[1].hasPrefix("'") && operands[1].hasSuffix("'")) else {
                    unknownExpression = true
                    pattern += ".*?"
                    openSlots += 1
                    continue
                }
                let fallback = operands.count == 2 ? String(operands[1].dropFirst().dropLast()) : nil
                captures.append((spec, fallback))
                if spec.options.isEmpty {
                    pattern += "(.*?)"
                    openSlots += 1
                } else {
                    pattern += "(" + spec.options.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
                }
            }
        }
        guard openSlots <= 3, let regex = try? NSRegularExpression(pattern: pattern + "$"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        var values: [String: String] = [:]
        for (i, capture) in captures.enumerated() {
            guard let range = Range(match.range(at: i + 1), in: text) else { continue }
            let value = String(text[range])
            let (spec, fallback) = capture
            guard !ambiguousBoundary, !unknownExpression, openSlots <= 1, !value.contains("***"), !value.isEmpty, value.count <= 1024,
                  fallback != value || (spec.required && !spec.options.isEmpty) else { continue }
            if let existing = values[spec.id], existing != value { return nil }
            values[spec.id] = value
        }
        return values
    }

    // For conditional titles, render each possible choice/boolean assignment.
    // Keep only values shared by every assignment that produces the exact title.
    func finiteValues(for title: String, inputs: [WorkflowInput], context: [String: String]) -> [String: String] {
        let expressions = parts.compactMap { if case .expression(let e) = $0 { return e }; return nil }
        let names = Set(expressions.flatMap { $0.matches(of: #/\binputs\.([\w-]+)/#).map { String($0.1) } })
        let used = inputs.filter { names.contains($0.id) }
        guard !used.isEmpty else { return [:] }
        var assignments: [[String: String]] = [[:]]
        for spec in used {
            guard !spec.options.isEmpty else { return [:] }
            let candidates = spec.options + (!spec.required && spec.type != "boolean" ? [""] : [])
            guard assignments.count <= 512 / candidates.count else { return [:] }
            assignments = assignments.flatMap { base in candidates.map { v in
                var next = base
                next[spec.id] = v
                return next
            } }
        }
        let matches = assignments.filter { assignment in
            var variables = context.mapValues(Expression.Value.string)
            for spec in used {
                guard let value = assignment[spec.id] else { continue }
                variables["inputs." + spec.id] = spec.type == "boolean" ? .bool(value == "true") : .string(value)
                variables["github.event.inputs." + spec.id] = .string(value)
            }
            var rendered = ""
            for part in parts {
                switch part {
                case .literal(let s): rendered += s
                case .expression(let expr):
                    var parser = Expression(expr, variables: variables)
                    guard let value = parser.evaluate() else { return false }
                    rendered += value.text
                }
            }
            return rendered == title
        }
        guard let first = matches.first else { return [:] }
        return first.filter { key, value in !value.isEmpty && matches.allSatisfy { $0[key] == value } }
    }
}

// Deliberately limited to literals, context references, equality, &&, || and
// parentheses. Unsupported syntax yields no evidence.
private struct Expression {
    enum Value: Equatable {
        case string(String), bool(Bool)
        var text: String {
            switch self { case .string(let s): return s; case .bool(let b): return String(b) }
        }
        var truth: Bool {
            switch self { case .string(let s): return !s.isEmpty; case .bool(let b): return b }
        }
    }
    var rest: Substring
    let variables: [String: Value]
    init(_ expr: String, variables: [String: Value]) { rest = expr[...]; self.variables = variables }

    mutating func eat(_ s: String) -> Bool {
        rest = rest.drop(while: { $0.isWhitespace })
        guard rest.hasPrefix(s) else { return false }
        rest = rest.dropFirst(s.count)
        return true
    }
    mutating func evaluate() -> Value? {
        let result = or()
        return rest.allSatisfy(\.isWhitespace) ? result : nil
    }
    mutating func or() -> Value? {
        guard var result = and() else { return nil }
        while eat("||") {
            guard let rhs = and() else { return nil }
            result = result.truth ? result : rhs
        }
        return result
    }
    mutating func and() -> Value? {
        guard var result = equal() else { return nil }
        while eat("&&") {
            guard let rhs = equal() else { return nil }
            result = result.truth ? rhs : result
        }
        return result
    }
    mutating func equal() -> Value? {
        guard let lhs = atom() else { return nil }
        let negated = eat("!=")
        if !negated && !eat("==") { return lhs }
        guard let rhs = atom() else { return nil }
        let same: Bool
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): same = a.caseInsensitiveCompare(b) == .orderedSame
        case (.bool(let a), .bool(let b)): same = a == b
        default: return nil
        }
        return .bool(negated != same)
    }
    mutating func atom() -> Value? {
        if eat("(") { let value = or(); return eat(")") ? value : nil }
        if eat("'") {
            var s = ""
            while let c = rest.popFirst() {
                if c == "'" {
                    if rest.first == "'" { rest.removeFirst(); s.append("'"); continue }
                    return .string(s)
                }
                s.append(c)
            }
            return nil
        }
        let token = rest.prefix { $0.isLetter || $0.isNumber || "._-".contains($0) }
        rest = rest.dropFirst(token.count)
        if token == "true" || token == "false" { return .bool(token == "true") }
        return variables[String(token)]
    }
}
