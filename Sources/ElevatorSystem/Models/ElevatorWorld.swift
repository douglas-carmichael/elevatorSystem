import Foundation
import Combine

/// Building-wide operating mode. Real elevator code (ASME A17.1 §2.27,
/// EN 81-72 / EN 81-73) requires the system to override every cab's
/// normal call-handling behaviour under certain conditions.
enum BuildingMode: String, Codable {
    /// Normal automatic group dispatch.
    case normal
    /// Phase I Fire Service Recall: every cab is taken out of service,
    /// existing car / hall calls are cancelled, and each cab travels
    /// directly to the designated recall floor with doors open. The
    /// auto-driver is suspended for the duration.
    case fireRecall
    /// Emergency Power Operation: the backup generator can only run
    /// ONE cab at a time. The designated cab keeps running; all other
    /// cabs are sent to the recall floor with doors open, then held.
    case emergencyPower
}

enum AlarmSeverity: Int, Codable, CaseIterable, Comparable {
    case advisory = 0
    case minor = 1
    case major = 2
    case critical = 3

    static func < (lhs: AlarmSeverity, rhs: AlarmSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .advisory: return "ADVISORY"
        case .minor: return "MINOR"
        case .major: return "MAJOR"
        case .critical: return "CRITICAL"
        }
    }
}

struct SCADAAlarm: Identifiable, Codable, Hashable {
    let id: UUID
    let sequence: Int
    let raisedAt: Date
    var acknowledgedAt: Date?
    var clearedAt: Date?
    let source: String
    let point: String
    let severity: AlarmSeverity
    let message: String

    var isActive: Bool { clearedAt == nil }
    var isAcknowledged: Bool { acknowledgedAt != nil }
    var statusLabel: String {
        if clearedAt != nil { return "CLEARED" }
        return acknowledgedAt == nil ? "UNACK" : "ACK"
    }
}

@MainActor
final class ElevatorWorld: ObservableObject {
    @Published var elevators: [Elevator] = []
    @Published var localPeerId: String
    @Published var localPeerLabel: String

    /// Current building-wide safety mode. Defaults to .normal.
    @Published var buildingMode: BuildingMode = .normal
    /// Floor every cab is recalled to under .fireRecall and
    /// .emergencyPower. Defaults to the lowest building floor.
    @Published var recallFloor: Int = Sim.firstFloor
    /// Cab designated to remain operational on emergency-power. While
    /// `buildingMode == .emergencyPower` every other cab is held at
    /// the recall floor.
    @Published var epoCabId: UUID?
    @Published private(set) var alarmLog: [SCADAAlarm] = []

    private var timer: Timer?
    private var lastTickAt: Date = .init()
    private var nextAlarmSequence: Int = 1
    private var doorOpenSince: [UUID: Date] = [:]
    private var doorClosingSince: [UUID: Date] = [:]
    private var dispatchStallSince: [UUID: Date] = [:]
    var onLocalChange: ((Elevator) -> Void)?

    init(localPeerId: String = UUID().uuidString, localPeerLabel: String = Host.current().localizedName ?? "LOCAL") {
        self.localPeerId = localPeerId
        self.localPeerLabel = localPeerLabel
    }

