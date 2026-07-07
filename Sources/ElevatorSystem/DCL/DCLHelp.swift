import Foundation

// The interactive HELP facility and SELFTEST.
//
// HELP works the way OpenVMS HELP does. Typed at an interactive prompt it
// enters a browse loop: it displays a topic, lists the subtopics available
// beneath it ("Additional information available:"), and prompts for the
// next one ("Topic?" at the root, "SHOW Subtopic?" one level down, and so
// on). Topic names may be abbreviated; an asterisk lists or globs; a
// question mark redisplays; pressing RETURN moves up one level (and exits
// from the top); CTRL/Z exits from anywhere.
//
// The content is a parsed help library (see DCLHelpLibrary.swift /
// DCLHelpText.swift), authored in genuine VMS `.HLP` format. This file is
// just the reader's front end: it walks the tree, renders each node with
// the level-based indentation VMS uses, and runs the prompt loop by
// rerouting DCLEngine.submit() through runHelpLine() while `helpActive` is
// set -- the same pattern the MAIL and EDT subshells use.
extension DCLEngine {

    // MARK: -- library

    /// The parsed help library, built once from the `.HLP` source with the
    /// live node / user / version / path substitutions folded in.
    var helpRoot: HelpNode {
        if let cached = helpRootCache { return cached }
        let subs = [
            "$OSTITLE$": osTitle,
            "$OSVERSION$": osVersion,
            "$NODE$": nodeName,
            "$USER$": username,
            "$STOREROOT$": scriptStore.rootPath,
        ]
        let root = HelpLibrary.parse(source: HelpLibrary.source, substitutions: subs)
        helpRootCache = root
        return root
    }

    // MARK: -- entry point (called from execute())

    /// Handle a HELP command. In an interactive session this displays the
    /// requested topic and opens the Topic?/Subtopic? browse loop; inside a
    /// command procedure or during SELFTEST it prints once and returns
    /// (real HELP does not prompt when it is not talking to a terminal).
    func helpCommand(_ cmd: Parsed) -> String {
        let keys = cmd.positional + cmd.qualifiers.map { $0.name }
        if dryRun || scriptDepth > 0 {
            return helpOneShot(keys: keys)
        }
        helpActive = true
        helpPreviousPrompt = prompt
        helpPath = []
        let body = helpNavigate(keys: keys)
        updateHelpPrompt()
        return body
    }

    /// Non-interactive HELP: resolve the whole key path from the root once
    /// and return the rendered text, touching none of the browse state.
    private func helpOneShot(keys: [String]) -> String {
        if keys.isEmpty { return renderTarget(path: []) }
        var node = helpRoot
        var path: [String] = []
        for key in keys {
            let matches = node.child(matching: key)
            if matches.isEmpty { return sorry(path: path, key: key) }
            if matches.count > 1 { return renderMultiple(parentPath: path, nodes: matches) }
            node = matches[0]
            path.append(node.key)
        }
        return renderTarget(path: path)
    }

    // MARK: -- browse loop (called from submit() while helpActive)

    /// Route one input line while the HELP browser owns the prompt. Returns
    /// the text to display; submit() then emits the (updated) prompt.
    func runHelpLine(_ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // RETURN moves up one level; RETURN at the top level exits HELP.
        if line.isEmpty {
            if helpPath.isEmpty { return helpExit() }
            helpPath.removeLast()
            updateHelpPrompt()
            return ""
        }
        // "?" redisplays the current level without moving.
        if line == "?" {
            return renderTarget(path: helpPath)
        }
        let keys = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let body = helpNavigate(keys: keys)
        updateHelpPrompt()
        return body
    }

    /// Leave the HELP browser and restore the DCL prompt.
    @discardableResult
    func helpExit() -> String {
        helpActive = false
        prompt = helpPreviousPrompt.isEmpty ? "$ " : helpPreviousPrompt
        return ""
    }

    /// Resolve `keys` relative to the current position, display the result,
    /// and update `helpPath`. Abbreviations descend; an ambiguous or
    /// wildcard final key displays every match; an unknown key reports
    /// "Sorry, no documentation on ...".
    private func helpNavigate(keys: [String]) -> String {
        if keys.isEmpty { return renderTarget(path: helpPath) }
        var node = nodeAt(helpPath)
        var path = helpPath
        for key in keys {
            let matches = node.child(matching: key)
            if matches.isEmpty {
                helpPath = path
                return sorry(path: path, key: key)
            }
            if matches.count > 1 {
                helpPath = path
                return renderMultiple(parentPath: path, nodes: matches)
            }
            node = matches[0]
            path.append(node.key)
        }
        // Descend into the target if it has subtopics; otherwise stay at the
        // parent's prompt (the RETURN-to-go-up behaviour of real HELP).
        helpPath = node.children.isEmpty ? Array(path.dropLast()) : path
        return renderTarget(path: path)
    }

