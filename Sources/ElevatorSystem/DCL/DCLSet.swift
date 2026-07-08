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
        case matches(what, "STANDARD", min: 3): return setStandard(cmd)
        default:
            return noPriv("SET \(what)")
        }
    }

    /// SET STANDARD ASME | EN81 | AUTO
    ///
    /// Chooses which lift-safety standard's terminology the UI presents.
    /// AUTO (the default) follows the UI language: French → EN 81, English
    /// → ASME A17.1. Affects SHOW MODBUS contact names, the safety-chain
    /// labels and the fire-recall status line.
    func setStandard(_ cmd: Parsed) -> String {
        guard let language else { return noPriv("SET STANDARD") }
        guard let arg = cmd.positional.dropFirst().first?.uppercased() else {
            return tr("dcl.set.standard.usage") + "\n"
        }
        switch arg {
        case "ASME", "A17", "A17.1":
            language.standardOverride = .asme
        case "EN81", "EN-81", "EN":
            language.standardOverride = .en81
        case "AUTO", "LANGUAGE", "DEFAULT":
            language.standardOverride = nil
        default:
            return String(format: tr("dcl.set.standard.bad"), arg) + "\n"
        }
        let modeKey = language.standardOverride == nil
            ? "dcl.set.standard.followlang" : "dcl.set.standard.override"
        return String(format: tr("dcl.set.standard.ok"),
                      language.standard.label, tr(modeKey)) + "\n"
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
        guard let world else { return tr("lpdcp.cmd.noworld") }
        if cmd.hasQualifier("NORMAL", min: 3) {
            world.buildingMode = .normal
            world.epoCabId = nil
            return tr("lpdcp.bldg.modenormal")
        }
        if let disp = cmd.qualifierValue("DISPATCH", min: 4) {
            let mode: DispatchMode
            switch disp.uppercased() {
            case "DESTINATION", "DEST":
                mode = .destination
            case "COLLECTIVE", "COLL":
                mode = .collective
            default:
                return tr("lpdcp.bldg.dispkeyw")
            }
            world.dispatchMode = mode
            return mode == .destination
                ? tr("lpdcp.bldg.dispdest")
                : tr("lpdcp.bldg.dispcoll")
        }
        if let fire = cmd.qualifierValue("FIRE_RECALL", min: 4)
                        ?? cmd.qualifierValue("FIRE", min: 4) {
            if let floorStr = cmd.qualifierValue("FLOOR", min: 3),
               let floor = Int(floorStr) {
                world.recallFloor = max(Sim.firstFloor, min(Sim.lastFloor, floor))
            }
            if fire.uppercased() == "ON" {
                world.buildingMode = .fireRecall
                return String(format: tr("lpdcp.bldg.fireon"), world.recallFloor)
            } else {
                world.buildingMode = .normal
                world.epoCabId = nil
                return tr("lpdcp.bldg.fireoff")
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
                let survLabel = surv.map { world.displayLabel(for: $0) } ?? tr("lpdcp.bldg.none")
                return String(format: tr("lpdcp.bldg.epoon"), survLabel)
            } else {
                world.buildingMode = .normal
                world.epoCabId = nil
                return tr("lpdcp.bldg.epoff")
            }
        }
        return tr("lpdcp.bldg.missqual")
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
            return tr("lpdcp.cab.misscab")
        }
        guard let world else {
            return tr("lpdcp.cmd.sysnoworld")
        }
        guard let cab = findCab(label: label, in: world) else {
            fail("SET-W-NOSUCHCAB", "%X000080A4")
            return String(format: tr("lpdcp.cab.nosuch"), label)
        }
        let dLabel = world.displayLabel(for: cab)
        guard world.canControl(cab) else {
            return String(format: tr("lpdcp.cab.remote"), dLabel)
        }
        guard let auto = automation else {
            return tr("lpdcp.cab.noauto")
        }
        if cmd.hasQualifier("MANUAL", min: 3) {
            let was = auto.isAutomatic(cabId: cab.id)
            auto.takeManualControl(cabId: cab.id)
            return was
                ? String(format: tr("lpdcp.cab.man.set"), dLabel)
                : String(format: tr("lpdcp.cab.man.nochg"), dLabel)
        }
        if cmd.hasQualifier("AUTOMATIC", min: 4) || cmd.hasQualifier("AUTO", min: 4) {
            let was = auto.isAutomatic(cabId: cab.id)
            auto.returnToAutomatic(cabId: cab.id)
            return !was
                ? String(format: tr("lpdcp.cab.auto.set"), dLabel)
                : String(format: tr("lpdcp.cab.auto.nochg"), dLabel)
        }
        if cmd.hasQualifier("PAX", min: 3) {
            let was = cab.profile
            _ = world.mutateLocal(cab.id) { $0.profile = .pax }
            return was == .pax
                ? String(format: tr("lpdcp.cab.pax.nochg"), dLabel)
                : String(format: tr("lpdcp.cab.pax.set"), dLabel)
        }
        if cmd.hasQualifier("FREIGHT", min: 3) || cmd.hasQualifier("FRT", min: 3) {
            let was = cab.profile
            _ = world.mutateLocal(cab.id) { $0.profile = .freight }
            return was == .freight
                ? String(format: tr("lpdcp.cab.frt.nochg"), dLabel)
                : String(format: tr("lpdcp.cab.frt.set"), dLabel)
        }
        if let phase = cmd.qualifierValue("PHASE2", min: 5)
                        ?? cmd.qualifierValue("PHASE_TWO", min: 5) {
            let on = phase.uppercased() == "ON"
            _ = world.mutateLocal(cab.id) { $0.phaseTwoActive = on }
            return on
                ? String(format: tr("lpdcp.cab.phase2.on"), dLabel)
                : String(format: tr("lpdcp.cab.phase2.off"), dLabel)
        }
        if let ind = cmd.qualifierValue("INDEPENDENT", min: 3)
                        ?? cmd.qualifierValue("IND", min: 3) {
            let on = ind.uppercased() == "ON"
            _ = world.mutateLocal(cab.id) { $0.independentActive = on }
            return on
                ? String(format: tr("lpdcp.cab.indep.on"), dLabel)
                : String(format: tr("lpdcp.cab.indep.off"), dLabel)
        }
        if let loadStr = cmd.qualifierValue("LOAD", min: 3),
           let kg = Double(loadStr) {
            let clamped = max(0, min(9999, kg))
            _ = world.mutateLocal(cab.id) { $0.loadKg = clamped }
            return String(format: tr("lpdcp.cab.load.set"),
                          dLabel, clamped,
                          clamped / cab.profile.ratedLoadKg * 100.0)
        }
        return tr("lpdcp.cab.missqual")
    }
}
