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

    // MARK: -- Screen-mode editor (EDT change mode)
    //
    // The screen editor takes over the alternate buffer (same one used
    // by MONITOR and the diagnostic menu), paints a reverse-video
    // status bar at the top and hint bar at the bottom, and shows a
    // scrollable view of the buffer in between. Arrow keys move the
    // cursor, printable input inserts at the cursor, Enter splits the
    // current line, Backspace deletes the character before the cursor
    // (or joins with the previous line at column 0), Page Up / Down
    // scroll the viewport, Ctrl-Z saves and exits, Ctrl-Y / Ctrl-C
    // discard and exit.

    /// Screen-editor layout constants (a 24-row VT220 viewport).
    private static let edtScreenViewRows: Int = 21    // rows 2...22
    private static let edtScreenHintRow: Int = 23
    private static let edtScreenWidth: Int = 80

    func startEdtScreen(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%EDIT-F-NOFILE, no file specified\n"
        }
        let name = scriptStore.normalize(raw)
        let body = scriptStore.read(name: name) ?? ""
        let created = !scriptStore.exists(name: name)
        if created {
            scriptStore.write(name: name, body: "")
        }
        // Always have at least one (possibly empty) line so the cursor
        // can sit somewhere when editing an empty file.
        var lines = body.isEmpty ? [""] : body.components(separatedBy: "\n")
        // Drop the trailing empty element from a final "\n" so the line
        // count matches what the user expects.
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        if lines.isEmpty { lines = [""] }

        editorActive = true
        editorScreenMode = true
        editorFilename = name
        editorBuffer = lines
        editorCursorRow = 0
        editorCursorCol = 0
        editorViewTop = 0
        editorCurrentLine = 1
        editorModified = created
        editorInsertMode = false
        editorPreviousPrompt = prompt
        liveMode = .screenEditor
        enterLiveScreen()
        refreshScreenEditor()
        return ""
    }

    /// Repaint the entire screen. Status bar in reverse video at row 1,
    /// content viewport on rows 2...22, hint bar in reverse video at
    /// row 23. Cursor is positioned over the logical (cursorRow,
    /// cursorCol) cell at the end.
    func refreshScreenEditor() {
        guard case .screenEditor = liveMode else { return }
        let viewRows = Self.edtScreenViewRows
        let width    = Self.edtScreenWidth
        let hintRow  = Self.edtScreenHintRow

        // Auto-scroll so the cursor row is always visible.
        if editorCursorRow < editorViewTop {
            editorViewTop = editorCursorRow
        } else if editorCursorRow >= editorViewTop + viewRows {
            editorViewTop = editorCursorRow - viewRows + 1
        }
        editorViewTop = max(0, editorViewTop)

        var s = ""
        // Status bar
        let modTag  = editorModified ? " [Modified]" : ""
        let leftS   = " EDT  \(editorFilename)\(modTag)"
        let rightS  = "L:\(editorCursorRow + 1)  C:\(editorCursorCol + 1) "
        let padN    = max(1, width - leftS.count - rightS.count)
        let status  = (leftS + String(repeating: " ", count: padN) + rightS)
                        .padding(toLength: width, withPad: " ", startingAt: 0)
        s += "\u{1B}[1;1H\u{1B}[7m\(status)\u{1B}[27m"

        // Content viewport
        for vrow in 0..<viewRows {
            let bufferRow = editorViewTop + vrow
            let lineText: String
            if bufferRow < editorBuffer.count {
                lineText = String(editorBuffer[bufferRow].prefix(width))
            } else {
                lineText = "~"
            }
            s += "\u{1B}[\(vrow + 2);1H\(lineText)\u{1B}[K"
        }

        // Hint bar -- ^Z and ^Y are the canonical EDT bindings, but the
        // tty driver on macOS eats them when the user connects via nc,
        // so we publish the ^X / ESC ESC alternatives too.
        let hint = " ^Z/^X save   ^Y / ESC ESC discard   PgUp/PgDn   Arrows: move"
            .padding(toLength: width, withPad: " ", startingAt: 0)
        s += "\u{1B}[\(hintRow);1H\u{1B}[7m\(hint)\u{1B}[27m"

        // Position cursor over its logical cell.
        let cursorScreenRow = (editorCursorRow - editorViewTop) + 2
        let cursorScreenCol = max(1, min(width, editorCursorCol + 1))
        s += "\u{1B}[0m\u{1B}[\(cursorScreenRow);\(cursorScreenCol)H"
        outRaw(s)
    }

    /// Dispatch input bytes routed by VTShellView while the editor is
    /// in screen mode. Parses CSI escapes for arrows / Page keys and
    /// hands single-byte keys to the dedicated handlers.
    func handleScreenEditorKey(_ bytes: [UInt8]) {
        guard case .screenEditor = liveMode else { return }
        var dirty = false
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            // ESC ESC: alternative discard-and-exit gesture for users
            // whose tty driver eats ^Y / ^C / ^Z before they can reach
            // us (common when connecting via `nc localhost 2323` from a
            // macOS terminal -- DSUSP / INTR / SUSP get consumed by the
            // local line discipline).
            if b == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x1B {
                screenEditorDiscardAndExit()
                return
            }
            // CSI sequence (ESC [ ... <final 0x40...0x7E>)
            if b == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                var j = i + 2
                while j < bytes.count, !((0x40...0x7E).contains(bytes[j])) {
                    j += 1
                }
                if j < bytes.count {
                    let final  = bytes[j]
                    let params = Array(bytes[(i + 2)..<j])
                    handleScreenEditorCSI(final: final, params: params)
                    i = j + 1
                    dirty = true
                    continue
                } else {
                    break   // incomplete escape -- ignore the tail
                }
            }
            switch b {
            case 0x1A, 0x18:                            // Ctrl-Z / Ctrl-X: save + exit
                screenEditorSaveAndExit()
                return
            case 0x03, 0x19:                            // Ctrl-C / Ctrl-Y: discard
                screenEditorDiscardAndExit()
                return
            case 0x0D, 0x0A:                            // Enter: split line
                screenEditorSplitLine()
                dirty = true
            case 0x08, 0x7F:                            // BS / DEL
                screenEditorBackspace()
                dirty = true
            case 0x09:                                  // TAB -> 4 spaces
                for _ in 0..<4 { screenEditorInsert(" ") }
                dirty = true
            default:
                if b >= 0x20, b < 0x80 {
                    screenEditorInsert(Character(UnicodeScalar(b)))
                    dirty = true
                }
            }
            i += 1
        }
        if dirty { refreshScreenEditor() }
    }

    private func handleScreenEditorCSI(final: UInt8, params: [UInt8]) {
        switch final {
        case 0x41:                                      // A - Up
            if editorCursorRow > 0 {
                editorCursorRow -= 1
                editorCursorCol = min(editorCursorCol, screenEditorCurrentLineLength())
            }
        case 0x42:                                      // B - Down
            if editorCursorRow < editorBuffer.count - 1 {
                editorCursorRow += 1
                editorCursorCol = min(editorCursorCol, screenEditorCurrentLineLength())
            }
        case 0x43:                                      // C - Right
            let lineLen = screenEditorCurrentLineLength()
            if editorCursorCol < lineLen {
                editorCursorCol += 1
            } else if editorCursorRow < editorBuffer.count - 1 {
                editorCursorRow += 1
                editorCursorCol = 0
            }
        case 0x44:                                      // D - Left
            if editorCursorCol > 0 {
                editorCursorCol -= 1
            } else if editorCursorRow > 0 {
                editorCursorRow -= 1
                editorCursorCol = screenEditorCurrentLineLength()
            }
        case 0x48:                                      // H - Home
            editorCursorCol = 0
        case 0x46:                                      // F - End
            editorCursorCol = screenEditorCurrentLineLength()
        case 0x7E:                                      // ~ - vt220 keypad
            if params == [0x35] {                       // 5 ~ - Page Up
                screenEditorPageScroll(up: true)
            } else if params == [0x36] {                // 6 ~ - Page Down
                screenEditorPageScroll(up: false)
            } else if params == [0x31] {                // 1 ~ - Home
                editorCursorCol = 0
            } else if params == [0x34] {                // 4 ~ - End
                editorCursorCol = screenEditorCurrentLineLength()
            }
        default:
            break
        }
        editorCurrentLine = editorCursorRow + 1
    }

    private func screenEditorCurrentLineLength() -> Int {
        guard editorCursorRow >= 0, editorCursorRow < editorBuffer.count else { return 0 }
        return editorBuffer[editorCursorRow].count
    }

    private func screenEditorInsert(_ ch: Character) {
        while editorCursorRow >= editorBuffer.count { editorBuffer.append("") }
        var line = editorBuffer[editorCursorRow]
        let safeCol = max(0, min(editorCursorCol, line.count))
        let idx = line.index(line.startIndex, offsetBy: safeCol)
        line.insert(ch, at: idx)
        editorBuffer[editorCursorRow] = line
        editorCursorCol = safeCol + 1
        editorModified = true
    }

    private func screenEditorSplitLine() {
        while editorCursorRow >= editorBuffer.count { editorBuffer.append("") }
        let line = editorBuffer[editorCursorRow]
        let safeCol = max(0, min(editorCursorCol, line.count))
        let splitIdx = line.index(line.startIndex, offsetBy: safeCol)
        let head = String(line[..<splitIdx])
        let tail = String(line[splitIdx...])
        editorBuffer[editorCursorRow] = head
        editorBuffer.insert(tail, at: editorCursorRow + 1)
        editorCursorRow += 1
        editorCursorCol = 0
        editorModified = true
    }

    private func screenEditorBackspace() {
        guard editorCursorRow < editorBuffer.count else { return }
        if editorCursorCol > 0 {
            var line = editorBuffer[editorCursorRow]
            let safeCol = max(0, min(editorCursorCol, line.count))
            guard safeCol > 0 else { return }
            let idx = line.index(line.startIndex, offsetBy: safeCol - 1)
            line.remove(at: idx)
            editorBuffer[editorCursorRow] = line
            editorCursorCol = safeCol - 1
            editorModified = true
        } else if editorCursorRow > 0 {
            // Join with previous line.
            let current = editorBuffer.remove(at: editorCursorRow)
            editorCursorRow -= 1
            let prevLen = editorBuffer[editorCursorRow].count
            editorBuffer[editorCursorRow] += current
            editorCursorCol = prevLen
            editorModified = true
        }
    }

    private func screenEditorPageScroll(up: Bool) {
        let viewRows = Self.edtScreenViewRows
        if up {
            editorCursorRow = max(0, editorCursorRow - viewRows)
            editorViewTop   = max(0, editorViewTop - viewRows)
        } else {
            editorCursorRow = min(max(0, editorBuffer.count - 1), editorCursorRow + viewRows)
            let maxTop = max(0, editorBuffer.count - viewRows)
            editorViewTop = min(maxTop, editorViewTop + viewRows)
        }
        editorCursorCol = min(editorCursorCol, screenEditorCurrentLineLength())
    }

    private func screenEditorSaveAndExit() {
        let body = editorBuffer.joined(separator: "\n") + "\n"
        let lineCount = editorBuffer.count
        let name = editorFilename
        scriptStore.write(name: name, body: body)
        screenEditorTeardown()
        out("%EDT-I-WRITTEN, \(name) (\(lineCount) lines)\n")
        out(prompt)
    }

    private func screenEditorDiscardAndExit() {
        let modified = editorModified
        let name = editorFilename
        screenEditorTeardown()
        if modified {
            out("%EDT-W-DISCARD, changes to \(name) discarded\n")
        } else {
            out("%EDT-I-NOCHANGE, no changes to \(name)\n")
        }
        out(prompt)
    }

    private func screenEditorTeardown() {
        editorActive = false
        editorScreenMode = false
        editorBuffer = []
        editorFilename = ""
        editorModified = false
        editorCursorRow = 0
        editorCursorCol = 0
        editorViewTop = 0
        liveMode = .none
        exitLiveScreen()
        prompt = editorPreviousPrompt.isEmpty ? "$ " : editorPreviousPrompt
    }
}