    /// Prompt string for the current position: "Topic? " at the root,
    /// "SHOW Subtopic? " one level down, and so on.
    private func updateHelpPrompt() {
        prompt = helpPath.isEmpty ? "Topic? " : helpPath.joined(separator: " ") + " Subtopic? "
    }

    // MARK: -- tree walk

    /// The node at an absolute path from the root (the root itself for an
    /// empty path). Stops at the deepest key that resolves.
    private func nodeAt(_ path: [String]) -> HelpNode {
        var node = helpRoot
        for key in path {
            guard let next = node.children.first(where: { $0.key.uppercased() == key.uppercased() }) else { break }
            node = next
        }
        return node
    }

    // MARK: -- rendering

    /// Render a topic at an absolute path: each ancestor key as a bare
    /// header, then the target key, its help text, and -- when it has
    /// subtopics -- the "Additional information available:" list. Indent
    /// increases 2 spaces per level, exactly as VMS HELP lays it out.
    private func renderTarget(path: [String]) -> String {
        let level = max(1, path.count)
        let node: HelpNode = path.isEmpty ? helpRoot : nodeAt(path)
        let keyword = path.last ?? "HELP"

        var s = "\n"
        // Ancestor headers (every key except the last).
        if path.count > 1 {
            for i in 0..<(path.count - 1) {
                s += indent(2 * i) + path[i] + "\n\n"
            }
        }
        // Target keyword header.
        s += indent(2 * (level - 1)) + keyword + "\n\n"
        // Body text, indented one level deeper than the keyword.
        if !node.text.isEmpty {
            s += renderBody(node.text, level: level) + "\n"
        }
        // Subtopic list.
        if !node.children.isEmpty {
            s += "\n" + indent(2 * (level - 1)) + "Additional information available:\n\n"
            s += columns(node.children.map { $0.key }, indent: 2 * level)
        }
        return s
    }

    /// Render several sibling matches (ambiguous abbreviation or wildcard)
    /// one after another beneath their shared parent.
    private func renderMultiple(parentPath: [String], nodes: [HelpNode]) -> String {
        nodes.sorted { $0.key.uppercased() < $1.key.uppercased() }
            .map { renderTarget(path: parentPath + [$0.key]) }
            .joined()
    }

    /// Body text indented to a level. Blank lines stay blank; every other
    /// line gets the level indent prepended to whatever indentation the
    /// `.HLP` source already carried.
    private func renderBody(_ text: String, level: Int) -> String {
        let pad = indent(2 * level)
        return text.components(separatedBy: "\n")
            .map { $0.isEmpty ? "" : pad + $0 }
            .joined(separator: "\n")
    }

