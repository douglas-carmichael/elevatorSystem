import Foundation

// Cab-control verbs: CALL / OPEN / CLOSE / STOP.
extension DCLEngine {
    func callCmd(_ cmd: Parsed) -> String {
        // CALL CAB <label> FLOOR <n>      (or CALL <label> <n>)
        var args = cmd.positional
        if args.first?.uppercased() == "CAB" { args.removeFirst() }
        guard args.count >= 2 else {
            return "%CALL-W-MISSPARM, usage: CALL CAB <label> FLOOR <n>\n"
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
