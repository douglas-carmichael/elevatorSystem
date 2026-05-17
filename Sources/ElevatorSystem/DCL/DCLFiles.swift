import Foundation

// File-oriented and communication verbs: DIR / TYPE / WRITE / ASSIGN
// / DEFINE / DEASSIGN / MAIL / PHONE / FINGER / RECALL / SPAWN / ATTACH
// / WAIT / ACCOUNTING / INSTALL / PRODUCT / SEARCH / PRINT / SUBMIT /
// CREATE.
extension DCLEngine {
    func directoryCmd(_ cmd: Parsed) -> String {
        let withSize = cmd.hasQualifier("SIZE", min: 3) || cmd.hasQualifier("FULL",  min: 3)
        let withDate = cmd.hasQualifier("DATE", min: 3) || cmd.hasQualifier("FULL",  min: 3)

        struct Entry { let name: String; let used: Int; let alloc: Int; let when: Date }
        var files: [Entry] = [
            Entry(name: "CONTROL.EXE;42",  used: 128, alloc: 128, when: bootTime),
            Entry(name: "DOORS.EXE;19",    used:  42, alloc:  48, when: bootTime.addingTimeInterval(2)),
            Entry(name: "SCHED.EXE;7",     used:  18, alloc:  24, when: bootTime.addingTimeInterval(4)),
            Entry(name: "EVENTLOG.LOG;91", used: 822, alloc: 824, when: Date().addingTimeInterval(-60)),
            Entry(name: "PEERS.DAT;14",    used:   6, alloc:   8, when: Date()),
        ]
        // User-created .COM files from disk get folded into the listing.
        let scripts = scriptStore.list()
        if scripts.isEmpty {
            files.insert(Entry(name: "STARTUP.COM;3", used: 4, alloc: 8,
                               when: bootTime.addingTimeInterval(-2)), at: 3)
        } else {
            for info in scripts.sorted(by: { $0.name < $1.name }) {
                let blocks = max(1, (info.bytes + 511) / 512)
                files.append(Entry(name: "\(info.name);\(info.version)",
                                   used: blocks, alloc: blocks,
                                   when: info.modified))
            }
        }

        var s = "\nDirectory \(defaultDevice)\(defaultDirectory)\n\n"
        for f in files {
            var line = f.name.padding(toLength: 22, withPad: " ", startingAt: 0)
            if withSize {
                line += String(format: "%4d/%-4d  ", f.used, f.alloc)
            }
            if withDate {
                line += stamp(f.when)
            }
            s += line + "\n"
        }
        let totalU = files.reduce(0) { $0 + $1.used  }
        let totalA = files.reduce(0) { $0 + $1.alloc }
        if withSize {
            s += "\nTotal of \(files.count) files, \(totalU)/\(totalA) blocks.\n"
        } else {
            s += "\nTotal of \(files.count) files.\n"
        }
        return s
    }

    func typeCmd(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.first else {
            return "%DCL-W-MISSPRM, missing required parameter on TYPE\n"
        }
        let key = target.uppercased()
        // First look on disk for user-edited content.
        if let body = scriptStore.read(name: scriptStore.normalize(key)) {
            return body.hasSuffix("\n") ? body : body + "\n"
        }
        if key.contains("STARTUP") {
            return defaultStartupCom()
        }
        if key.contains("EVENTLOG") {
            var s = "\n"
            for off in stride(from: 600, to: 0, by: -90) {
                s += "\(stamp(Date().addingTimeInterval(-Double(off))))  CAB_01_TASK     INFO   floor reached, doors opening\n"
                s += "\(stamp(Date().addingTimeInterval(-Double(off - 30))))  DOOR_SVC_01     INFO   doors fully open, dwell timer armed\n"
            }
            return s
        }
        if key.contains("PEERS") {
            return "%TYPE-W-NOTASCII, file \(target) does not contain ASCII data\n"
        }
        fail("RMS-E-FNF", "%X00018292")
        return "%TYPE-W-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(target) as input\n-RMS-E-FNF, file not found\n"
    }