    /// Lay subtopic keys out in left-aligned columns that fit the terminal
    /// width, sorted the way HELP sorts them.
    private func columns(_ keys: [String], indent leftPad: Int) -> String {
        guard !keys.isEmpty else { return "" }
        let sorted = keys.sorted { $0.uppercased() < $1.uppercased() }
        let colWidth = (sorted.map { $0.count }.max() ?? 0) + 3
        let width = terminalWidth > 20 ? terminalWidth : 80
        let perRow = max(1, (width - leftPad) / colWidth)
        let pad = indent(leftPad)

        var rows: [String] = []
        var i = 0
        while i < sorted.count {
            let slice = sorted[i..<min(i + perRow, sorted.count)]
            var row = pad
            for key in slice {
                row += key.padding(toLength: colWidth, withPad: " ", startingAt: 0)
            }
            rows.append(trimTrailing(row))
            i += perRow
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// "Sorry, no documentation on ..." for an unknown key, naming the full
    /// path the operator asked for.
    private func sorry(path: [String], key: String) -> String {
        let full = (path + [key]).joined(separator: " ").uppercased()
        return "\nSorry, no documentation on \(full)\n"
    }

    private func indent(_ n: Int) -> String {
        String(repeating: " ", count: max(0, n))
    }

    private func trimTrailing(_ s: String) -> String {
        String(s.reversed().drop(while: { $0 == " " }).reversed())
    }

    // MARK: -- SELFTEST

    /// SELFTEST -- drives every documented DCL verb once and prints a
    /// one-line pass / fail summary per command. A clean run means every
    /// verb dispatches and returns without panicking.
    func selfTest() async -> String {
        let verbs: [String] = [
            "SHOW PROCESS", "SHOW PROCESS/ALL",
            "SHOW SYSTEM", "SHOW USERS", "SHOW DEVICES", "SHOW MEMORY",
            "SHOW TIME", "SHOW NETWORK", "SHOW QUEUE", "SHOW ALARMS",
            "SHOW LOGICAL", "SHOW LOGICAL/PROCESS",
            "SHOW SYMBOL", "SHOW SYMBOL $STATUS", "SHOW SYMBOL $SEVERITY",
            "SHOW ERROR", "SHOW STATUS", "SHOW LICENSE",
            "SHOW CPU", "SHOW DEFAULT", "SHOW QUOTA",
            "SHOW PROTECTION", "SHOW TERMINAL", "SHOW WORKING_SET",
            "SHOW VERSION", "SHOW RMS_DEFAULT", "SHOW INTRUSION",
            "SHOW CLUSTER", "SHOW CONNECTIONS", "SHOW AUDIT",
            "SET DEFAULT [-]", "SET TERMINAL/WIDTH=80",
            "SET PROMPT=\"DCL$ \"", "SET ON", "SET NOON",
            "SET PROCESS",
            "DIRECTORY", "DIRECTORY/SIZE/DATE",
            "TYPE STARTUP.COM", "TYPE EVENTLOG.LOG", "TYPE PEERS.DAT",
            "TYPE NOSUCHFILE.TXT",
            "WRITE SYS$OUTPUT \"selftest\"",
            "ASSIGN DKA0: TEST_DISK", "DEASSIGN TEST_DISK",
            "DEFINE TEST_LOG \"value\"", "DEASSIGN TEST_LOG",
            "MAIL", "MAIL DIRECTORY", "MAIL READ",
            "MAIL SEND OPERATOR \"selftest\" \"hello\"",
            "PHONE", "FINGER", "FINGER OPERATOR",
            "RECALL", "RECALL/ALL", "RECALL 1",
            "SPAWN", "ATTACH", "WAIT 00:00:01",
            "ACCOUNTING", "INSTALL", "PRODUCT",
            "SEARCH FILE.TXT \"foo\"", "PRINT REPORT.LIS",
            "SUBMIT JOB.COM",
            "CREATE NEWFILE.TXT", "CONTINUE",
            "COPY A.TXT B.TXT", "DELETE OLD.TXT", "PURGE TMP.TMP",
            "RENAME A.TXT B.TXT", "APPEND A.TXT B.TXT",
            "EDIT FILE.TXT", "DIFFERENCES A.TXT B.TXT",
            "RUN PROG.EXE", "RUN BRAKE_TEST", "RUN DOOR_TEST",
            "RUN WEIGHT_CAL", "RUN HALL_LAMP_TEST",
            "RUN WEIGHT_CAL/NODE=LOCAL", "RUN BRAKE_TEST/NODE=L",
            "ANALYZE/ERROR_LOG", "ANALYZE/AUDIT", "ANALYZE/IMAGE",
            "INITIALIZE DKA0:",
            "MOUNT DKA0:", "MOUNT MUA0: ELEV_BACKUP",
            "DISMOUNT MUA0:",
            "BACKUP CAB$DATA: MUA0:ELEV.BCK",
            "PATCH FILE", "DEPOSIT 100",
            "EXAMINE 1000", "EXAMINE ^X100",
            "ALLOCATE MUA0:", "ALLOCATE TT0:",
            "DEALLOCATE MUA0:", "DEALLOCATE/ALL",
            "REPLY \"go ahead\"", "REQUEST \"need maintenance\"",
            "ACKNOWLEDGE ALARM ALL",
            "@STARTUP",
            "HELP", "HELP SHOW", "HELP SHOW PROCESS", "HELP SET",
            "HELP MONITOR", "HELP LPDCP", "HELP LPDCP SHOW CAB",
            "HELP ACKNOWLEDGE", "HELP CALL", "HELP ELEVATOR",
            "HELP SCRIPTING", "HELP TUTORIAL", "HELP HINTS",
            "HELP INSTRUCTIONS", "HELP NOSUCHTOPIC",
        ]

        var passed = 0
        var lines: [String] = []
        lines.append("\nSELFTEST -- driving every documented verb (LOGOUT/EXIT/CLEAR excluded)\n")
        dryRun = true
        defer { dryRun = false }
        for v in verbs {
            let body = await execute(v)
            let chars = body.count
            let badFmt = body.contains("(null)") || body.contains("0x") && body.contains("Optional")
            let status: String
            if chars == 0 {
                status = "ok (no output)"
            } else if badFmt {
                status = "BAD-FMT"
            } else {
                status = "ok"
            }
            if status.hasPrefix("ok") { passed += 1 }
            let label = v.padding(toLength: 38, withPad: " ", startingAt: 0)
            lines.append(String(format: "  %@  %@  (%d chars)", label, status.padding(toLength: 14, withPad: " ", startingAt: 0), chars))
        }
        lines.append("")
        lines.append("  \(passed)/\(verbs.count) verbs returned cleanly.")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
