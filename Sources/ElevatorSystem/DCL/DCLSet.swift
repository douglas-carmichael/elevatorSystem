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
        case matches(what, "BUILDING", min: 4): return setBuilding(cmd)
        default:
            return noPriv("SET \(what)")
        }
    }

    /// SET BUILDING /FIRE_RECALL=ON|OFF [/FLOOR=n]
    /// SET BUILDING /EPO=ON|OFF [/CAB=Lxx]
    /// SET BUILDING /NORMAL
    ///
    /// Toggles building-wide safety modes (Phase I Fire Service Recall
    /// and Emergency Power Operation). Phase I cancels every cab's
    /// queue, sends each cab to the recall floor, and holds doors
    /// open. EPO does the same for every cab EXCEPT the designated
    /// survivor, which keeps running on backup power.
    func setBuilding(_ cmd: Parsed) -> String {
        guard let world else { return "%CTRL-E-NOWORLD, no world\n" }
        if cmd.hasQualifier("NORMAL", min: 3) {
            world.buildingMode = .normal
            world.epoCabId = nil
            return "%CTRL-S-MODE, building returned to normal operation\n"
        }
        if let disp = cmd.qualifierValue("DISPATCH", min: 4) {
            let mode: DispatchMode
            switch disp.uppercased() {
            case "DESTINATION", "DEST":
                mode = .destination
            case "COLLECTIVE", "COLL":
                mode = .collective
            default:
                return "%DCL-W-IVKEYW, /DISPATCH expects COLLECTIVE or DESTINATION\n"
            }
            world.dispatchMode = mode
            return mode == .destination
                ? "%CTRL-S-DISPATCH, destination dispatch enabled -- CALL DESTINATION /FROM=<n> /TO=<m>\n"
                : "%CTRL-S-DISPATCH, collective control restored\n"
        }
        if let fire = cmd.qualifierValue("FIRE_RECALL", min: 4)
                        ?? cmd.qualifierValue("FIRE", min: 4) {
            if let floorStr = cmd.qualifierValue("FLOOR", min: 3),
               let floor = Int(floorStr) {
                world.recallFloor = max(Sim.firstFloor, min(Sim.lastFloor, floor))
            }
            if fire.uppercased() == "ON" {
                world.buildingMode = .fireRecall
                return "%CTRL-W-FIRERECALL, Phase I Fire Service active -- all cabs recall to floor \(world.recallFloor)\n"
            } else {
                world.buildingMode = .normal
                world.epoCabId = nil
                return "%CTRL-S-FIRERESET, Phase I Fire Service released\n"
            }
        }
        if let epo = cmd.qualifierValue("EPO", min: 3) {
            if epo.uppercased() == "ON" {
                if let cabLabel = cmd.qualifierValue("CAB", min: 3) {
                    let cabs = world.elevators
                    if let cab = cabs.first(where: { world.displayLabel(for: $0).uppercased() == cabLabel.uppercased() || $0.label.uppercased() == cabLabel.uppercased() }) {
                        world.epoCabId = cab.id
                    }
                }
                world.buildingMode = .emergencyPower
                let surv = world.epoCabId.flatMap { id in world.elevators.first(where: { $0.id == id }) }
                let survLabel = surv.map { world.displayLabel(for: $0) } ?? "(none)"
                return "%CTRL-W-EPO, Emergency Power Operation -- only cab \(survLabel) remains on backup\n"
            } else {
                world.buildingMode = .normal
                world.epoCabId = nil
                return "%CTRL-S-EPORESET, Emergency Power Operation released\n"
            }
        }
        return "%DCL-W-MISSQUAL, SET BUILDING needs /FIRE_RECALL, /EPO, or /NORMAL\n"
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
        if let phase = cmd.qualifierValue("PHASE2", min: 5)
                        ?? cmd.qualifierValue("PHASE_TWO", min: 5) {
            let on = phase.uppercased() == "ON"
            _ = world.mutateLocal(cab.id) { $0.phaseTwoActive = on }
            return on
                ? "%SET-W-PHASE2, cab \(dLabel) in Phase II Fire Service -- fireman's operation\n"
                : "%SET-I-PHASE2OFF, cab \(dLabel) Phase II Fire Service released\n"
        }
        if let ind = cmd.qualifierValue("INDEPENDENT", min: 3)
                        ?? cmd.qualifierValue("IND", min: 3) {
            let on = ind.uppercased() == "ON"
            _ = world.mutateLocal(cab.id) { $0.independentActive = on }
            return on
                ? "%SET-I-INDEP, cab \(dLabel) in Independent Service -- doors held open, no group dispatch\n"
                : "%SET-I-INDEPOFF, cab \(dLabel) returned to normal group dispatch\n"
        }
        if let loadStr = cmd.qualifierValue("LOAD", min: 3),
           let kg = Double(loadStr) {
            let clamped = max(0, min(9999, kg))
            _ = world.mutateLocal(cab.id) { $0.loadKg = clamped }
            return String(format: "%%SET-I-LOAD, cab %@ platform load now %.0f kg (%.0f%% of rated)\n",
                          dLabel, clamped,
                          clamped / cab.profile.ratedLoadKg * 100.0)
        }
        return "%SET-W-MISSQUAL, SET CAB needs /MANUAL, /AUTOMATIC, /PAX, /FREIGHT, /PHASE2, /INDEPENDENT or /LOAD\n"
    }
}