    /// Canonical contents of STARTUP.COM used when the operator hasn't
    /// edited their own copy. Mirrors a real SYS$STARTUP for the elevator
    /// controller cluster.
    func defaultStartupCom() -> String {
        var s = "\n$ ! ELEVATOR$ROOT:[CONTROL]STARTUP.COM\n"
        s += "$ ! Boot-time initialization for the elevator controller cluster\n"
        s += "$ SET NOON\n"
        s += "$ DEFINE/SYSTEM ELEVATOR$ROOT  DISK$ELEV_SYS:[ELEVATOR]\n"
        s += "$ DEFINE/SYSTEM CAB$DATA       DISK$ELEV_DATA:[CABS]\n"
        s += "$ DEFINE/SYSTEM DOOR$STATE     DISK$ELEV_DOORS:[STATE]\n"
        s += "$ RUN/DETACHED ELEVATOR$ROOT:[CONTROL]CONTROL.EXE -\n"
        s += "$       /PROCESS_NAME=ELEVATOR_CTL  /PRIORITY=8\n"
        s += "$ RUN/DETACHED ELEVATOR$ROOT:[CONTROL]DOORS.EXE -\n"
        s += "$       /PROCESS_NAME=DOOR_SVC      /PRIORITY=6\n"
        s += "$ INSTALL ADD ELEVATOR$ROOT:[CONTROL]CONTROL.EXE /OPEN/SHARED\n"
        s += "$ EXIT\n"
        return s
    }

    func writeCmd(_ cmd: Parsed) -> String {
        // WRITE SYS$OUTPUT "literal"
        guard cmd.positional.count >= 2 else {
            return "%DCL-W-MISSPRM, missing required parameter on WRITE\n"
        }
        let dest = cmd.positional[0].uppercased()
        let payload = cmd.positional.dropFirst().joined(separator: " ")
        let cleaned = payload.replacingOccurrences(of: "\"", with: "")
        if dest.hasSuffix("SYS$OUTPUT") || dest == "SYS$OUTPUT" || dest == "SYS$ERROR" {
            return cleaned + "\n"
        }
        return "%WRITE-F-WRITERR, file \(dest) is not opened for output\n"
    }

