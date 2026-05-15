import Foundation

// Operator-level verbs: ALLOCATE / DEALLOCATE / MOUNT / DISMOUNT /
// BACKUP / ANALYZE / EXAMINE / REPLY / REQUEST / RUN.
extension DCLEngine {
    /// ALLOCATE -- claim a device for the current process.
    func allocateCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%ALLOC-F-NODEV, no device specified\n"
        }
        let dev = normalizeDevice(raw)
        if isSystemDevice(dev) {
            return noPriv("ALLOCATE \(dev)")
        }
        if allocatedDevices.contains(dev) {
            return "%ALLOC-W-ALLOCATED, _\(nodeName)$\(dev) already allocated\n"
        }
        allocatedDevices.insert(dev)
        return "%ALLOC-S-ALLOC, _\(nodeName)$\(dev) allocated\n"
    }

    func deallocateCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            if cmd.hasQualifier("ALL", min: 1) {
                let n = allocatedDevices.count
                allocatedDevices.removeAll()
                return "%DEALLOC-S-DEALLOC, \(n) device\(n == 1 ? "" : "s") deallocated\n"
            }
            return "%DEALLOC-F-NODEV, no device specified\n"
        }
        let dev = normalizeDevice(raw)
        if allocatedDevices.remove(dev) != nil {
            return "%DEALLOC-S-DEALLOC, _\(nodeName)$\(dev) deallocated\n"
        }
        return "%DEALLOC-W-NOTALLOC, _\(nodeName)$\(dev) was not allocated to this process\n"
    }

    func mountCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%MOUNT-F-NODEV, no device specified\n"
        }
        let dev = normalizeDevice(raw)
        if isSystemDevice(dev) {
            return noPriv("MOUNT \(dev)")
        }
        let label = cmd.positional.count > 1 ? cmd.positional[1].uppercased()
                                              : (cmd.qualifierValue("VOLUME") ?? "SCRATCH")
        if mountedVolumes[dev] != nil {
            return "%MOUNT-W-MOUNTED, _\(nodeName)$\(dev) is already mounted\n"
        }
        mountedVolumes[dev] = label
        return "%MOUNT-I-MOUNTED, \(label) mounted on _\(nodeName)$\(dev)\n"
    }

    func dismountCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%DISMNT-F-NODEV, no device specified\n"
        }
        let dev = normalizeDevice(raw)
        if mountedVolumes.removeValue(forKey: dev) != nil {
            return "%DISMNT-I-DISMOUNT, _\(nodeName)$\(dev) dismounted\n"
        }
        return "%DISMNT-W-NOTMNT, _\(nodeName)$\(dev) was not mounted\n"
    }

    func backupCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%BACKUP-F-NOSPEC, missing input or output specification\n"
        }
        let src = cmd.positional[0]
        let dst = cmd.positional[1]
        let now = Date()
        var s = "%BACKUP-I-IDENT, OpenVMS BACKUP V9.2-3 \(stamp(now))\n"
        s += "%BACKUP-I-STARTVERIFY, starting verification pass\n"
        s += "%BACKUP-S-CREATED, save set \(dst) created\n"
        s += "%BACKUP-S-COPIED, copied \(Int.random(in: 6...14)) files in \(Int.random(in: 800...2400)) blocks from \(src)\n"
        s += "%BACKUP-I-PROCDONE, operation completed\n"
        return s
    }

    func analyzeCmd(_ cmd: Parsed) -> String {
        if cmd.hasQualifier("ERROR_LOG", min: 4) || cmd.hasQualifier("ERROR", min: 4) {
            return showError()
        }
        if cmd.hasQualifier("AUDIT", min: 3) {
            return showAudit()
        }
        if cmd.hasQualifier("IMAGE", min: 3) || cmd.hasQualifier("CRASH_DUMP", min: 5) {
            return noPriv("ANALYZE\(cmd.hasQualifier("IMAGE", min: 3) ? "/IMAGE" : "/CRASH_DUMP")")
        }
        return "%ANALYZE-W-NOQUAL, ANALYZE requires /ERROR_LOG, /AUDIT, /IMAGE, or /CRASH_DUMP\n"
    }

    func runCmd(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.first?.uppercased() else {
            return "%RUN-F-NOIMG, no image specified\n"
        }
        let stripped = target.hasSuffix(".EXE") ? String(target.dropLast(4)) : target
        let knownDiagnostic: Bool
        switch stripped {
        case "BRAKE_TEST", "DOOR_TEST", "WEIGHT_CAL", "HALL_LAMP_TEST":
            knownDiagnostic = true
        default:
            knownDiagnostic = false
        }
        if !knownDiagnostic { return noPriv("RUN \(target)") }
        if dryRun {
            return "%RUN-S-PROC_ID, would launch \(stripped) test utility (dry-run)\n"
        }
        switch stripped {
        case "BRAKE_TEST":      startBrakeTest()
        case "DOOR_TEST":       startDoorTest()
        case "WEIGHT_CAL":      startWeightCal()
        case "HALL_LAMP_TEST":  startHallLampTest()
        default: break
        }
        return ""
    }

    func examineCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%EXAMINE-F-NOLOC, no address specified\n"
        }
        let addr: UInt64
        let trimmed = raw.uppercased().replacingOccurrences(of: "^X", with: "")
        if let v = UInt64(trimmed, radix: 16) {
            addr = v
        } else if let v = UInt64(trimmed) {
            addr = v
        } else {
            return "%EXAMINE-W-IVADDR, invalid address \\\(raw)\\\n"
        }
        let v = (addr &* 0x9E3779B1) ^ 0xDEADBEEF
        return String(format: "  %08llX:  %08llX\n", addr, v & 0xFFFFFFFF)
    }

    func replyCmd(_ cmd: Parsed) -> String {
        let msg = cmd.positional.joined(separator: " ").replacingOccurrences(of: "\"", with: "")
        if msg.isEmpty {
            return "%REPLY-F-NOMSG, no message text specified\n"
        }
        return "%REPLY-S-REPLIED, reply queued to OPER0:  \"\(msg)\"\n"
    }

    func requestCmd(_ cmd: Parsed) -> String {
        let msg = cmd.positional.joined(separator: " ").replacingOccurrences(of: "\"", with: "")
        if msg.isEmpty {
            return "%REQUEST-F-NOMSG, no message text specified\n"
        }
        return "%OPCOM-I-LOGGED, request from \(username) at \(stamp(Date())) -- \"\(msg)\"\n"
    }

    // MARK: -- helpers

    /// Strips a leading "_NODE$" prefix and adds a trailing colon so user
    /// input like "MUA0", "MUA0:", "_ASCEN1$MUA0:" maps to the same key.
    func normalizeDevice(_ raw: String) -> String {
        var s = raw.uppercased()
        if let dollar = s.firstIndex(of: "$") {
            s = String(s[s.index(after: dollar)...])
        }
        if !s.hasSuffix(":") { s += ":" }
        return s
    }

    /// System / production volumes the operator account cannot allocate.
    func isSystemDevice(_ dev: String) -> Bool {
        return dev.hasPrefix("DK") || dev.hasPrefix("CAB$DK") || dev.hasPrefix("EVENTLOG$") ||
               dev.contains("SYS")
    }
}
