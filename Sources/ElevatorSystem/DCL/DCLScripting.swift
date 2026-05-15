import Foundation

// DCL command-procedure interpreter (`@file.COM`).
//
// Supports the slice of DCL that's most useful for driving the elevator
// simulator from a script:  labels, GOTO/GOSUB/RETURN, IF/THEN/[ELSE],
// EXIT, symbol assignment (string and integer arithmetic), single-quote
// substitution, and a handful of F$ lexical functions.
extension DCLEngine {
    /// Maximum nested `@file` depth.  Real DCL allows 32 levels of
    /// nesting; we cap shallower to keep the simulation lively.
    private static var maxScriptDepth: Int { 8 }

    /// Entry point for the `@file` verb.  Looks the script up in the
    /// store, runs it, and returns the accumulated output that should
    /// appear in the transcript.
    func execComFile(_ raw: String) -> String {
        // Strip parameters: real DCL allows `@FILE arg1 arg2 ...`. The
        // verb is a single token without spaces, so additional args land
        // in cmd.positional. We only see the raw filename here.
        let name = scriptStore.normalize(raw)
        guard let body = scriptStore.read(name: name) else {
            // Provide the canonical STARTUP fallback for compatibility.
            if name == "STARTUP.COM" {
                return runScript(body: defaultStartupCom(), name: name, args: [])
            }
            fail("RMS-E-FNF", "%X00018292")
            return "%DCL-E-OPENIN, error opening \(raw) as input\n-RMS-E-FNF, file not found\n"
        }
        return runScript(body: body, name: name, args: [])
    }

    /// Run the body of a script as if it were typed at the prompt.
    /// Captures every line of output and returns it.
    func runScript(body: String, name: String, args: [String]) -> String {
        guard scriptDepth < DCLEngine.maxScriptDepth else {
            return "%DCL-E-NESTED, too many nested command procedures (max \(DCLEngine.maxScriptDepth))\n"
        }
        scriptDepth += 1
        defer { scriptDepth -= 1 }

        // P1..P8 are positional arguments by VMS convention.
        for i in 0..<8 {
            let key = "P\(i + 1)"
            if i < args.count { symbols[key] = args[i] }
            else              { symbols[key] = "" }
        }

        let lines = body.components(separatedBy: "\n")
        // Pre-scan for labels so GOTO can branch forward.
        var labels: [String: Int] = [:]
        for (idx, raw) in lines.enumerated() {
            if let lbl = parseLabel(raw) { labels[lbl] = idx }
        }

        var pc = 0
        var output = ""
        var gosubReturns: [Int] = []
        var exitRequested = false

        while pc < lines.count && !exitRequested {
            let rawLine = lines[pc]
            pc += 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Lines that don't start with $ are continuation / data; we
            // surface them as literal output to mirror DCL's INPUT mode.
            guard trimmed.first == "$" else {
                output += trimmed + "\n"
                continue
            }
            var stripped = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            if stripped.first == "!" { continue }                  // $! comment
            if parseLabel(rawLine) != nil { continue }              // $LABEL:

            // Inline comment trim: anything after a `!` outside quotes.
            stripped = stripInlineComment(stripped)
            if stripped.isEmpty { continue }

            // Symbol substitution.
            stripped = substituteSymbols(stripped)

            // Interpret control verbs that the dispatcher doesn't know.
            if let action = parseScriptControl(stripped) {
                switch action {
                case .exit(let status):
                    if let st = status { lastStatus = st }
                    exitRequested = true
                case .goto(let label):
                    if let target = labels[label.uppercased()] {
                        pc = target + 1
                    } else {
                        output += "%DCL-W-USGOTO, target of GOTO not found -- \(label)\n"
                        exitRequested = true
                    }
                case .gosub(let label):
                    if let target = labels[label.uppercased()] {
                        gosubReturns.append(pc)
                        pc = target + 1
                    } else {
                        output += "%DCL-W-USGOTO, target of GOSUB not found -- \(label)\n"
                        exitRequested = true
                    }
                case .returnSub:
                    if let dest = gosubReturns.popLast() {
                        pc = dest
                    } else {
                        output += "%DCL-W-NORETURN, no matching GOSUB\n"
                        exitRequested = true
                    }
                case .ifThen(let cmd):
                    let result = execute(cmd)
                    if !result.isEmpty {
                        output += result + (result.hasSuffix("\n") ? "" : "\n")
                    }
                case .assignment(let key, let value):
                    symbols[key.uppercased()] = value
                }
                continue
            }

            // Otherwise dispatch as a normal DCL command line.
            let result = execute(stripped)
            if !result.isEmpty {
                output += result + (result.hasSuffix("\n") ? "" : "\n")
            }
        }
        return output
    }

