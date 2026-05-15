import Foundation

// In-shell EDT line editor.
//
// EDIT [/EDT] filename
//   * Loads the named .COM file from the script store into a line buffer.
//   * Replaces the DCL prompt with EDT's "*" so the same TextField in the
//     DCLShellWindow drives the editor.
//   * Each submit() is routed to runEditorLine until EXIT or QUIT.
//
// Supported commands (case-insensitive, may be abbreviated):
//   TYPE [range]            display lines (default = current line)
//   INSERT [line]           enter input mode at the given line, ending at "."
//   DELETE [range]          delete lines
//   REPLACE [range]         delete then input
//   FIND "string"           jump to first match, current line forward
//   SUBSTITUTE/old/new/     replace text on the current line
//   MOVE line               make `line` the current line
//   WRITE [file]            save buffer (defaults to original filename)
//   EXIT                    save and leave
//   QUIT                    discard and leave
//   HELP                    short reminder of the command set
//
// A "range" is one of:  n     n:m     %      WHOLE     END
extension DCLEngine {
    // MARK: -- entry / exit

    func startEdt(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%EDIT-F-NOFILE, no file specified\n"
        }
        let name = scriptStore.normalize(raw)
        var body = scriptStore.read(name: name) ?? ""
        var created = false
        if !scriptStore.exists(name: name) {
            // Match real EDT: create an empty buffer and tell the user.
            scriptStore.write(name: name, body: "")
            body = ""
            created = true
        }
        editorActive = true
        editorFilename = name
        editorBuffer = body.isEmpty
            ? []
            : body.components(separatedBy: "\n").map { line in
                // Drop the trailing empty element produced by a final "\n"
                // (we re-add it on save).
                line
            }
        // Remove trailing empty element from a final newline so line count
        // matches what the user expects.
        if let last = editorBuffer.last, last.isEmpty, !editorBuffer.isEmpty {
            editorBuffer.removeLast()
        }
        editorCurrentLine = max(1, editorBuffer.count == 0 ? 1 : 1)
        editorModified = created
        editorInsertMode = false
        editorPreviousPrompt = prompt
        prompt = "*"
        var s = "\n        \(osTitle) EDT Editor   File: \(name)\n"
        if created {
            s += "        [EOB] (new file)\n"
        } else {
            s += "        \(editorBuffer.count) lines loaded.\n"
        }
        s += "        Type HELP for commands, EXIT to save, QUIT to discard.\n"
        return s
    }

    /// Routes an input line to the editor. Returns transcript text to
    /// append; the engine has already echoed the prompt.
    func runEditorLine(_ raw: String) -> String {
        if editorInsertMode {
            return editorAcceptInput(raw)
        }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return "" }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let verb = parts[0].uppercased()
        let rest = parts.count > 1 ? parts[1] : ""

        switch true {
        case editorMatch(verb, "TYPE"):
            return editorType(rest)
        case editorMatch(verb, "INSERT"):
            return editorBeginInsert(rest, replace: false)
        case editorMatch(verb, "DELETE"):
            return editorDelete(rest)
        case editorMatch(verb, "REPLACE"):
            return editorBeginInsert(rest, replace: true)
        case editorMatch(verb, "FIND"):
            return editorFind(rest)
        case editorMatch(verb, "MOVE"):
            return editorMove(rest)
        case editorMatch(verb, "SUBSTITUTE"):
            return editorSubstitute(rest)
        case editorMatch(verb, "WRITE"):
            return editorWrite(rest)
        case editorMatch(verb, "EXIT"):
            return editorExit(save: true)
        case editorMatch(verb, "QUIT"):
            return editorExit(save: false)
        case editorMatch(verb, "HELP"):
            return editorHelp()
        case editorMatch(verb, "SHOW"):
            return editorShow(rest)
        default:
            return "%EDT-W-NOSUCH, unrecognized EDT command -- \(verb)\n"
        }
    }

    /// Whether the EDT session is currently consuming text-input lines
    /// (between an INSERT/REPLACE and the terminating ".").
    func editorIsInsertingText() -> Bool {
        return editorActive && editorInsertMode
    }

    // MARK: -- command implementations

    private func editorMatch(_ token: String, _ canonical: String) -> Bool {
        let t = token.uppercased()
        let c = canonical.uppercased()
        return t.count >= 1 && c.hasPrefix(t)
    }

    private func editorType(_ rest: String) -> String {
        let (lo, hi) = editorResolveRange(rest, defaultRange: (editorCurrentLine, editorCurrentLine))
        if editorBuffer.isEmpty {
            return "  [EOB]\n"
        }
        var s = ""
        for n in max(1, lo)...min(editorBuffer.count, hi) {
            s += String(format: "%4d  %@\n", n, editorBuffer[n - 1])
        }
        editorCurrentLine = min(editorBuffer.count, hi)
        if lo > editorBuffer.count {
            s += "  [EOB]\n"
        }
        return s
    }

    private func editorMove(_ rest: String) -> String {
        guard let n = editorParseSingle(rest) else {
            return "%EDT-W-LINENO, expected a line number\n"
        }
        editorCurrentLine = max(1, min(editorBuffer.count + 1, n))
        return "  line \(editorCurrentLine)\n"
    }

    private func editorBeginInsert(_ rest: String, replace: Bool) -> String {
        if replace {
            let (lo, hi) = editorResolveRange(rest, defaultRange: (editorCurrentLine, editorCurrentLine))
            if lo >= 1 && lo <= editorBuffer.count {
                let actualHi = min(editorBuffer.count, hi)
                editorBuffer.removeSubrange((lo - 1)...(actualHi - 1))
                editorModified = true
                editorCurrentLine = lo
            }
        } else if !rest.isEmpty, let n = editorParseSingle(rest) {
            editorCurrentLine = max(1, min(editorBuffer.count + 1, n))
        }
        editorInsertMode = true
        return "  Input mode: enter lines, end with a single '.' on its own line.\n"
    }

    private func editorAcceptInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "." {
            editorInsertMode = false
            return "  \(editorBuffer.count) lines, current = \(editorCurrentLine)\n"
        }
        let insertAt = max(0, min(editorBuffer.count, editorCurrentLine - 1))
        editorBuffer.insert(raw, at: insertAt)
        editorCurrentLine = insertAt + 2
        editorModified = true
        return ""
    }

    private func editorDelete(_ rest: String) -> String {
        let (lo, hi) = editorResolveRange(rest, defaultRange: (editorCurrentLine, editorCurrentLine))
        guard !editorBuffer.isEmpty, lo >= 1, lo <= editorBuffer.count else {
            return "  no lines to delete\n"
        }
        let actualHi = min(editorBuffer.count, hi)
        let n = actualHi - lo + 1
        editorBuffer.removeSubrange((lo - 1)...(actualHi - 1))
        editorModified = true
        editorCurrentLine = min(editorBuffer.count, lo)
        if editorBuffer.isEmpty { editorCurrentLine = 1 }
        return "  \(n) line\(n == 1 ? "" : "s") deleted\n"
    }

    private func editorFind(_ rest: String) -> String {
        let needle = editorUnquote(rest.trimmingCharacters(in: .whitespaces))
        if needle.isEmpty { return "%EDT-W-NEEDARG, FIND requires a target string\n" }
        let startIdx = max(0, editorCurrentLine - 1)
        for i in startIdx..<editorBuffer.count {
            if editorBuffer[i].range(of: needle, options: .caseInsensitive) != nil {
                editorCurrentLine = i + 1
                return String(format: "%4d  %@\n", editorCurrentLine, editorBuffer[i])
            }
        }
        return "%EDT-I-NOTFOUND, no match for \"\(needle)\"\n"
    }

    private func editorSubstitute(_ rest: String) -> String {
        // SUBSTITUTE/old/new/[range]
        var body = rest.trimmingCharacters(in: .whitespaces)
        var delim: Character = "/"
        if let first = body.first, "/!|".contains(first) { delim = first; body.removeFirst() }
        let parts = body.split(separator: delim, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else {
            return "%EDT-W-SUBARG, usage: SUBSTITUTE/old/new/[range]\n"
        }
        let old = parts[0]
        let new = parts[1]
        let rangeStr = parts.count > 2 ? parts[2] : ""
        let (lo, hi) = editorResolveRange(rangeStr, defaultRange: (editorCurrentLine, editorCurrentLine))
        var changes = 0
        for i in max(1, lo)...min(editorBuffer.count, hi) {
            let before = editorBuffer[i - 1]
            let after = before.replacingOccurrences(of: old, with: new)
            if before != after {
                editorBuffer[i - 1] = after
                changes += 1
            }
        }
        if changes > 0 { editorModified = true }
        return "  \(changes) substitution\(changes == 1 ? "" : "s") made\n"
    }

    private func editorWrite(_ rest: String) -> String {
        let target = rest.trimmingCharacters(in: .whitespaces)
        let dest = target.isEmpty ? editorFilename : scriptStore.normalize(target)
        let body = editorBuffer.joined(separator: "\n") + "\n"
        scriptStore.write(name: dest, body: body)
        editorModified = false
        return "%EDT-S-WROTE, wrote \(editorBuffer.count) lines to \(dest)\n"
    }

    private func editorExit(save: Bool) -> String {
        var s = ""
        if save {
            let body = editorBuffer.joined(separator: "\n") + "\n"
            scriptStore.write(name: editorFilename, body: body)
            s = "%EDT-I-WRITTEN, \(editorFilename) (\(editorBuffer.count) lines)\n"
        } else if editorModified {
            s = "%EDT-W-DISCARD, changes to \(editorFilename) discarded\n"
        } else {
            s = "%EDT-I-NOCHANGE, no changes to \(editorFilename)\n"
        }
        editorActive = false
        editorInsertMode = false
        editorBuffer = []
        editorFilename = ""
        editorModified = false
        prompt = editorPreviousPrompt.isEmpty ? "$ " : editorPreviousPrompt
        return s
    }

    private func editorHelp() -> String {
        var s = "\n  EDT line-editor commands\n"
        s += "  ------------------------\n"
        s += "    TYPE [range]              Display lines.\n"
        s += "    INSERT [line]             Insert text before the given line (\".\" to end).\n"
        s += "    DELETE [range]            Delete lines.\n"
        s += "    REPLACE [range]           Delete then insert.\n"
        s += "    MOVE line                 Set the current line.\n"
        s += "    FIND \"text\"               Jump to the next matching line.\n"
        s += "    SUBSTITUTE/old/new/[range]   Replace text within a range.\n"
        s += "    WRITE [file]              Save the buffer (defaults to current file).\n"
        s += "    SHOW [BUFFER|FILE]        Editor status.\n"
        s += "    EXIT                      Save and return to DCL.\n"
        s += "    QUIT                      Discard changes and return to DCL.\n"
        s += "    HELP                      This list.\n"
        s += "\n  Range forms:  n   n:m   %  (whole buffer)   END\n"
        return s
    }

    private func editorShow(_ rest: String) -> String {
        let arg = rest.uppercased().trimmingCharacters(in: .whitespaces)
        switch arg {
        case "", "BUFFER":
            return "  File: \(editorFilename)   Lines: \(editorBuffer.count)   Current: \(editorCurrentLine)\n  Modified: \(editorModified ? "yes" : "no")\n"
        case "FILE":
            return "  \(editorFilename) (in script store)\n"
        default:
            return "%EDT-W-NOSUCH, SHOW \(arg)?  Try SHOW BUFFER or SHOW FILE.\n"
        }
    }

    // MARK: -- helpers

    private func editorParseSingle(_ s: String) -> Int? {
        return Int(s.trimmingCharacters(in: .whitespaces))
    }

    private func editorResolveRange(_ s: String, defaultRange: (Int, Int)) -> (Int, Int) {
        let trimmed = s.trimmingCharacters(in: .whitespaces).uppercased()
        if trimmed.isEmpty { return defaultRange }
        if trimmed == "%" || trimmed == "WHOLE" { return (1, max(1, editorBuffer.count)) }
        if trimmed == "END" { return (max(1, editorBuffer.count), max(1, editorBuffer.count)) }
        if let colon = trimmed.firstIndex(of: ":") {
            let lo = Int(trimmed[..<colon]) ?? defaultRange.0
            let hi = Int(trimmed[trimmed.index(after: colon)...]) ?? defaultRange.1
            return (min(lo, hi), max(lo, hi))
        }
        if let n = Int(trimmed) { return (n, n) }
        return defaultRange
    }

    private func editorUnquote(_ s: String) -> String {
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