    func start() {
        guard timer == nil else { return }
        lastTickAt = Date()
        let t = Timer(timeInterval: Sim.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastTickAt))
        lastTickAt = now
        enforceBuildingMode()
        for index in elevators.indices {
            advance(&elevators[index], dt: dt)
        }
        sampleSystemAlarms()
        sampleCabAlarms(at: now)
    }

    private func sampleSystemAlarms() {
        switch buildingMode {
        case .normal:
            clearAlarm(source: "SYS", point: "SAFETY_MODE")
        case .fireRecall:
            raiseAlarm(source: "SYS",
                       point: "SAFETY_MODE",
                       severity: .critical,
                       message: Strings.lookup("alarm.msg.fire", lang: .en))
        case .emergencyPower:
            raiseAlarm(source: "SYS",
                       point: "SAFETY_MODE",
                       severity: .major,
                       message: Strings.lookup("alarm.msg.epo", lang: .en))
        }
    }

    private func sampleCabAlarms(at now: Date) {
        let currentIds = Set(elevators.map(\.id))
        doorOpenSince = doorOpenSince.filter { currentIds.contains($0.key) }
        doorClosingSince = doorClosingSince.filter { currentIds.contains($0.key) }
        dispatchStallSince = dispatchStallSince.filter { currentIds.contains($0.key) }

        for cab in elevators {
            let source = "CAB \(displayLabel(for: cab))"
            sampleOverspeedAlarm(for: cab, source: source)
            sampleLandingZoneAlarm(for: cab, source: source)
            sampleDoorOpenAlarm(for: cab, source: source, at: now)
            sampleDoorCloseAlarm(for: cab, source: source, at: now)
            sampleDispatchStallAlarm(for: cab, source: source, at: now)
        }
    }

    private func sampleOverspeedAlarm(for cab: Elevator, source: String) {
        let limit = cab.profile.travelFloorsPerSecond * 1.15
        if abs(cab.velocity) > limit {
            raiseAlarm(source: source,
                       point: "OVERSPEED",
                       severity: .critical,
                       message: Strings.lookup("alarm.msg.overspeed", lang: .en))
        } else {
            clearAlarm(source: source, point: "OVERSPEED")
        }
    }

    private func sampleLandingZoneAlarm(for cab: Elevator, source: String) {
        let stoppedBetweenFloors = !cab.isStoppedAtFloor &&
            abs(cab.velocity) < 0.02 &&
            cab.queue.isEmpty &&
            cab.doors == .closed
        if stoppedBetweenFloors {
            raiseAlarm(source: source,
                       point: "LANDING_ZONE",
                       severity: .major,
                       message: Strings.lookup("alarm.msg.landingzone", lang: .en))
        } else {
            clearAlarm(source: source, point: "LANDING_ZONE")
        }
    }

    private func sampleDoorOpenAlarm(for cab: Elevator, source: String, at now: Date) {
        let shouldTrack = cab.doors == .open &&
            !cab.phaseTwoActive &&
            !cab.independentActive &&
            buildingMode == .normal
        guard shouldTrack else {
            doorOpenSince.removeValue(forKey: cab.id)
            clearAlarm(source: source, point: "DOOR_OPEN")
            return
        }

        let startedAt = doorOpenSince[cab.id] ?? now
        doorOpenSince[cab.id] = startedAt
        if now.timeIntervalSince(startedAt) > cab.profile.doorDwellDuration + 6.0 {
            raiseAlarm(source: source,
                       point: "DOOR_OPEN",
                       severity: .minor,
                       message: Strings.lookup("alarm.msg.doorheld", lang: .en))
        } else {
            clearAlarm(source: source, point: "DOOR_OPEN")
        }
    }

    private func sampleDoorCloseAlarm(for cab: Elevator, source: String, at now: Date) {
        guard cab.doors == .closing else {
            doorClosingSince.removeValue(forKey: cab.id)
            clearAlarm(source: source, point: "DOOR_CLOSE")
            return
        }

        let startedAt = doorClosingSince[cab.id] ?? now
        doorClosingSince[cab.id] = startedAt
        if now.timeIntervalSince(startedAt) > cab.profile.doorCloseDuration * 3.0 {
            raiseAlarm(source: source,
                       point: "DOOR_CLOSE",
                       severity: .major,
                       message: Strings.lookup("alarm.msg.doorclose", lang: .en))
        } else {
            clearAlarm(source: source, point: "DOOR_CLOSE")
        }
    }

    private func sampleDispatchStallAlarm(for cab: Elevator, source: String, at now: Date) {
        let hasUnservedTarget = cab.queue.first.map { $0 != cab.nearestFloor || !cab.isStoppedAtFloor } ?? false
        let shouldTrack = hasUnservedTarget &&
            cab.doors == .closed &&
            abs(cab.velocity) < 0.02 &&
            buildingMode == .normal &&
            !cab.phaseTwoActive &&
            !cab.independentActive
        guard shouldTrack else {
            dispatchStallSince.removeValue(forKey: cab.id)
            clearAlarm(source: source, point: "DISPATCH")
            return
        }

        let startedAt = dispatchStallSince[cab.id] ?? now
        dispatchStallSince[cab.id] = startedAt
        if now.timeIntervalSince(startedAt) > 4.0 {
            raiseAlarm(source: source,
                       point: "DISPATCH",
                       severity: .major,
                       message: Strings.lookup("alarm.msg.dispatchstall", lang: .en))
        } else {
            clearAlarm(source: source, point: "DISPATCH")
        }
    }

    /// Enforce Phase I / EPO behaviour every tick: cabs that must
    /// recall get their queue replaced with the recall floor and have
    /// their doors held open once they get there.
    private func enforceBuildingMode() {
        guard buildingMode != .normal else { return }
        let local = locallyOwned()
        for cab in local {
            let mustRecall: Bool
            switch buildingMode {
            case .fireRecall:
                mustRecall = true
            case .emergencyPower:
                mustRecall = (cab.id != epoCabId)
            case .normal:
                mustRecall = false
            }
            guard mustRecall else { continue }
            mutateLocal(cab.id) { e in
                let parked = e.isStoppedAtFloor && e.nearestFloor == recallFloor
                if !parked {
                    if e.queue != [recallFloor] {
                        e.queue = [recallFloor]
                    }
                    return
                }
                // Already at the recall floor: open the doors if they
                // aren't already, and hold them open indefinitely so
                // the cab can't sneak back into service.
                e.queue = []
                if e.doors == .closed || e.doors == .closing {
                    e.doors = .opening
                    e.doorProgress = e.doors == .closing
                        ? 1.0 - e.doorProgress
                        : 0
                } else if e.doors == .open {
                    e.doorDwellRemaining = max(e.doorDwellRemaining, 999.0)
                }
            }
        }
    }

    private func advance(_ elev: inout Elevator, dt: Double) {
        let prof = elev.profile
        switch elev.doors {
        case .opening:
            elev.doorProgress += dt / prof.doorOpenDuration
            if elev.doorProgress >= 1.0 {
                elev.doorProgress = 1.0
                elev.doors = .open
                elev.doorDwellRemaining = prof.doorDwellDuration
            }
            elev.direction = .idle
            return
        case .open:
            // Phase II ("fireman's operation") and Independent Service
            // both require the cab to hold its doors open until the
            // operator explicitly commands a close -- the dwell timer
            // is suspended.
            if elev.phaseTwoActive || elev.independentActive {
                elev.direction = .idle
                return
            }
            elev.doorDwellRemaining -= dt
            if elev.doorDwellRemaining <= 0 {
                elev.doors = .closing
                elev.doorProgress = 0
            }
            elev.direction = .idle
            return
        case .closing:
            elev.doorProgress += dt / prof.doorCloseDuration
            if elev.doorProgress >= 1.0 {
                elev.doorProgress = 0
                elev.doors = .closed
            } else {
                elev.direction = .idle
                return
            }
        case .closed:
            break
        }

        guard let target = elev.queue.first else {
            // No call queued -- bring the cab to a stop with the same
            // acceleration ceiling the trapezoidal profile uses for
            // travel, so a cancelled trip doesn't slam to zero
            // instantaneously.
            decelerateToStop(&elev, dt: dt)
            elev.direction = .idle
            return
        }

        // Trapezoidal velocity profile. Target speed is the highest
        // value that still lets us decelerate to zero by the time we
        // reach the floor (using v² = 2 a s for the braking distance).
        // Velocity changes are clamped to ±maxAccel * dt so each tick
        // looks like a smooth motor command instead of a teleport.
        let dy = Double(target) - elev.position
        let maxSpeed = prof.travelFloorsPerSecond
        let maxAccel = prof.travelAccel
        let dirSign: Double = dy >= 0 ? 1 : -1
        let absDistance = abs(dy)
        let stoppingDistance = (elev.velocity * elev.velocity) / (2 * maxAccel)
        let targetSpeedMag: Double
        if absDistance > stoppingDistance {
            // Still in the acceleration / cruise band -- aim for max.
            targetSpeedMag = min(maxSpeed, sqrt(maxSpeed * maxSpeed))
        } else {
            // Inside the deceleration band -- pick the speed that lets
            // us coast to a stop exactly at the floor.
            targetSpeedMag = sqrt(2 * maxAccel * absDistance)
        }
        let targetVelocity = dirSign * targetSpeedMag
        let dv = targetVelocity - elev.velocity
        let maxDv = maxAccel * dt
        elev.velocity += max(-maxDv, min(maxDv, dv))

        // Integrate position.
        elev.position += elev.velocity * dt

        // Arrival detection: when we're close to the target and moving
        // slowly enough, snap to the floor and open the doors. The
        // velocity threshold prevents a tick from skipping past the
        // arrival check.
        if abs(elev.position - Double(target)) < 0.05,
           abs(elev.velocity) < (maxAccel * dt * 1.5) {
            elev.position = Double(target)
            elev.velocity = 0
            elev.queue.removeFirst()
            elev.doors = .opening
            elev.doorProgress = 0
            elev.direction = .idle
            return
        }

        // Set the published direction flag from the current velocity
        // sign so the UI and SHOW QUEUE stay accurate during the
        // accel / decel phases.
        if elev.velocity > 0.01 {
            elev.direction = .up
        } else if elev.velocity < -0.01 {
            elev.direction = .down
        } else {
            elev.direction = .idle
        }
    }

    private func decelerateToStop(_ elev: inout Elevator, dt: Double) {
        let maxAccel = elev.profile.travelAccel
        let maxDv = maxAccel * dt
        if abs(elev.velocity) <= maxDv {
            elev.velocity = 0
        } else {
            elev.velocity -= maxDv * (elev.velocity > 0 ? 1 : -1)
        }
        elev.position += elev.velocity * dt
    }

    func upsert(_ elev: Elevator) {
        if let idx = elevators.firstIndex(where: { $0.id == elev.id }) {
            elevators[idx] = elev
        } else {
            elevators.append(elev)
        }
    }

    func removeAll(ownedBy peerId: String) {
        elevators.removeAll(where: { $0.ownerPeerId == peerId })
    }

    func locallyOwned() -> [Elevator] {
        elevators.filter { $0.ownerPeerId == localPeerId }
    }

    var sortedElevators: [Elevator] {
        elevators.sorted { a, b in
            let aLocal = a.ownerPeerId == localPeerId
            let bLocal = b.ownerPeerId == localPeerId
            if aLocal != bLocal { return aLocal }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    func canControl(_ elev: Elevator) -> Bool {
        elev.ownerPeerId == localPeerId
    }

    var activeAlarms: [SCADAAlarm] {
        alarmLog
            .filter(\.isActive)
            .sorted {
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                return $0.raisedAt > $1.raisedAt
            }
    }

    var unacknowledgedAlarmCount: Int {
        alarmLog.filter { $0.isActive && !$0.isAcknowledged }.count
    }

    var highestActiveSeverity: AlarmSeverity? {
        activeAlarms.map(\.severity).max()
    }

    @discardableResult
    func raiseAlarm(source: String, point: String, severity: AlarmSeverity, message: String) -> SCADAAlarm {
        if let index = alarmLog.firstIndex(where: { $0.isActive && $0.source == source && $0.point == point }) {
            return alarmLog[index]
        }
        let alarm = SCADAAlarm(id: UUID(),
                               sequence: nextAlarmSequence,
                               raisedAt: Date(),
                               acknowledgedAt: nil,
                               clearedAt: nil,
                               source: source,
                               point: point,
                               severity: severity,
                               message: message)
        nextAlarmSequence += 1
        alarmLog.insert(alarm, at: 0)
        if alarmLog.count > 200 {
            alarmLog.removeLast(alarmLog.count - 200)
        }
        return alarm
    }

    @discardableResult
    func acknowledgeAlarm(sequence: Int) -> Bool {
        guard let index = alarmLog.firstIndex(where: { $0.sequence == sequence && $0.isActive }) else { return false }
        guard alarmLog[index].acknowledgedAt == nil else { return true }
        alarmLog[index].acknowledgedAt = Date()
        return true
    }

    func acknowledgeAllAlarms() -> Int {
        var count = 0
        for index in alarmLog.indices where alarmLog[index].isActive && alarmLog[index].acknowledgedAt == nil {
            alarmLog[index].acknowledgedAt = Date()
            count += 1
        }
        return count
    }

    @discardableResult
    func clearAlarm(sequence: Int) -> Bool {
        guard let index = alarmLog.firstIndex(where: { $0.sequence == sequence && $0.isActive }) else { return false }
        alarmLog[index].clearedAt = Date()
        return true
    }

    @discardableResult
    func clearAlarm(source: String, point: String) -> Bool {
        guard let index = alarmLog.firstIndex(where: { $0.isActive && $0.source == source && $0.point == point }) else { return false }
        alarmLog[index].clearedAt = Date()
        return true
    }

    var remotePeerIds: [String] {
        Array(Set(elevators.compactMap { $0.ownerPeerId != localPeerId ? $0.ownerPeerId : nil })).sorted()
    }

    func peerLetter(for peerId: String) -> String {
        let remoteIds = remotePeerIds
        let index = remoteIds.firstIndex(of: peerId) ?? 0
        return String(UnicodeScalar(UInt32(UnicodeScalar("A").value) + UInt32(index))!)
    }

    func displayLabel(for elev: Elevator) -> String {
        if elev.ownerPeerId == localPeerId {
            return "L\(elev.label)"
        }
        let remotePeerIds = Set(elevators.map(\.ownerPeerId))
            .subtracting([localPeerId])
            .sorted()
        let index = remotePeerIds.firstIndex(of: elev.ownerPeerId) ?? 0
        let letter = String(UnicodeScalar(UInt32(UnicodeScalar("A").value) + UInt32(index))!)
        return "\(letter)\(elev.label)"
    }

    @discardableResult
    func mutateLocal(_ id: UUID, _ block: (inout Elevator) -> Void) -> Elevator? {
        guard let idx = elevators.firstIndex(where: { $0.id == id }) else { return nil }
        guard elevators[idx].ownerPeerId == localPeerId else { return nil }
        block(&elevators[idx])
        let snap = elevators[idx]
        onLocalChange?(snap)
        return snap
    }
}
