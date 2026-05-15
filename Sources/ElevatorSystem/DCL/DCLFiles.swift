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

    func mailCmd() -> String {
        var s = "\n        \(osTitle) Personal Mail Utility\n"
        s += "        \(stamp(Date()))\n\n"
        s += "You have no new messages.\n"
        s += "MAIL>EXIT\n"
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

    func waitCmd(_ cmd: Parsed) -> String {
        // WAIT 00:00:nn -- no-op (we don't actually block)
        return ""
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

    func installCmd() -> String {
        var s = "\nDISK$ELEV_SYS:<SYS0.SYSCOMMON.SYSEXE>.EXE\n"
        s += "  CONTROL.EXE;42                   Open Hdr Shar Lnkbl\n"
        s += "  DOORS.EXE;19                     Open Hdr Shar Lnkbl\n"
        s += "  SCHED.EXE;7                      Open Hdr Shar Lnkbl\n"
        return s
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
        return "%SEARCH-I-NOMATCHES, no strings matched in \(defaultDevice)\(defaultDirectory)\(file)\n"
    }

    func printCmd(_ cmd: Parsed) -> String {
        guard let file = cmd.positional.first else {
            return "%PRINT-F-NOPARM, missing parameter on PRINT\n"
        }
        let job = Int.random(in: 1000...9999)
        return "Job \(file) (queue SYS$PRINT, entry \(job)) holding\n"
    }

    func submitCmd(_ cmd: Parsed) -> String {
        guard let file = cmd.positional.first else {
            return "%SUBMIT-F-NOPARM, missing parameter on SUBMIT\n"
        }
        let job = Int.random(in: 1000...9999)
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