    // MARK: -- Script control parsing

    enum ScriptAction {
        case exit(String?)
        case goto(String)
        case gosub(String)
        case returnSub
        case ifThen(String)            // command to execute when expression is true
        case assignment(String, String)
    }

    private func parseLabel(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "$" else { return nil }
        let inner = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        // "LABEL:" with optionally a trailing comment.
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        let head = inner[..<colon]
        let tail = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // A label is a bare identifier followed by ":"; if there is text
        // after the colon (e.g. "DCL:") it's just a normal command line.
        let name = String(head).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }
        let isIdent = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        if !isIdent { return nil }
        if !tail.isEmpty && !tail.hasPrefix("!") { return nil }
        return name.uppercased()
    }

    private func parseScriptControl(_ line: String) -> ScriptAction? {
        let head = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)?.uppercased() ?? ""

        switch head {
        case "EXIT":
            let rest = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return .exit(rest.isEmpty ? nil : rest)
        case "GOTO":
            let rest = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return .goto(rest)
        case "GOSUB":
            let rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return .gosub(rest)
        case "RETURN":
            return .returnSub
        case "IF":
            return parseIfClause(line)
        default:
            // Detect `SYM = ...` -- a bare assignment, not a verb.
            if let assignment = parseAssignment(line) {
                return .assignment(assignment.0, assignment.1)
            }
            return nil
        }
    }

    /// Single-line  IF expr THEN cmd [ELSE cmd].
    private func parseIfClause(_ line: String) -> ScriptAction? {
        // Locate THEN ... and optional ELSE ... outside quoted strings.
        let upper = line.uppercased()
        guard let thenRange = rangeOfKeyword("THEN", in: upper) else {
            return nil
        }
        let condRaw = String(line[line.index(line.startIndex, offsetBy: 2)..<line.index(line.startIndex, offsetBy: thenRange.lowerBound)])
            .trimmingCharacters(in: .whitespaces)

        let afterThen = line.index(line.startIndex, offsetBy: thenRange.upperBound)
        var thenCmd = String(line[afterThen...]).trimmingCharacters(in: .whitespaces)
        var elseCmd: String? = nil

        if let elseRange = rangeOfKeyword("ELSE", in: upper, startingAt: thenRange.upperBound) {
            let elseStart = line.index(line.startIndex, offsetBy: elseRange.lowerBound)
            let elseAfter = line.index(line.startIndex, offsetBy: elseRange.upperBound)
            thenCmd = String(line[afterThen..<elseStart]).trimmingCharacters(in: .whitespaces)
            elseCmd = String(line[elseAfter...]).trimmingCharacters(in: .whitespaces)
        }

        let truthy = evaluateCondition(condRaw)
        let chosen = truthy ? thenCmd : (elseCmd ?? "")
        return .ifThen(chosen)
    }

    /// Find a standalone keyword (space-surrounded) in a string, returning
    /// the integer character offset range of the keyword body itself.
    private func rangeOfKeyword(_ kw: String, in upper: String, startingAt offset: Int = 0) -> (lowerBound: Int, upperBound: Int)? {
        let chars = Array(upper)
        let kwChars = Array(kw)
        var i = offset
        var inQuote = false
        while i + kwChars.count <= chars.count {
            let c = chars[i]
            if c == "\"" { inQuote.toggle() }
            if !inQuote {
                let leftOK = (i == 0) || !chars[i - 1].isLetter
                let rightOK = (i + kwChars.count == chars.count) ||
                              (!chars[i + kwChars.count].isLetter && chars[i + kwChars.count] != "_")
                if leftOK && rightOK && Array(chars[i..<i + kwChars.count]) == kwChars {
                    return (i, i + kwChars.count)
                }
            }
            i += 1
        }
        return nil
    }

    private func parseAssignment(_ line: String) -> (String, String)? {
        // Skip leading verb pattern: a verb followed by args. An
        // assignment is the form  IDENT [=|==] expr.
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let lhs = line[..<eq].trimmingCharacters(in: .whitespaces)
        // The lhs must be a single identifier.
        let isIdent = !lhs.isEmpty && lhs.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        if !isIdent { return nil }
        var rhsStart = line.index(after: eq)
        // Accept ==  (global symbol) by skipping the second '='.
        if rhsStart < line.endIndex && line[rhsStart] == "=" {
            rhsStart = line.index(after: rhsStart)
        }
        var rhs = String(line[rhsStart...]).trimmingCharacters(in: .whitespaces)
        // String literal "abc" -> drop the quotes.
        if rhs.hasPrefix("\"") && rhs.hasSuffix("\"") && rhs.count >= 2 {
            rhs = String(rhs.dropFirst().dropLast())
            return (lhs.uppercased(), rhs)
        }
        // Otherwise treat as integer expression.
        if let value = evaluateInteger(rhs) {
            return (lhs.uppercased(), String(value))
        }
        return (lhs.uppercased(), rhs)
    }

    // MARK: -- Expression evaluation

    /// Evaluate a DCL IF expression. Supports:
    ///   .EQ. .NE. .LT. .LE. .GT. .GE.    integer compare
    ///   .EQS. .NES.                       string compare
    ///   .AND. .OR. .NOT.                  boolean combinators
    private func evaluateCondition(_ expr: String) -> Bool {
        let resolved = resolveLexicals(substituteSymbols(expr))
        let upper = resolved.uppercased()
        // .NOT.
        if upper.hasPrefix(".NOT.") {
            let rest = String(resolved.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return !evaluateCondition(rest)
        }
        // Boolean combinators -- left-to-right, no precedence beyond NOT.
        if let split = splitBoolean(resolved, op: ".AND.") {
            return evaluateCondition(split.0) && evaluateCondition(split.1)
        }
        if let split = splitBoolean(resolved, op: ".OR.") {
            return evaluateCondition(split.0) || evaluateCondition(split.1)
        }
        // Comparators. IF expressions treat bare identifiers as symbol
        // references, so resolveForCompare looks them up before comparing.
        for op in [".EQS.", ".NES.", ".EQ.", ".NE.", ".LE.", ".LT.", ".GE.", ".GT."] {
            if let split = splitBoolean(resolved, op: op) {
                let l = resolveForCompare(split.0)
                let r = resolveForCompare(split.1)
                switch op {
                case ".EQS.": return l == r
                case ".NES.": return l != r
                case ".EQ.":  return (Int(l) ?? 0) == (Int(r) ?? 0)
                case ".NE.":  return (Int(l) ?? 0) != (Int(r) ?? 0)
                case ".LE.":  return (Int(l) ?? 0) <= (Int(r) ?? 0)
                case ".LT.":  return (Int(l) ?? 0) <  (Int(r) ?? 0)
                case ".GE.":  return (Int(l) ?? 0) >= (Int(r) ?? 0)
                case ".GT.":  return (Int(l) ?? 0) >  (Int(r) ?? 0)
                default:      break
                }
            }
        }
        // A bare expression: non-zero / non-empty == true.
        let stripped = resolveForCompare(resolved)
        if let n = Int(stripped) { return n != 0 }
        return !stripped.isEmpty
    }

    /// Resolve an IF-expression operand: a "quoted string" turns into its
    /// inner text; an identifier is looked up in the symbol table; a
    /// numeric literal passes through unchanged.
    private func resolveForCompare(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        if Int(trimmed) != nil { return trimmed }
        let key = trimmed.uppercased()
        if let b = builtinSymbol(key) { return b }
        if let v = symbols[key] { return v }
        return trimmed
    }

    private func splitBoolean(_ s: String, op: String) -> (String, String)? {
        let upper = s.uppercased()
        var i = upper.startIndex
        var inQuote = false
        while i < upper.endIndex {
            if upper[i] == "\"" { inQuote.toggle() }
            if !inQuote {
                if upper[i...].hasPrefix(op) {
                    let lhs = String(s[..<i])
                    let rhsStart = upper.index(i, offsetBy: op.count)
                    let rhs = String(s[rhsStart...])
                    return (lhs, rhs)
                }
            }
            i = upper.index(after: i)
        }
        return nil
    }

    private func unquote(_ s: String) -> String {
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Evaluate a DCL integer expression -- simple left-to-right + - * /.
    private func evaluateInteger(_ raw: String) -> Int? {
        let resolved = resolveLexicals(substituteSymbols(raw))
        // Tokenize on operators.
        var tokens: [String] = []
        var current = ""
        for ch in resolved {
            if "+-*/".contains(ch) {
                if !current.isEmpty { tokens.append(current.trimmingCharacters(in: .whitespaces)) }
                tokens.append(String(ch))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current.trimmingCharacters(in: .whitespaces)) }
        if tokens.isEmpty { return nil }
        func intValue(_ tok: String) -> Int? {
            if let n = Int(tok) { return n }
            let key = tok.uppercased()
            if let b = builtinSymbol(key), let n = Int(b) { return n }
            if let v = symbols[key], let n = Int(v) { return n }
            return nil
        }
        guard var acc = intValue(tokens[0]) else { return nil }
        var i = 1
        while i + 1 < tokens.count {
            let op = tokens[i]
            guard let rhs = intValue(tokens[i + 1]) else { return nil }
            switch op {
            case "+": acc += rhs
            case "-": acc -= rhs
            case "*": acc *= rhs
            case "/": acc = rhs == 0 ? 0 : acc / rhs
            default:  return nil
            }
            i += 2
        }
        return acc
    }

    // MARK: -- Symbol substitution

    /// Replace `'SYM'` and `''SYM''` in the supplied line. Outside quotes
    /// `'NAME'` substitutes; inside double quotes `''NAME''` substitutes.
    func substituteSymbols(_ line: String) -> String {
        var out = ""
        var i = line.startIndex
        var inQuote = false
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                inQuote.toggle()
                out.append(ch)
                i = line.index(after: i)
                continue
            }
            // Symbol substitution inside double quotes:  ''NAME'
            // (two apostrophes to open, one to close -- standard DCL).
            if inQuote && ch == "'" && line.index(after: i) < line.endIndex && line[line.index(after: i)] == "'" {
                let afterTwo = line.index(i, offsetBy: 2)
                if let end = findClosingSingleTick(in: line, from: afterTwo) {
                    let name = String(line[afterTwo..<end])
                    out += lookupSymbol(name)
                    i = line.index(after: end)
                    continue
                }
            }
            // Single-tick form outside double quotes.
            if !inQuote && ch == "'" {
                let after = line.index(after: i)
                if let end = findClosingSingleTick(in: line, from: after) {
                    let name = String(line[after..<end])
                    out += lookupSymbol(name)
                    i = line.index(after: end)
                    continue
                }
            }
            out.append(ch)
            i = line.index(after: i)
        }
        return resolveLexicals(out)
    }

    private func findClosingSingleTick(in s: String, from start: String.Index) -> String.Index? {
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if c == "'" { return i }
            // Only identifier chars are valid inside.
            if !(c.isLetter || c.isNumber || c == "_" || c == "$") { return nil }
            i = s.index(after: i)
        }
        return nil
    }



    private func lookupSymbol(_ raw: String) -> String {
        let key = raw.uppercased()
        if let b = builtinSymbol(key) { return b }
        return symbols[key] ?? ""
    }

    /// Remove `!` inline comments that aren't inside a quoted string.
    private func stripInlineComment(_ line: String) -> String {
        var out = ""
        var inQuote = false
        for ch in line {
            if ch == "\"" { inQuote.toggle() }
            if ch == "!" && !inQuote { break }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: -- F$ lexical functions

    /// Expand all occurrences of F$NAME(args) in the supplied text.
    func resolveLexicals(_ raw: String) -> String {
        var s = raw
        // Naive iterative expansion until no F$ remains.
        var safety = 0
        while let range = s.range(of: "F$", options: [.caseInsensitive]) {
            safety += 1
            if safety > 32 { break }
            let nameStart = range.lowerBound
            // Find the open paren.
            guard let lparen = s.range(of: "(", range: range.upperBound..<s.endIndex) else { break }
            let funcName = String(s[range.upperBound..<lparen.lowerBound]).uppercased()
            // Find matching ')'.
            guard let rparen = matchingParen(in: s, from: lparen.upperBound) else { break }
            let argText = String(s[lparen.upperBound..<rparen])
            let args = splitArgs(argText).map { stripSpaces($0) }
            let replacement = evalLexical(funcName, args: args)
            let endIndex = s.index(after: rparen)
            s.replaceSubrange(nameStart..<endIndex, with: replacement)
        }
        return s
    }

    private func matchingParen(in s: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var i = start
        var inQuote = false
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" { inQuote.toggle() }
            if !inQuote {
                if c == "(" { depth += 1 }
                if c == ")" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private func splitArgs(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var depth = 0
        var inQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle() }
            if !inQuote {
                if ch == "(" { depth += 1 }
                if ch == ")" { depth -= 1 }
                if ch == "," && depth == 0 {
                    args.append(current)
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        if !current.isEmpty || !args.isEmpty {
            args.append(current)
        }
        return args
    }

    private func stripSpaces(_ s: String) -> String {
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func evalLexical(_ name: String, args: [String]) -> String {
        func arg(_ i: Int) -> String { i < args.count ? unquote(args[i]) : "" }
        switch name {
        case "LENGTH":
            return String(arg(0).count)
        case "EXTRACT":
            let start = Int(arg(0)) ?? 0
            let len   = Int(arg(1)) ?? 0
            let s = arg(2)
            if start >= s.count { return "" }
            let s0 = s.index(s.startIndex, offsetBy: max(0, start))
            let s1 = s.index(s0, offsetBy: min(len, s.count - start))
            return String(s[s0..<s1])
        case "LOCATE":
            let needle = arg(0)
            let haystack = arg(1)
            if let r = haystack.range(of: needle) {
                return String(haystack.distance(from: haystack.startIndex, to: r.lowerBound))
            }
            return String(haystack.count)
        case "INTEGER":
            return String(Int(arg(0)) ?? 0)
        case "STRING":
            return arg(0)
        case "EDIT":
            let s = arg(0)
            let modifiers = arg(1).uppercased()
            var out = s
            if modifiers.contains("UPCASE")    { out = out.uppercased() }
            if modifiers.contains("LOWERCASE") { out = out.lowercased() }
            if modifiers.contains("TRIM")      { out = out.trimmingCharacters(in: .whitespaces) }
            if modifiers.contains("COMPRESS")  {
                while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
            }
            return out
        case "TIME":
            return stamp(Date())
        case "USER":
            return username
        case "MODE":
            return "INTERACTIVE"
        case "PROCESS":
            return "DCL_\(username)"
        case "PID":
            return pid
        case "ENVIRONMENT":
            let key = arg(0).uppercased()
            switch key {
            case "DEFAULT":      return "\(defaultDevice)\(defaultDirectory)"
            case "PROMPT_PROMPT", "PROMPT": return prompt.trimmingCharacters(in: .whitespaces)
            case "VERIFY_PROCEDURE", "VERIFY": return "FALSE"
            default: return ""
            }
        case "SEARCH":
            let target = arg(0)
            let name = scriptStore.normalize(target)
            return scriptStore.exists(name: name) ? "\(defaultDevice)\(defaultDirectory)\(name);1" : ""
        case "TRNLNM":
            return processLogicals[arg(0).uppercased()] ?? ""
        default:
            return ""
        }
    }
}
