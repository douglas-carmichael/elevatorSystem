import Foundation

// LPD-CP -- LPD Elevator Control Program.
//
// Top-level entry for the elevator-control layered product, modelled on
// the real VMS layered-tool pattern (NCP for DECnet, LATCP for LAT, ...).
// A site engineer types the program name first, then a subverb, then the
// noun keyword:
//
//      $ LPDCP SHOW CAB L01
//      $ LPDCP SHOW DISPATCH
//      $ LPDCP SET CAB L01 /MANUAL
//      $ LPDCP SET BUILDING /FIRE_RECALL=ON
//
// On a real OpenVMS host this would be a separately-linked image
// installed via SET COMMAND on a .CLD definition. Here it just shares
// the DCLEngine extension surface with every other verb.
//
// Convenience aliases (CAB, BLDG, CALLS, ...) are defined as foreign-
// command symbols in the seeded LOGIN.COM so a returning operator can
// type the short form. Symbol substitution in DCLEngine.execute()
// expands those aliases to LPDCP ... before parsing.
//
// LPDCP output is localised (EN / FR) because the vendor is French --
// same rationale as LPD-DIAG. The underlying VMS error facility names
// (LPDCP-W-IVVERB, LPDCP-W-MISSQUAL) stay English to look like a real
// VMS error code; the human-readable tail of each message localises.
extension DCLEngine {

    func lpdcpCmd(_ cmd: Parsed) -> String {
        guard let subverb = cmd.positional.first else {
            return lpdcpSynopsis()
        }
        // Strip the subverb so the downstream handler sees positional
        // = [<subject>, <args>...]. The existing setCab / showDispatch
        // implementations were written for that shape.
        let inner = Parsed(verb: subverb.uppercased(),
                           positional: Array(cmd.positional.dropFirst()),
                           qualifiers: cmd.qualifiers)
        switch true {
        case matches(subverb, "SHOW"):           return lpdcpShow(inner)
        case matches(subverb, "SET"):            return lpdcpSet(inner)
        case matches(subverb, "HELP"):           return lpdcpHelp()
        default:
            fail("DCL-W-IVKEYW", "%X00038088")
            return String(format: tr("lpdcp.err.ivverb"), subverb)
        }
    }

    private func lpdcpShow(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else {
            return tr("lpdcp.err.show.missqual")
        }
        switch true {
        case matches(what, "CAB"):              return showCabLPDCP(cmd)
        case matches(what, "BUILDING", min: 4): return showBuildingLPDCP()
        case matches(what, "DISPATCH", min: 4): return showDispatch()
        case matches(what, "CALLS",    min: 4): return showCalls()
        case matches(what, "LOAD"):             return showLoad()
        default:
            fail("DCL-W-IVKEYW", "%X00038088")
            return String(format: tr("lpdcp.err.show.ivkeyw"), what)
        }
    }

    private func lpdcpSet(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else {
            return tr("lpdcp.err.set.missqual")
        }
        switch true {
        case matches(what, "CAB"):              return setCab(cmd)
        case matches(what, "BUILDING", min: 4): return setBuilding(cmd)
        default:
            fail("DCL-W-IVKEYW", "%X00038088")
            return String(format: tr("lpdcp.err.set.ivkeyw"), what)
        }
    }

    /// LPDCP SHOW CAB [label] -- per-cab status sheet, or list-all when
    /// no label is supplied. The list-all form just trampolines to the
    /// existing SHOW DISPATCH output so we don't duplicate the table.
    func showCabLPDCP(_ cmd: Parsed) -> String {
        guard let label = cmd.positional.dropFirst().first else {
            return showDispatch()
        }
        guard let world else { return "%SHOW-W-NOWORLD, elevator world not attached\n" }
        guard let cab = findCab(label: label, in: world) else {
            fail("SHOW-W-NOSUCHCAB", "%X000080A4")
            return "%SHOW-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        let dLabel = world.displayLabel(for: cab)
        let doorKey: String
        switch cab.doors {
        case .open:    doorKey = "lpdcp.door.open"
        case .closed:  doorKey = "lpdcp.door.closed"
        case .opening: doorKey = "lpdcp.door.opening"
        case .closing: doorKey = "lpdcp.door.closing"
        }
        let modeKey: String
        if cab.phaseTwoActive {
            modeKey = "lpdcp.mode.phase2"
        } else if cab.independentActive {
            modeKey = "lpdcp.mode.indep"
        } else if let auto = automation, auto.isAutomatic(cabId: cab.id) {
            modeKey = "lpdcp.mode.auto"
        } else {
            modeKey = "lpdcp.mode.manual"
        }
        let profileKey = cab.profile == .freight ? "lpdcp.profile.freight"
                                                 : "lpdcp.profile.pax"
        let queueStr = cab.queue.isEmpty
            ? tr("lpdcp.cab.empty")
            : cab.queue.map(String.init).joined(separator: " -> ")
        let ownerKey = world.canControl(cab) ? "lpdcp.owner.local"
                                             : "lpdcp.owner.remote"
        var s = String(format: tr("lpdcp.cab.title"), dLabel, stamp(Date()))
        s += String(format: "%@%6.2f fl\n",   tr("lpdcp.cab.position"), cab.position)
        s += String(format: "%@%+6.3f fl/s\n", tr("lpdcp.cab.velocity"), cab.velocity)
        s += tr("lpdcp.cab.profile")  + tr(profileKey) + "\n"
        s += tr("lpdcp.cab.doors")    + tr(doorKey)    + "\n"
        s += tr("lpdcp.cab.load")
        s += String(format: tr("lpdcp.cab.rated") + "\n",
                    cab.loadKg, cab.profile.ratedLoadKg)
        s += tr("lpdcp.cab.mode")     + tr(modeKey)    + "\n"
        s += tr("lpdcp.cab.queue")    + queueStr       + "\n"
        s += tr("lpdcp.cab.owner")    + tr(ownerKey)   + "\n"
        return s
    }

    /// LPDCP SHOW BUILDING -- one-screen summary of building-wide state
    /// (safety mode + dispatch + cab census).
    func showBuildingLPDCP() -> String {
        guard let world else { return "%SHOW-W-NOWORLD, elevator world not attached\n" }
        let mode: String
        switch world.buildingMode {
        case .normal:
            mode = tr("lpdcp.bldg.mode.normal")
        case .fireRecall:
            mode = String(format: tr("lpdcp.bldg.mode.fire"), world.recallFloor)
        case .emergencyPower:
            mode = tr("lpdcp.bldg.mode.epo")
        }
        let dispatch = world.dispatchMode == .destination
            ? tr("lpdcp.bldg.disp.dest")
            : tr("lpdcp.bldg.disp.coll")
        var s = String(format: tr("lpdcp.bldg.title"), stamp(Date()))
        s += tr("lpdcp.bldg.safety")   + mode + "\n"
        s += tr("lpdcp.bldg.dispatch") + dispatch + "\n"
        s += tr("lpdcp.bldg.recall")   + "\(world.recallFloor)\n"
        s += String(format: tr("lpdcp.bldg.cabs"), world.elevators.count)
        return s
    }

    private func lpdcpSynopsis() -> String {
        return tr("lpdcp.synopsis") + "\n"
    }

    private func lpdcpHelp() -> String {
        return lpdcpSynopsis() + tr("lpdcp.help.body") + "\n"
    }
}
