import Foundation

// SET family -- per-keyword subcommands.
extension DCLEngine {
    func setCmd(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else { return missQual("SET") }
        switch true {
        case matches(what, "DEFAULT", min: 3):  return setDefault(cmd)
        case matches(what, "TERMINAL", min: 4): return setTerminal(cmd)
        case matches(what, "PROMPT", min: 3):   return setPrompt(cmd)
        case matches(what, "ON"):               return ""
        case matches(what, "NOON", min: 3):     return ""
        case matches(what, "VERIFY", min: 3):   return ""
        case matches(what, "NOVERIFY", min: 3): return ""
        case matches(what, "PASSWORD", min: 4): return setPassword()
        case matches(what, "PROCESS", min: 4):  return setProcess(cmd)
        case matches(what, "CAB"):              return setCab(cmd)
        default:
            return noPriv("SET \(what)")
        }
    }

    func setDefault(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.dropFirst().first else { return missQual("SET DEFAULT") }
        var dev = defaultDevice
        var dir = defaultDirectory

        var spec = target
        if let colon = spec.firstIndex(of: ":") {
            dev = String(spec[...colon]).uppercased()
            spec = String(spec[spec.index(after: colon)...])
        }
        if !spec.isEmpty {
            if spec == "[-]" {
                if dir.hasPrefix("[") && dir.hasSuffix("]") {
                    var inner = String(dir.dropFirst().dropLast())
                    if let dot = inner.lastIndex(of: ".") {
                        inner = String(inner[..<dot])
                        dir = "[\(inner)]"
                    } else {
                        dir = "[000000]"
                    }
                }
            } else if spec.hasPrefix("[.") {
                let extra = String(spec.dropFirst(2).dropLast())
                let inner = dir.dropFirst().dropLast()
                dir = "[\(inner).\(extra)]"
            } else if spec.hasPrefix("[") {
                dir = spec.uppercased()
            } else {
                fail("DCL-W-IVKEYW", "%X00038088")
                return "%DCL-W-IVKEYW, unrecognized keyword - check validity and spelling\n"
            }
        }
        defaultDevice = dev
        defaultDirectory = dir
        return ""
    }

    func setTerminal(_ cmd: Parsed) -> String {
        if let w = cmd.qualifierValue("WIDTH"), let n = Int(w) { terminalWidth = n }
        if let p = cmd.qualifierValue("PAGE"),  let n = Int(p) { terminalPage = n }
        return ""
    }

    func setPrompt(_ cmd: Parsed) -> String {
        if let v = cmd.qualifiers.first(where: { $0.value != nil })?.value {
            prompt = v.replacingOccurrences(of: "\"", with: "") + " "
            return ""
        }
        if let v = cmd.positional.dropFirst().first {
            prompt = v.replacingOccurrences(of: "\"", with: "") + " "
            return ""
        }
        prompt = "$ "
        return ""
    }

    func setPassword() -> String {
        return "%SET-W-NOTSET, error modifying \(username)\n-SYSTEM-F-NOPRIV, insufficient privilege\n"
    }

    func setProcess(_ cmd: Parsed) -> String {
        if cmd.hasQualifier("PRIORITY", min: 3) || cmd.hasQualifier("NAME", min: 3) {
            return noPriv("SET PROCESS")
        }
        return ""
    }

    func setCab(_ cmd: Parsed) -> String {
        guard let label = cmd.positional.dropFirst().first else {
            return "%SET-W-MISSCAB, missing cab identifier\n"
        }
        guard let world else {
            return "%SYSTEM-F-NOWORLD, elevator world not attached\n"
        }
        guard let cab = findCab(label: label, in: world) else {
            fail("SET-W-NOSUCHCAB", "%X000080A4")
            return "%SET-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        let dLabel = world.displayLabel(for: cab)
        guard world.canControl(cab) else {
            return "%SET-W-REMOTE, cab \(dLabel) is owned by a remote node\n"
        }
        guard let auto = automation else {
            return "%SET-F-NOAUTO, automation subsystem not running\n"
        }
        if cmd.hasQualifier("MANUAL", min: 3) {
            let was = auto.isAutomatic(cabId: cab.id)
            auto.takeManualControl(cabId: cab.id)
            if was {
                return "%SET-I-CABMAN, cab \(dLabel) released from auto-dispatch -- MANUAL CONTROL\n"
            } else {
                return "%SET-I-NOCHG, cab \(dLabel) was already under manual control\n"
            }
        }
        if cmd.hasQualifier("AUTOMATIC", min: 4) || cmd.hasQualifier("AUTO", min: 4) {
            let was = auto.isAutomatic(cabId: cab.id)
            auto.returnToAutomatic(cabId: cab.id)
            if !was {
                return "%SET-I-CABAUTO, cab \(dLabel) returned to auto-dispatch\n"
            } else {
                return "%SET-I-NOCHG, cab \(dLabel) was already under auto-dispatch\n"
            }
        }
        if cmd.hasQualifier("PAX", min: 3) {
            let was = cab.profile
            _ = world.mutateLocal(cab.id) { $0.profile = .pax }
            return was == .pax
                ? "%SET-I-NOCHG, cab \(dLabel) was already PAX\n"
                : "%SET-I-CABPAX, cab \(dLabel) profile set to PASSENGER\n"
        }
        if cmd.hasQualifier("FREIGHT", min: 3) || cmd.hasQualifier("FRT", min: 3) {
            let was = cab.profile
            _ = world.mutateLocal(cab.id) { $0.profile = .freight }
            return was == .freight
                ? "%SET-I-NOCHG, cab \(dLabel) was already FREIGHT\n"
                : "%SET-I-CABFRT, cab \(dLabel) profile set to FREIGHT\n"
        }
        return "%SET-W-MISSQUAL, /MANUAL, /AUTOMATIC, /PAX, or /FREIGHT required for SET CAB\n"
    }
}