    func assignCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%DCL-W-MISSPRM, missing required parameter on ASSIGN\n"
        }
        // ASSIGN equiv-name  logical-name   (DEC order)
        // DEFINE logical-name equiv-name    (reverse)
        let isDefine = cmd.verb == "DEFINE" || matches(cmd.verb, "DEFINE")
        let name: String
        let equiv: String
        if isDefine {
            name = cmd.positional[0].uppercased()
            equiv = cmd.positional[1]
        } else {
            equiv = cmd.positional[0]
            name = cmd.positional[1].uppercased()
        }
        processLogicals[name] = equiv
        return ""
    }

    func deassignCmd(_ cmd: Parsed) -> String {
        guard let name = cmd.positional.first?.uppercased() else {
            return "%DCL-W-MISSPRM, missing required parameter on DEASSIGN\n"
        }
        if processLogicals.removeValue(forKey: name) != nil {
            return ""
        }
        fail("SYSTEM-F-NOLOGNAM", "%X0000020A")
        return "%SYSTEM-F-NOLOGNAM, no logical name match\n"
    }

    // Real DCL MAIL is a fully interactive subshell; the simulator
    // takes positional subverbs (DIRECTORY / READ / DELETE / SEND) so
    // a script or operator can drive it in one line. The shape of the
    // output mirrors what a real `MAIL>` prompt prints for each subverb.
    func mailCmd(_ cmd: Parsed) -> String {
        let banner = "\n        \(osTitle) Personal Mail Utility\n        \(stamp(Date()))\n\n"
        guard let head = cmd.positional.first?.uppercased() else {
            // `MAIL` with no args: banner + status line, auto-EXIT.
            let unread = mailbox.filter { !$0.read }.count
            var s = banner
            if mailbox.isEmpty {
                s += "You have no messages.\n"
            } else if unread == 0 {
                s += "You have \(mailbox.count) message\(mailbox.count == 1 ? "" : "s") (0 new).\n"
            } else {
                s += "You have \(unread) new message\(unread == 1 ? "" : "s") (\(mailbox.count) total).\n"
                s += "MAIL>DIRECTORY\n"
                s += mailDirectoryTable()
            }
            s += "MAIL>EXIT\n"
            return s
        }
        let rest = Array(cmd.positional.dropFirst())
        switch head {
        case "DIR", "DIRECTORY":
            if mailbox.isEmpty {
                return banner + "%MAIL-E-NOMSGS, no messages\nMAIL>EXIT\n"
            }
            return banner + "MAIL>DIRECTORY\n" + mailDirectoryTable() + "MAIL>EXIT\n"

        case "READ":
            let idx: Int
            if let raw = rest.first, let n = Int(raw) {
                guard let i = mailbox.firstIndex(where: { $0.id == n }) else {
                    return banner + "%MAIL-E-NOMSG, no message with id \(n)\nMAIL>EXIT\n"
                }
                idx = i
            } else {
                guard let i = mailbox.firstIndex(where: { !$0.read })
                    ?? (mailbox.isEmpty ? nil : mailbox.count - 1) else {
                    return banner + "%MAIL-E-NOMSGS, no messages\nMAIL>EXIT\n"
                }
                idx = i
            }
            mailbox[idx].read = true
            let m = mailbox[idx]
            var s = banner + "MAIL>READ\n"
            s += "From:    \(m.from)\n"
            s += "Date:    \(stamp(m.received))\n"
            s += "Subject: \(m.subject)\n\n"
            s += m.body
            if !m.body.hasSuffix("\n") { s += "\n" }
            s += "MAIL>EXIT\n"
            return s

        case "DELETE":
            guard let raw = rest.first, let n = Int(raw) else {
                return banner + "%MAIL-F-NOMSG, message id required\nMAIL>EXIT\n"
            }
            guard let i = mailbox.firstIndex(where: { $0.id == n }) else {
                return banner + "%MAIL-E-NOMSG, no message with id \(n)\nMAIL>EXIT\n"
            }
            mailbox.remove(at: i)
            return banner + "MAIL>DELETE \(n)\n%MAIL-I-DELETED, message \(n) deleted\nMAIL>EXIT\n"

        case "SEND":
            // SEND addr "subject" "body..." -- everything after the
            // address is collapsed into the body if subject quotes
            // aren't supplied, matching the way real MAIL prompts
            // for To / Subj / Text in sequence.
            guard let addr = rest.first else {
                return banner + "%MAIL-F-NORECIP, address required\nMAIL>EXIT\n"
            }
            let tail = Array(rest.dropFirst())
            let subject: String
            let body: String
            if tail.count >= 2 {
                subject = unquoteMail(tail[0])
                body = tail.dropFirst().map { unquoteMail($0) }.joined(separator: " ")
            } else if let only = tail.first {
                subject = "(no subject)"
                body = unquoteMail(only)
            } else {
                subject = "(no subject)"
                body = ""
            }
            // Loopback to local inbox: real MAIL would hand off to the
            // mail-router process; here we deliver to ourselves so the
            // operator can demonstrate the SEND -> READ round-trip.
            mailbox.append(MailMessage(id: nextMailId,
                                       from: username,
                                       subject: subject,
                                       body: body,
                                       received: Date(),
                                       read: false))
            nextMailId += 1
            return banner + "MAIL>SEND \(addr)\n%MAIL-S-SENT, message queued for \(addr.uppercased())\nMAIL>EXIT\n"

        default:
            return banner + "%MAIL-W-UNKKEYWORD, unknown keyword: \(head)\nMAIL>EXIT\n"
        }
    }

    private func mailDirectoryTable() -> String {
        var s = "  #   From            Date              Subject\n"
        s += "  --  --------------  ----------------  --------------------------------\n"
        for m in mailbox {
            let mark = m.read ? " " : "*"
            let from = m.from.padding(toLength: 14, withPad: " ", startingAt: 0)
            let when = stamp(m.received)
                .padding(toLength: 16, withPad: " ", startingAt: 0)
            let subj = m.subject.count > 32
                ? String(m.subject.prefix(29)) + "..."
                : m.subject
            s += String(format: "%@%3d  %@  %@  %@\n", mark, m.id, from, when, subj)
        }
        return s
    }

    private func unquoteMail(_ s: String) -> String {
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    func phoneCmd() -> String {
        return "%PHONE-W-NOTAVAIL, phone facility is not enabled on this node\n"
    }

    func fingerCmd(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.first else {
            var s = "\nUser            Personal Name                    Job Type\n"
            s += "\(username.padding(toLength: 16, withPad: " ", startingAt: 0))Console operator                Interactive\n"
            for peer in network?.peers ?? [] {
                let upper = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
                let nm = String(upper.prefix(12)).padding(toLength: 16, withPad: " ", startingAt: 0)
                s += "\(nm)Remote elevator peer            DECnet\n"
            }
            return s
        }
        return "\n  \(target.uppercased())          (no further information available)\n"
    }

    func recallCmd(_ cmd: Parsed) -> String {
        if cmd.hasQualifier("ALL", min: 1) || cmd.hasQualifier("ERASE", min: 3) {
            if cmd.hasQualifier("ERASE", min: 3) {
                history.removeAll()
                return ""
            }
            var s = "\n"
            for (i, h) in history.enumerated() {
                s += String(format: "  %3d  %@\n", i + 1, h)
            }
            if history.isEmpty { s += "  (no commands in recall buffer)\n" }
            return s
        }
        if let n = cmd.positional.first, let idx = Int(n) {
            let one = idx - 1
            if one >= 0 && one < history.count {
                return "  \(history[one])\n"
            }
            return "%RECALL-W-NOMATCH, no command matches recall request\n"
        }
        if let last = history.dropLast().last {
            return "  \(last)\n"
        }
        return "%RECALL-W-NOMATCH, no command matches recall request\n"
    }

    func spawnCmd() -> String {
        return "%DCL-E-OPENIN, error opening SYS$INPUT as input\n-DCL-E-NOSUBPROC, subprocess facility unavailable in this shell\n"
    }

    func attachCmd() -> String {
        return "%DCL-W-ATTNOPAR, no parent process to attach to\n"
    }

    // WAIT delta-time -- real VMS pauses the process for the supplied
    // delta. We parse HH:MM:SS / MM:SS / SS forms (optionally with a
    // fractional-second tail) and await `Task.sleep`, so a command
    // procedure that issues `WAIT 00:00:02` actually gives the elevator
    // physics two real seconds to evolve before the next line runs.
    func waitCmd(_ cmd: Parsed) async -> String {
        guard let raw = cmd.positional.first else { return "" }
        let seconds = parseDeltaTime(raw)
        guard seconds > 0 else { return "" }
        let nanos = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        return ""
    }

    private func parseDeltaTime(_ raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Plain decimal seconds: "2", "2.5"
        if let bare = Double(trimmed) { return bare }
        // [DDD] HH:MM:SS[.cc] with optional day prefix.
        let dayPart: Substring
        let timePart: Substring
        if let space = trimmed.firstIndex(of: " ") {
            dayPart = trimmed[..<space]
            timePart = trimmed[trimmed.index(after: space)...]
        } else {
            dayPart = ""
            timePart = Substring(trimmed)
        }
        let days = Double(dayPart) ?? 0
        let pieces = timePart.split(separator: ":")
        let h: Double, m: Double, s: Double
        switch pieces.count {
        case 3:
            h = Double(pieces[0]) ?? 0
            m = Double(pieces[1]) ?? 0
            s = Double(pieces[2]) ?? 0
        case 2:
            h = 0
            m = Double(pieces[0]) ?? 0
            s = Double(pieces[1]) ?? 0
        case 1:
            h = 0; m = 0
            s = Double(pieces[0]) ?? 0
        default:
            return 0
        }
        return days * 86_400 + h * 3_600 + m * 60 + s
    }

    func accountingCmd() -> String {
        let upS = Int(host.uptime())
        var s = "\nFrom: \(stamp(bootTime))    To: \(stamp(Date()))\n\n"
        s += "                          Image      CPU         Direct    Buffered\n"
        s += "Account     Username     Activations Time         I/O        I/O\n"
        s += "----------  ------------ ----------- -----------  --------   --------\n"
        let userPad = username.padding(toLength: 12, withPad: " ", startingAt: 0)
        s += String(format: "CONTROL_RM  %@     %5d     0 00:%02d:%02d   %7d   %7d\n",
                    userPad, max(1, upS / 600), (upS / 60) % 60, upS % 60, upS / 4, upS / 8)
        return s
    }

    // INSTALL maintains a session-scoped set of "known" images. STARTUP.COM
    // runs `INSTALL ADD ELEVATOR$ROOT:[CONTROL]CONTROL.EXE /OPEN/SHARED` --
    // that ADD now actually mutates installedImages, so a subsequent
    // INSTALL LIST reflects what's been installed during this session.
    func installCmd(_ cmd: Parsed) -> String {
        let head = cmd.positional.first?.uppercased() ?? "LIST"
        let rest = Array(cmd.positional.dropFirst())

        switch head {
        case "ADD", "CREATE", "REPLACE":
            guard let path = rest.first else {
                return "%INSTALL-F-NOPARM, file specification required\n"
            }
            let base = installBaseName(path)
            // Derive flags from /qualifiers on the verb (/OPEN, /SHARED,
            // /HEADER_RESIDENT, /PROTECT, etc) -- the real INSTALL prints
            // a similar abbreviated flag list in its LIST output.
            let flags = installFlags(from: cmd.qualifiers)
            // Replace existing entry with same base name, or append.
            if let idx = installedImages.firstIndex(where: { installBaseName($0.name) == base }) {
                installedImages[idx] = InstalledImage(name: base, flags: flags)
            } else {
                installedImages.append(InstalledImage(name: base, flags: flags))
            }
            return "%INSTALL-I-LOADED, \(base) installed (\(flags))\n"

        case "REMOVE", "DELETE":
            guard let path = rest.first else {
                return "%INSTALL-F-NOPARM, file specification required\n"
            }
            let base = installBaseName(path)
            guard let idx = installedImages.firstIndex(where: { installBaseName($0.name) == base }) else {
                return "%INSTALL-W-NOTKNOWN, \(base) is not a known image\n"
            }
            installedImages.remove(at: idx)
            return "%INSTALL-I-REMOVED, \(base) removed from known-image table\n"

        case "LIST":
            fallthrough
        default:
            var s = "\nDISK$ELEV_SYS:<SYS0.SYSCOMMON.SYSEXE>.EXE\n"
            if installedImages.isEmpty {
                s += "  (no images installed)\n"
            } else {
                for image in installedImages {
                    let nm = image.name.padding(toLength: 34, withPad: " ", startingAt: 0)
                    s += "  \(nm)\(image.flags)\n"
                }
            }
            return s
        }
    }

    private func installBaseName(_ path: String) -> String {
        // Strip device:[directory] and version; keep "FOO.EXE;n" or
        // synthesize ";1" if none was supplied, so the LIST output is
        // consistent with what real INSTALL prints.
        var s = path.uppercased()
        if let bracket = s.lastIndex(of: "]") { s = String(s[s.index(after: bracket)...]) }
        if let colon = s.lastIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
        if !s.contains(";") { s += ";1" }
        return s
    }

    private func installFlags(from qualifiers: [(name: String, value: String?)]) -> String {
        var flags: [String] = []
        var hasOpen = false
        for q in qualifiers {
            switch q.name.uppercased() {
            case let n where n.hasPrefix("OPEN"):      flags.append("Open"); hasOpen = true
            case let n where n.hasPrefix("SHAR"):      flags.append("Shar")
            case let n where n.hasPrefix("HEAD"):      flags.append("Hdr")
            case let n where n.hasPrefix("PROT"):      flags.append("Prot")
            case let n where n.hasPrefix("WRIT"):      flags.append("Wrt")
            case let n where n.hasPrefix("EXEC"):      flags.append("Exec")
            case let n where n.hasPrefix("PRIV"):      flags.append("Priv")
            default: break
            }
        }
        if !hasOpen && flags.isEmpty {
            flags = ["Lnkbl"]
        } else if !flags.contains("Hdr") {
            flags.append("Lnkbl")
        }
        return flags.joined(separator: " ")
    }

    func productCmd() -> String {
        var s = "\n----------------------------------- ----------- --------- --------\n"
        s += "PRODUCT                              KIT TYPE   STATE     RELEASE\n"
        s += "----------------------------------- ----------- --------- --------\n"
        s += "VSI OPENVMS                          Full LP    Installed \(osVersion)\n"
        s += "VSI OPENVMS DECNET-PLUS              Full LP    Installed \(osVersion)\n"
        s += "LPD LPD-DIAG                         Full LP    Installed V1.4\n"
        s += "----------------------------------- ----------- --------- --------\n"
        return s
    }

    func searchCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%SEARCH-F-NOFILES, no files specified\n"
        }
        let file = cmd.positional[0]
        let normalized = scriptStore.normalize(file)
        guard let body = scriptStore.read(name: normalized) else {
            return "%SEARCH-E-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(file) as input\n-RMS-E-FNF, file not found\n"
        }
        let needles = Array(cmd.positional.dropFirst()).map { unquote($0) }
        let exact = cmd.hasQualifier("EXACT", min: 3)
        let lines = body.components(separatedBy: "\n")
        var hits = 0
        var out = ""
        for (idx, line) in lines.enumerated() {
            let hay = exact ? line : line.lowercased()
            let matched = needles.contains { needle in
                let pin = exact ? needle : needle.lowercased()
                return hay.contains(pin)
            }
            if matched {
                out += String(format: "%6d  %@\n", idx + 1, line)
                hits += 1
            }
        }
        if hits == 0 {
            return "%SEARCH-I-NOMATCHES, no strings matched in \(defaultDevice)\(defaultDirectory)\(normalized)\n"
        }
        out += "\n***************\n\(defaultDevice)\(defaultDirectory)\(normalized);1\n\(hits) occurrence\(hits == 1 ? "" : "s") matched\n"
        return out
    }

    func printCmd(_ cmd: Parsed) -> String {
        guard let file = cmd.positional.first else {
            return "%PRINT-F-NOPARM, missing parameter on PRINT\n"
        }
        let normalized = scriptStore.normalize(file)
        guard scriptStore.read(name: normalized) != nil else {
            return "%PRINT-E-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(file) as input\n-RMS-E-FNF, file not found\n"
        }
        let job = Int.random(in: 1000...9999)
        return "Job \(file) (queue SYS$PRINT, entry \(job)) holding\n"
    }

    // ------------------------------------------------------------------
    // COPY / RENAME / APPEND / PURGE / DIFFERENCES
    //
    // These previously short-circuited to a fake RMS-E-FNF regardless of
    // whether the file existed. The scriptStore can actually round-trip
    // .COM content, so wire the verbs up to read/write through it; for
    // anything outside the user-writable .COM namespace the existing
    // read-only contract still applies and we fall back to RMS-E-FNF.

    func copyCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%COPY-F-NOFILES, two file parameters required\n"
        }
        let src = cmd.positional[0]
        let dst = cmd.positional[1]
        let srcNorm = scriptStore.normalize(src)
        guard let body = scriptStore.read(name: srcNorm) else {
            return "%COPY-E-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(src) as input\n-RMS-E-FNF, file not found\n"
        }
        let dstNorm = scriptStore.normalize(dst)
        guard scriptStore.write(name: dstNorm, body: body) else {
            return "%COPY-E-OPENOUT, error opening \(defaultDevice)\(defaultDirectory)\(dst) as output\n"
        }
        return "%COPY-S-COPIED, \(defaultDevice)\(defaultDirectory)\(srcNorm);1 copied to \(defaultDevice)\(defaultDirectory)\(dstNorm);1 (1 block)\n"
    }

    func renameCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%RENAME-F-NOFILES, two file parameters required\n"
        }
        let src = cmd.positional[0]
        let dst = cmd.positional[1]
        let srcNorm = scriptStore.normalize(src)
        guard let body = scriptStore.read(name: srcNorm) else {
            return "%RENAME-E-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(src) as input\n-RMS-E-FNF, file not found\n"
        }
        let dstNorm = scriptStore.normalize(dst)
        guard scriptStore.write(name: dstNorm, body: body) else {
            return "%RENAME-E-OPENOUT, error opening \(defaultDevice)\(defaultDirectory)\(dst) as output\n"
        }
        _ = scriptStore.delete(name: srcNorm)
        return "%RENAME-I-RENAMED, \(defaultDevice)\(defaultDirectory)\(srcNorm);1 renamed to \(defaultDevice)\(defaultDirectory)\(dstNorm);1\n"
    }

    func appendCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%APPEND-F-NOFILES, two file parameters required\n"
        }
        let src = cmd.positional[0]
        let dst = cmd.positional[1]
        let srcNorm = scriptStore.normalize(src)
        let dstNorm = scriptStore.normalize(dst)
        guard let srcBody = scriptStore.read(name: srcNorm) else {
            return "%APPEND-E-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(src) as input\n-RMS-E-FNF, file not found\n"
        }
        guard let dstBody = scriptStore.read(name: dstNorm) else {
            return "%APPEND-E-OPENOUT, error opening \(defaultDevice)\(defaultDirectory)\(dst) as output\n-RMS-E-FNF, file not found\n"
        }
        var merged = dstBody
        if !merged.hasSuffix("\n") && !merged.isEmpty { merged += "\n" }
        merged += srcBody
        guard scriptStore.write(name: dstNorm, body: merged) else {
            return "%APPEND-E-OPENOUT, error writing \(defaultDevice)\(defaultDirectory)\(dst)\n"
        }
        return "%APPEND-S-APPENDED, \(defaultDevice)\(defaultDirectory)\(srcNorm);1 appended to \(defaultDevice)\(defaultDirectory)\(dstNorm);1\n"
    }

    // The scriptStore keeps a single ;1 version per file, so PURGE has
    // nothing to delete -- but it can honestly report that, instead of
    // pretending the file is missing.
    func purgeCmd(_ cmd: Parsed) -> String {
        if let target = cmd.positional.first {
            let normalized = scriptStore.normalize(target)
            guard scriptStore.read(name: normalized) != nil else {
                return "%PURGE-E-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(target) as input\n-RMS-E-FNF, file not found\n"
            }
            return "%PURGE-I-NOFILPURG, no files purged from \(defaultDevice)\(defaultDirectory)\(normalized) (single-version namespace)\n"
        }
        let count = scriptStore.list().count
        return "%PURGE-I-NOFILPURG, no files purged from \(defaultDevice)\(defaultDirectory) (\(count) file\(count == 1 ? "" : "s") inspected, all at ;1)\n"
    }

    // Simple line-by-line diff: read both files, group CollectionDifference
    // changes into two ordered run lists, and emit a VMS-flavoured section
    // header so the output is recognisable to anyone who has used real
    // DCL DIFFERENCES.
    func differencesCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%DIFFERENCES-F-NOFILES, two file parameters required\n"
        }
        let f1 = cmd.positional[0]
        let f2 = cmd.positional[1]
        let n1 = scriptStore.normalize(f1)
        let n2 = scriptStore.normalize(f2)
        guard let body1 = scriptStore.read(name: n1) else {
            return "%DIFFERENCES-E-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(f1) as input\n-RMS-E-FNF, file not found\n"
        }
        guard let body2 = scriptStore.read(name: n2) else {
            return "%DIFFERENCES-E-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(f2) as input\n-RMS-E-FNF, file not found\n"
        }
        let lines1 = body1.components(separatedBy: "\n")
        let lines2 = body2.components(separatedBy: "\n")
        let diff = lines2.difference(from: lines1)

        let path1 = "\(defaultDevice)\(defaultDirectory)\(n1);1"
        let path2 = "\(defaultDevice)\(defaultDirectory)\(n2);1"

        if diff.isEmpty {
            return "************\n\(path1)\n\(path2)\nNumber of difference sections found: 0\nNumber of difference records found: 0\n"
        }

        var removes: [(Int, String)] = []
        var inserts: [(Int, String)] = []
        for change in diff {
            switch change {
            case .remove(let off, let line, _): removes.append((off, line))
            case .insert(let off, let line, _): inserts.append((off, line))
            }
        }
        removes.sort { $0.0 < $1.0 }
        inserts.sort { $0.0 < $1.0 }

        var out = "************\n"
        out += "File \(path1)\n"
        if removes.isEmpty {
            out += "    (no lines unique to this file)\n"
        } else {
            for (off, line) in removes {
                out += String(format: "%6d   %@\n", off + 1, line)
            }
        }
        out += "******\n"
        out += "File \(path2)\n"
        if inserts.isEmpty {
            out += "    (no lines unique to this file)\n"
        } else {
            for (off, line) in inserts {
                out += String(format: "%6d   %@\n", off + 1, line)
            }
        }
        out += "************\n\n"
        out += "Number of difference sections found: 1\n"
        out += "Number of difference records found: \(removes.count + inserts.count)\n"
        return out
    }

    private func unquote(_ s: String) -> String {
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    func submitCmd(_ cmd: Parsed) async -> String {
        guard let file = cmd.positional.first else {
            return "%SUBMIT-F-NOPARM, missing parameter on SUBMIT\n"
        }
        let normalized = scriptStore.normalize(file)
        guard scriptStore.read(name: normalized) != nil else {
            return "%SUBMIT-E-OPENIN, error opening \(file) as input\n-RMS-E-FNF, file not found\n"
        }
        // Real VMS SUBMIT spools the procedure to SYS$BATCH, returns the
        // prompt immediately, runs the procedure detached (writing output
        // to a .LOG), and notifies the submitter through OPCOM + MAIL on
        // completion. The simulator follows the same flow: kick off a
        // MainActor task, capture the script's output into a MAIL message
        // (the in-shell stand-in for the .LOG), and drop an OPCOM line on
        // the terminal when the job finishes.
        let job = Int.random(in: 1000...9999)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let started = Date()
            let body = await self.execComFile(file)
            let finished = Date()
            let elapsed = self.uptimeString(from: started, to: finished)
            var log = "Job \(job) (\(normalized)) on queue SYS$BATCH\n"
            log += "Submitted \(self.stamp(started))   Completed \(self.stamp(finished))   Elapsed \(elapsed)\n"
            log += "\n"
            log += body.isEmpty ? "(no output)\n" : body
            self.mailbox.append(MailMessage(
                id: self.nextMailId,
                from: "BATCH",
                subject: "Job \(job) (\(normalized)) completed",
                body: log,
                received: finished,
                read: false))
            self.nextMailId += 1
            self.out("\r\n%OPCOM, \(self.stamp(finished)), batch job \(job) (\(normalized)) completed; see MAIL\n")
        }
        return "Job \(file) (queue SYS$BATCH, entry \(job)) pending\n"
    }

    /// CREATE -- in this shell, real .COM files get written to the disk
    /// store so EDIT / TYPE / @file can round-trip them. Everything else
    /// returns the standard OpenVMS \"created\" line for show.
    func createCmd(_ cmd: Parsed) -> String {
        guard let file = cmd.positional.first else {
            return "%CREATE-F-NOPARM, missing parameter on CREATE\n"
        }
        let normalized = scriptStore.normalize(file)
        if normalized.hasSuffix(".COM") {
            // Initialise an empty file if it doesn't already exist.
            if scriptStore.read(name: normalized) == nil {
                scriptStore.write(name: normalized, body: "")
            }
        }
        return "%CREATE-I-CREATED, \(defaultDevice)\(defaultDirectory)\(file);1 created (1 block allocated)\n"
    }

    /// DELETE -- removes a user-stored .COM file when one exists. All other
    /// targets still report RMS-E-FNF so the simulated namespace stays
    /// read-only for non-script content.
    func deleteCmd(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.first else {
            return "%DELETE-F-NOPARM, missing parameter on DELETE\n"
        }
        let normalized = scriptStore.normalize(target)
        if scriptStore.delete(name: normalized) {
            return "%DELETE-I-FILDEL, \(defaultDevice)\(defaultDirectory)\(target) deleted\n"
        }
        return rmsFNF("DELETE", cmd, op: "OPENIN")
    }
}
