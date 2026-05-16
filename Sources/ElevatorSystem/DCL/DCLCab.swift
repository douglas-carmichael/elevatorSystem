import Foundation

// Cab-control verbs: CALL / OPEN / CLOSE / STOP.
extension DCLEngine {
    func callCmd(_ cmd: Parsed) -> String {
        // CALL DESTINATION /FROM=<n> /TO=<m>     (destination-dispatch)
        // CALL HALL /FLOOR=<n> /UP|/DOWN         (landing-fixture call)
        // CALL CAB <label> FLOOR <n>             (in-cab "car call")
        // CALL <label> <n>                       (short, defaults to car call)
        var args = cmd.positional
        if args.first?.uppercased() == "DESTINATION" {
            return callDestinationCmd(cmd)
        }
        if args.first?.uppercased() == "HALL" {
            return callHallCmd(cmd)
        }
        if args.first?.uppercased() == "CAB" { args.removeFirst() }
        guard args.count >= 2 else {
            return "%CALL-W-MISSPARM, usage: CALL CAB <label> FLOOR <n>  or  CALL DESTINATION /FROM=<n> /TO=<m>\n"
        }
        let label = args[0]
        var floorTok = args[1]
        if args.count >= 3 && args[1].uppercased().hasPrefix("FLOOR") { floorTok = args[2] }
        guard let floor = Int(floorTok) else {
            return "%CALL-W-IVFLOOR, invalid floor \\\(floorTok)\\\n"
        }
        guard floor >= Sim.firstFloor && floor <= Sim.lastFloor else {
            return "%CALL-W-FLOORRNG, floor must be \(Sim.firstFloor)..\(Sim.lastFloor)\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, elevator world not attached\n" }
        guard let cab = findCab(label: label, in: world) else {
            return "%CALL-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        let dLabel = world.displayLabel(for: cab)
        guard world.canControl(cab) else {
            return "%CALL-W-REMOTE, cab \(dLabel) is owned by a remote node\n"
        }
        _ = world.mutateLocal(cab.id) { e in e.enqueue(floor: floor) }
        return "%CALL-S-QUEUED, cab \(dLabel) queued for floor \(floor)\n"
    }

    /// CALL DESTINATION /FROM=<n> /TO=<m>
    /// Destination-dispatch entry point: hands the call to
    /// `world.allocateDestination`, which picks the best cab by ETA
    /// plus same-direction bias and pre-loads its queue with origin
    /// then destination.
    func callDestinationCmd(_ cmd: Parsed) -> String {
        guard let world else {
            return "%SYSTEM-F-NOWORLD, elevator world not attached\n"
        }
        guard let fromStr = cmd.qualifierValue("FROM", min: 3),
              let from = Int(fromStr) else {
            return "%CALL-W-MISSFROM, usage: CALL DESTINATION /FROM=<n> /TO=<m>\n"
        }
        guard let toStr = cmd.qualifierValue("TO", min: 2),
              let to = Int(toStr) else {
            return "%CALL-W-MISSTO, usage: CALL DESTINATION /FROM=<n> /TO=<m>\n"
        }
        guard from >= Sim.firstFloor && from <= Sim.lastFloor,
              to >= Sim.firstFloor && to <= Sim.lastFloor else {
            return "%CALL-W-FLOORRNG, floor must be \(Sim.firstFloor)..\(Sim.lastFloor)\n"
        }
        guard from != to else {
            return "%CALL-W-SAMEFLOOR, /FROM and /TO must differ\n"
        }
        guard let call = world.allocateDestination(from: from, to: to) else {
            return "%CALL-W-NOAVAIL, no eligible cab to take that call\n"
        }
        return String(format: "%%CALL-S-ALLOC, dispatch #%04d  cab %@  FROM %d -> TO %d  ETA ~%.1fs\n",
                      call.sequence, call.cabLabel, call.from, call.to, call.etaSeconds)
    }

    /// CALL HALL /FLOOR=<n> /UP    (or /DOWN)
    /// Models a rider pressing the up / down button at a landing
    /// fixture. The world allocates it to the best cab; the lantern
    /// extinguishes when a cab arrives at that floor.
    func callHallCmd(_ cmd: Parsed) -> String {
        guard let world else {
            return "%SYSTEM-F-NOWORLD, elevator world not attached\n"
        }
        guard let floorStr = cmd.qualifierValue("FLOOR", min: 3),
              let floor = Int(floorStr) else {
            return "%CALL-W-MISSFLOOR, usage: CALL HALL /FLOOR=<n> /UP|/DOWN\n"
        }
        guard floor >= Sim.firstFloor && floor <= Sim.lastFloor else {
            return "%CALL-W-FLOORRNG, floor must be \(Sim.firstFloor)..\(Sim.lastFloor)\n"
        }
        let direction: Direction
        if cmd.hasQualifier("UP", min: 2) {
            direction = .up
        } else if cmd.hasQualifier("DOWN", min: 2) {
            direction = .down
        } else {
            return "%CALL-W-MISSDIR, must specify /UP or /DOWN\n"
        }
        guard let call = world.registerHallCall(floor: floor, direction: direction) else {
            return "%CALL-W-REJECT, hall call rejected (invalid direction)\n"
        }
        let dirLabel = direction == .up ? "UP" : "DN"
        if let cabId = call.assignedCabId,
           let cab = world.elevators.first(where: { $0.id == cabId }) {
            return String(format: "%%CALL-S-HALL, hall #%04d floor %d %@ -> cab %@\n",
                          call.sequence, floor, dirLabel,
                          world.displayLabel(for: cab))
        }
        return String(format: "%%CALL-S-HALL, hall #%04d floor %d %@ registered (no cab available)\n",
                      call.sequence, floor, dirLabel)
    }

    func openCmd(_ cmd: Parsed) -> String {
        var args = cmd.positional
        if args.first?.uppercased() == "CAB" { args.removeFirst() }
        guard let label = args.first else {
            return "%OPEN-W-MISSPARM, usage: OPEN CAB <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, elevator world not attached\n" }
        guard let cab = findCab(label: label, in: world) else {
            return "%OPEN-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        let dLabel = world.displayLabel(for: cab)
        guard world.canControl(cab) else { return "%OPEN-W-REMOTE, cab \(dLabel) is remote\n" }
        _ = world.mutateLocal(cab.id) { e in e.requestDoorsOpen() }
        return "%OPEN-S-DOOR, cab \(dLabel) doors opening\n"
    }

    func closeCmd(_ cmd: Parsed) -> String {
        var args = cmd.positional
        if args.first?.uppercased() == "CAB" { args.removeFirst() }
        guard let label = args.first else {
            return "%CLOSE-W-MISSPARM, usage: CLOSE CAB <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, elevator world not attached\n" }
        guard let cab = findCab(label: label, in: world) else {
            return "%CLOSE-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        let dLabel = world.displayLabel(for: cab)
        guard world.canControl(cab) else { return "%CLOSE-W-REMOTE, cab \(dLabel) is remote\n" }
        _ = world.mutateLocal(cab.id) { e in e.requestDoorsClose() }
        return "%CLOSE-S-DOOR, cab \(dLabel) doors closing\n"
    }

    func stopCmd(_ cmd: Parsed) -> String {
        var args = cmd.positional
        if args.first?.uppercased() == "CAB" { args.removeFirst() }
        guard let label = args.first else {
            return "%STOP-W-MISSPARM, usage: STOP CAB <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, elevator world not attached\n" }
        guard let cab = findCab(label: label, in: world) else {
            return "%STOP-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        let dLabel = world.displayLabel(for: cab)
        guard world.canControl(cab) else { return "%STOP-W-REMOTE, cab \(dLabel) is remote\n" }
        let n = cab.queue.count
        _ = world.mutateLocal(cab.id) { e in e.queue.removeAll() }
        return "%STOP-S-CLEARED, cab \(dLabel) queue cleared (\(n) call\(n == 1 ? "" : "s") aborted)\n"
    }

    /// Find a cab by user-supplied label, matching against display labels (L01, R01)
    /// as well as raw labels (01). Tolerates zero-padding ("2" finds "02") and case.
    func findCab(label raw: String, in world: ElevatorWorld) -> Elevator? {
        let needle = raw.uppercased()
        if let byDisplay = world.elevators.first(where: { world.displayLabel(for: $0).uppercased() == needle }) {
            return byDisplay
        }
        if let exact = world.elevators.first(where: { $0.label.uppercased() == needle }) {
            return exact
        }
        if let n = Int(needle) {
            if let byNumber = world.elevators.first(where: { Int($0.label) == n }) {
                return byNumber
            }
        }
        return nil
    }
}
