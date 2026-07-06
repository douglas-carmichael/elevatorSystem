import Foundation
import Combine

// DISPATCH SIMULATOR, NOT A SAFETY CONTROLLER.
//
// `ElevatorWorld.tick()` runs at the simulator's tick rate (Sim.tickHz,
// currently 60 Hz) and walks every cab through one step of door state,
// trapezoidal motion, alarm sampling, and building-mode enforcement.
// The structure mirrors a PLC's cyclic scan: read inputs (queue, door
// sensors), execute logic (advance), update outputs (publishes), then
// repeat. Real elevators use a safety-rated controller (e.g. SIL-3
// per IEC 61508 / EN 81-20 §5.11) running a deterministic 10..50 ms
// scan with hardware watchdog and category-3 safety chains. THIS code
// is a dispatch + visualisation simulator -- the safety chain checks
// in `advance()` (door interlock, terminal limits, brake state) are
// modelled so the operator panel and SCADA log read like the real
// thing, but nothing here is approved to drive an actual hoist motor.

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

/// Group-control strategy for the building.
///
///  * `collective`  -- traditional up/down hall calls + per-cab queues.
///                     Riders press a direction button at the floor;
///                     each cab serves whatever's on its queue.
///  * `destination` -- modern "destination dispatch" (KONE PORT, Otis
///                     Compass, Schindler PORT 4D). A single lobby
///                     keypad takes the rider's destination floor and
///                     the group dispatcher pre-allocates the best cab
///                     before they board. There's no up/down split --
///                     the algorithm picks one cab per call by ETA and
///                     a small same-direction bias.
enum DispatchMode: String, Codable {
    case collective
    case destination
}

/// One allocated destination-dispatch trip. Kept in
/// ElevatorWorld.destinationLog as an audit trail so SHOW DISPATCH can
/// display recent allocations and the lobby keypad UI can confirm what
/// got assigned.
struct DestinationCall: Identifiable, Codable, Hashable {
    let id: UUID
    let sequence: Int
    let from: Int
    let to: Int
    let cabId: UUID
    let cabLabel: String
    let etaSeconds: Double
    let createdAt: Date
}

/// One landing-fixture call. Real systems distinguish hall calls
/// (riser-mounted up / down buttons next to the lobby doors) from
/// car calls (the floor-number buttons inside the cab). Collective
/// dispatch serves both, but the dispatcher needs to know who pressed
/// where so it can route the nearest cab travelling in the right
/// direction. Cleared once a matching cab arrives at the floor with
/// doors opened.
struct HallCall: Identifiable, Codable, Hashable {
    let id: UUID
    let sequence: Int
    let floor: Int
    /// The direction the rider wants to travel: .up or .down. Real
    /// risers have separate buttons; `.idle` is not a valid hall-call
    /// direction and is reserved for the cab-source case below.
    let direction: Direction
    let createdAt: Date
    /// Cab the dispatcher allocated this hall call to, if any. Stays
    /// nil until allocation; useful for SHOW CALLS audit.
    var assignedCabId: UUID?
}

/// Distinguishes a call recorded against a cab's queue: a "hall call"
/// was raised by a landing fixture (someone in the lobby), a "car
/// call" is an in-cab button press by a rider already onboard.
enum CallSource: String, Codable {
    case hall
    case car
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
    /// True when the alarm is backed by a live field condition that the
    /// tick sampler auto-manages (OVERLOAD, DOOR_OPEN, SAFETY_MODE, ...).
    /// Such alarms return to normal on their own when the condition
    /// clears and are NOT operator-clearable -- pressing CLEAR on an
    /// in-condition alarm would be alarm suppression (ISA-18.2), so the
    /// panel skips them. Latched faults (manual fault-injection buttons,
    /// the injector) leave this false and must be cleared by the operator.
    var processDriven: Bool = false

    var isActive: Bool { clearedAt == nil }
    var isAcknowledged: Bool { acknowledgedAt != nil }
    /// A latched fault the operator is expected to CLEAR. Process-driven
    /// alarms self-clear when the field condition returns to normal.
    var isOperatorClearable: Bool { isActive && !processDriven }
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

    /// Current group-control strategy. Defaults to .collective so the
    /// behaviour everyone is used to is preserved; flipping to
    /// .destination switches the building into destination-dispatch
    /// mode (auto-driver stands down, all CALL flow goes through
    /// `allocateDestination`).
    @Published var dispatchMode: DispatchMode = .collective
    /// Most-recent destination-dispatch allocations (newest first).
    /// SHOW DISPATCH and any lobby-keypad UI read this log; capped at
    /// 20 entries to keep the table on-screen.
    @Published private(set) var destinationLog: [DestinationCall] = []
    private var nextDestinationSequence: Int = 1

    /// Active landing-fixture hall calls. Distinct from each cab's
    /// `queue` (which is a flat list of floors that cab is committed
    /// to serve, regardless of who raised the call). SHOW CALLS pulls
    /// from here; the auto-driver / collective dispatcher allocates
    /// each hall call to a cab and removes it once serviced.
    @Published private(set) var hallCalls: [HallCall] = []
    private var nextHallCallSequence: Int = 1

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
            // PWR/MAINS is intentionally NOT auto-cleared here -- the
            // SCADA panel's PWR button is a manual fault-injection
            // toggle the operator drives during the demo, and the
            // tick-rate auto-clear would race the click and make the
            // button look broken. The alarm is raised automatically
            // under emergencyPower (below); when normality returns
            // it stays in the log until the operator acknowledges /
            // clears it, which is the real SCADA contract anyway.
        case .fireRecall:
            raiseAlarm(source: "SYS",
                       point: "SAFETY_MODE",
                       severity: .critical,
                       message: Strings.lookup("alarm.msg.fire", lang: .en),
                       processDriven: true)
        case .emergencyPower:
            raiseAlarm(source: "SYS",
                       point: "SAFETY_MODE",
                       severity: .major,
                       message: Strings.lookup("alarm.msg.epo", lang: .en),
                       processDriven: true)
            // Emergency-power means the building's running off the
            // backup generator -- which only kicks in once the mains
            // supply has actually failed. Raise PWR/MAINS automatically
            // so the SCADA log shows the upstream fault that caused
            // EPO, not just the operating-mode advisory.
            raiseAlarm(source: "PWR",
                       point: "MAINS",
                       severity: .critical,
                       message: Strings.lookup("alarm.msg.mains", lang: .en))
        }
    }

    private func sampleCabAlarms(at now: Date) {
        // A node's SCADA only monitors the cabs it OWNS. Remote cabs are
        // the owning node's responsibility -- sampling their broadcast
        // state here would raise cab faults (OVERLOAD, DOOR_HELD, ...) for
        // conditions this node can't remediate, so the operator could
        // never clear them: CLEAR ALL would wipe the row and the very next
        // tick would re-raise it from the still-overloaded remote cab.
        // (Matches the manual failure injector, which is already
        // local-only.)
        let localCabs = locallyOwned()
        let currentIds = Set(localCabs.map(\.id))
        doorOpenSince = doorOpenSince.filter { currentIds.contains($0.key) }
        doorClosingSince = doorClosingSince.filter { currentIds.contains($0.key) }
        dispatchStallSince = dispatchStallSince.filter { currentIds.contains($0.key) }

        for cab in localCabs {
            let source = "CAB \(displayLabel(for: cab))"
            sampleOverspeedAlarm(for: cab, source: source)
            sampleLandingZoneAlarm(for: cab, source: source)
            sampleDoorOpenAlarm(for: cab, source: source, at: now)
            sampleDoorCloseAlarm(for: cab, source: source, at: now)
            sampleDispatchStallAlarm(for: cab, source: source, at: now)
            sampleTerminalLimitAlarm(for: cab, source: source)
            sampleBrakeHoldAlarm(for: cab, source: source)
            sampleLoadCellAlarms(for: cab, source: source)
        }
    }

    /// Raise FULL_LOAD (advisory) when the cab is above the 80%
    /// anti-nuisance threshold so the dispatcher / auto-driver can
    /// skip extra hall calls, and OVERLOAD (critical) when above 110%
    /// of rated capacity -- which also latches the door-close
    /// interlock in `advance()`.
    private func sampleLoadCellAlarms(for cab: Elevator, source: String) {
        let rated = cab.profile.ratedLoadKg
        if cab.loadKg > rated * 1.10 {
            raiseAlarm(source: source,
                       point: "OVERLOAD",
                       severity: .critical,
                       message: Strings.lookup("alarm.msg.overload", lang: .en),
                       processDriven: true)
        } else {
            clearAlarm(source: source, point: "OVERLOAD")
        }
        if cab.loadKg > rated * 0.80 {
            raiseAlarm(source: source,
                       point: "FULL_LOAD",
                       severity: .advisory,
                       message: Strings.lookup("alarm.msg.fullload", lang: .en),
                       processDriven: true)
        } else {
            clearAlarm(source: source, point: "FULL_LOAD")
        }
    }

    /// Raises TERMINAL_LIMIT when a cab is parked exactly at floor 1
    /// or the top floor with a queued target on the wrong side -- the
    /// hardware limit switch in advance() will have already clamped
    /// velocity to zero, so this surfaces the trip to the operator.
    private func sampleTerminalLimitAlarm(for cab: Elevator, source: String) {
        let atBottom = cab.position <= Double(Sim.firstFloor) + 0.001
        let atTop = cab.position >= Double(Sim.lastFloor) - 0.001
        let badBottom = atBottom &&
            (cab.queue.first.map { $0 < Sim.firstFloor } ?? false)
        let badTop = atTop &&
            (cab.queue.first.map { $0 > Sim.lastFloor } ?? false)
        if badBottom || badTop {
            raiseAlarm(source: source,
                       point: "TERMINAL_LIMIT",
                       severity: .critical,
                       message: Strings.lookup("alarm.msg.terminallimit", lang: .en),
                       processDriven: true)
        } else {
            clearAlarm(source: source, point: "TERMINAL_LIMIT")
        }
    }

    /// Brake-holding-while-moving fault. In a healthy install the
    /// brake releases before motion and engages on arrival; if we
    /// ever see appreciable velocity while the dispatcher still has
    /// the brake commanded, the brake is dragging or the contactor
    /// has welded -- both critical events.
    private func sampleBrakeHoldAlarm(for cab: Elevator, source: String) {
        if cab.brakeEngaged && abs(cab.velocity) > 0.10 {
            raiseAlarm(source: source,
                       point: "BRAKE_HOLD",
                       severity: .critical,
                       message: Strings.lookup("alarm.msg.brakehold", lang: .en),
                       processDriven: true)
        } else {
            clearAlarm(source: source, point: "BRAKE_HOLD")
        }
    }

    private func sampleOverspeedAlarm(for cab: Elevator, source: String) {
        let limit = cab.profile.travelFloorsPerSecond * 1.15
        if abs(cab.velocity) > limit {
            raiseAlarm(source: source,
                       point: "OVERSPEED",
                       severity: .critical,
                       message: Strings.lookup("alarm.msg.overspeed", lang: .en),
                       processDriven: true)
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
                       message: Strings.lookup("alarm.msg.landingzone", lang: .en),
                       processDriven: true)
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
                       message: Strings.lookup("alarm.msg.doorheld", lang: .en),
                       processDriven: true)
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
                       message: Strings.lookup("alarm.msg.doorclose", lang: .en),
                       processDriven: true)
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
                       message: Strings.lookup("alarm.msg.dispatchstall", lang: .en),
                       processDriven: true)
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
                // Cab just opened at a landing -- run the boarding /
                // alighting model so the load cells show realistic
                // fluctuation during the demo. Idempotent within a
                // single open cycle (doors transition opening->open
                // once per stop).
                applyBoarding(&elev)
            }
            elev.direction = .idle
            elev.brakeEngaged = true
            return
        case .open:
            // Phase II ("fireman's operation") and Independent Service
            // both require the cab to hold its doors open until the
            // operator explicitly commands a close -- the dwell timer
            // is suspended.
            if elev.phaseTwoActive || elev.independentActive {
                elev.direction = .idle
                elev.brakeEngaged = true
                return
            }
            elev.doorDwellRemaining -= dt
            // Light-curtain / safety-edge: don't even start closing
            // while an obstruction is reported.
            //
            // Overload interlock: ASME A17.1 §3.6 / EN 81-20 §5.12.1.2
            // forbid a cab loaded above 110% of rated capacity from
            // departing. The doors stay parked open with the cab
            // buzzer expected -- here, the dwell countdown latches at
            // zero so the door-held alarm timer in sampleDoorOpenAlarm
            // begins ticking, the OVERLOAD alarm fires, and the cab
            // can't leave the landing until weight drops.
            let overloaded = elev.loadKg >
                elev.profile.ratedLoadKg * 1.10
            if elev.doorDwellRemaining <= 0 &&
               !elev.doorObstructed &&
               !overloaded {
                elev.doors = .closing
                elev.doorProgress = 0
            }
            elev.direction = .idle
            elev.brakeEngaged = true
            return
        case .closing:
            // Door reversal on obstruction: any safety-edge / light-
            // curtain trip during the close cycle reverses the doors
            // back to .opening and re-arms the dwell so the rider
            // has time to clear the threshold. Equivalent to the
            // EN 81-20 §5.3.6.2.2 reopening requirement.
            if elev.doorObstructed {
                elev.doors = .opening
                elev.doorProgress = 1.0 - elev.doorProgress
                elev.direction = .idle
                elev.brakeEngaged = true
                return
            }
            elev.doorProgress += dt / prof.doorCloseDuration
            if elev.doorProgress >= 1.0 {
                elev.doorProgress = 0
                elev.doors = .closed
            } else {
                elev.direction = .idle
                elev.brakeEngaged = true
                return
            }
        case .closed:
            break
        }

        // Safety chain: ASME A17.1 §2.26 / EN 81-20 §5.11 require that
        // motion only ever be commanded when every door is confirmed
        // closed and the gate / interlock circuit is made. The case
        // analysis above already guarantees that, but a redundant
        // guard makes the interlock visible to anyone reading the
        // dispatch loop -- and catches the day someone adds a new
        // door state and forgets to wire it through.
        guard elev.doors == .closed else {
            elev.velocity = 0
            elev.direction = .idle
            elev.brakeEngaged = true
            return
        }

        // Active-alarm interlock: certain SCADA alarms must inhibit
        // motion until the operator acknowledges and clears them.
        // BRAKE / DOOR_ZONE on this cab keep the cab from moving (the
        // brake is forced engaged); a system-wide CONTROLLER fault
        // freezes every local cab. The cab decelerates to a stop and
        // stays parked with the brake set -- this is what a real lift
        // does when a safety chain link opens.
        if motionInhibitedByAlarm(for: elev) {
            decelerateToStop(&elev, dt: dt)
            elev.direction = .idle
            if abs(elev.velocity) < 0.01 { elev.brakeEngaged = true }
            return
        }

        guard let target = elev.queue.first else {
            // No call queued -- bring the cab to a stop with the same
            // acceleration ceiling the trapezoidal profile uses for
            // travel, so a cancelled trip doesn't slam to zero
            // instantaneously. The brake engages once we're at rest.
            decelerateToStop(&elev, dt: dt)
            elev.direction = .idle
            if abs(elev.velocity) < 0.01 { elev.brakeEngaged = true }
            return
        }

        // Brake release: on real hardware the motor controller builds
        // up holding torque BEFORE the brake lifts, otherwise the cab
        // sags. We approximate that by releasing the brake the moment
        // a motion command is about to be issued -- in the same scan
        // cycle the trapezoidal profile will start ramping velocity.
        elev.brakeEngaged = false

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

        // Terminal limit switches: ASME A17.1 §2.25 requires hard-
        // wired NORMAL and FINAL limit switches at both terminals
        // independent of the controller's queue logic. If a software
        // bug or sensor drift drives the cab past floor 1 or the top
        // floor, the limit trips -- we clamp the position, kill the
        // velocity, set the brake, and let the alarm sampler raise
        // TERMINAL_LIMIT next tick so the operator sees a fault.
        let topFloor = Double(Sim.lastFloor)
        let bottomFloor = Double(Sim.firstFloor)
        if elev.position <= bottomFloor && elev.velocity < 0 {
            elev.position = bottomFloor
            elev.velocity = 0
            elev.brakeEngaged = true
        } else if elev.position >= topFloor && elev.velocity > 0 {
            elev.position = topFloor
            elev.velocity = 0
            elev.brakeEngaged = true
        }

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
            elev.brakeEngaged = true
            // Cab arriving at a floor extinguishes any hall-call
            // lantern latched there, so the landing fixture and SHOW
            // CALLS audit reflect that the rider has been served.
            clearServicedHallCalls(at: target)
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

    /// Returns true if any active SCADA alarm should mechanically
    /// prevent this cab from moving. The mapping is industry-typical:
    ///
    ///   * CAB <label> BRAKE     -- brake-contact fault: refuse to release
    ///   * CAB <label> DOOR_ZONE -- door-zone sensor unreliable: hold
    ///   * SYS CONTROLLER        -- controller watchdog: freeze every cab
    ///
    /// The operator clears the alarm via the SCADA panel or
    /// `ACKNOWLEDGE ALARM ALL` in DCL once the upstream fault has been
    /// addressed; the cab returns to service the next scan tick.
    private func motionInhibitedByAlarm(for cab: Elevator) -> Bool {
        let cabSource = "CAB \(displayLabel(for: cab))"
        for alarm in alarmLog where alarm.isActive {
            if alarm.source == "SYS" && alarm.point == "CONTROLLER" { return true }
            if alarm.source == cabSource {
                switch alarm.point {
                case "BRAKE", "DOOR_ZONE": return true
                default: break
                }
            }
        }
        return false
    }

    /// Cheap boarding / alighting model invoked once per door-open
    /// cycle. Models lobby surge (more passengers join at floor 1 /
    /// the recall floor) and per-stop turnover at other floors. The
    /// numbers aren't a real building-traffic model -- they're enough
    /// to drive realistic load-cell fluctuation, FULL_LOAD and
    /// OVERLOAD alarms during the demo.
    private func applyBoarding(_ elev: inout Elevator) {
        let floor = Int(elev.position.rounded())
        let isLobby = floor == recallFloor
        switch elev.profile {
        case .pax:
            // 75 kg per "passenger". Lobby surge boards 1-4 people,
            // alighting at upper floors is 0-3 people; net effect
            // builds load on the way up and drains on the way back.
            let boarders = isLobby ? Int.random(in: 1...4) : Int.random(in: 0...2)
            let alighters = isLobby ? 0 : Int.random(in: 0...3)
            let delta = Double(boarders - alighters) * 75.0
            elev.loadKg = max(0, elev.loadKg + delta)
        case .freight:
            // Freight loads are chunkier and less frequent. ~80 kg
            // per "tote" with bigger swings.
            let delta = Double.random(in: -240...240)
            elev.loadKg = max(0, elev.loadKg + delta)
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
            // Sort on the *displayed* label (peer letter + number, e.g.
            // "A01"), not the raw per-cab label -- otherwise remote cabs
            // from different peers interleave by number (A01, B01, C01,
            // A02, ...) instead of grouping per peer (A01..A04, B01..B04).
            return displayLabel(for: a).localizedStandardCompare(displayLabel(for: b)) == .orderedAscending
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
    func raiseAlarm(source: String, point: String, severity: AlarmSeverity, message: String, processDriven: Bool = false) -> SCADAAlarm {
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
                               message: message,
                               processDriven: processDriven)
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

    /// Clear every operator-clearable (latched) active alarm outright,
    /// regardless of whether it has been acknowledged. Returns the number
    /// cleared. (Distinct from CLEAR ACK, which only clears latched alarms
    /// already acknowledged.) Process-driven alarms are deliberately left
    /// alone -- they reflect a live field condition and would be re-raised
    /// by the next tick, so "clearing" them would be meaningless alarm
    /// suppression; they self-clear when the condition returns to normal.
    @discardableResult
    func clearAllActiveAlarms() -> Int {
        let now = Date()
        var count = 0
        for index in alarmLog.indices where alarmLog[index].isOperatorClearable {
            alarmLog[index].clearedAt = now
            count += 1
        }
        return count
    }

    /// Clear only the latched alarms the operator has already acknowledged
    /// (the ACK-before-CLEAR discipline). Process-driven alarms are skipped
    /// for the same reason as `clearAllActiveAlarms()`. Returns the count.
    @discardableResult
    func clearAcknowledgedActiveAlarms() -> Int {
        let now = Date()
        var count = 0
        for index in alarmLog.indices
        where alarmLog[index].isOperatorClearable && alarmLog[index].isAcknowledged {
            alarmLog[index].clearedAt = now
            count += 1
        }
        return count
    }

    /// True when at least one latched fault is present for the operator to
    /// CLEAR. Drives the CLEAR ALL button's enabled state so it isn't lit
    /// when the only active alarms are self-clearing process alarms.
    var hasClearableAlarms: Bool {
        alarmLog.contains { $0.isOperatorClearable }
    }

    /// True when at least one *acknowledged* latched fault is present.
    /// Drives the CLEAR ACK button's enabled state.
    var hasClearableAcknowledgedAlarms: Bool {
        alarmLog.contains { $0.isOperatorClearable && $0.isAcknowledged }
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

    // MARK: -- Destination dispatch

    /// Allocate a destination-dispatch call. Picks the locally-owned
    /// cab with the lowest ETA to the origin floor (with a small
    /// same-direction bias) and pre-loads its queue with origin then
    /// destination so the rider is picked up first and dropped off
    /// second. Returns the resulting DestinationCall, or nil if no
    /// candidate cab is available (no local cabs, all are in Phase II
    /// / Independent / fire-recall / EPO-stranded).
    @discardableResult
    func allocateDestination(from: Int, to: Int) -> DestinationCall? {
        guard from != to else { return nil }
        let f = max(Sim.firstFloor, min(Sim.lastFloor, from))
        let t = max(Sim.firstFloor, min(Sim.lastFloor, to))
        guard f != t else { return nil }
        // Eligible cabs: locally-owned, not in a safety override, and
        // (under EPO) only the survivor.
        let candidates = elevators.filter { cab in
            guard cab.ownerPeerId == localPeerId else { return false }
            if cab.phaseTwoActive || cab.independentActive { return false }
            switch buildingMode {
            case .normal: return true
            case .fireRecall: return false
            case .emergencyPower: return cab.id == epoCabId
            }
        }
        guard !candidates.isEmpty else { return nil }
        var best: (cab: Elevator, score: Double, eta: Double)?
        for cab in candidates {
            let eta = estimatedSecondsToFloor(cab: cab, floor: f)
            // Same-direction bias: if the cab is currently moving away
            // from the origin call, add a soft 5-second penalty so a
            // closer-but-wrong-direction cab loses to a slightly more
            // distant cab that's already heading our way.
            var score = eta
            if cab.direction == .up && f < cab.nearestFloor { score += 5.0 }
            if cab.direction == .down && f > cab.nearestFloor { score += 5.0 }
            if best == nil || score < best!.score {
                best = (cab, score, eta)
            }
        }
        guard let pick = best else { return nil }
        // Enqueue origin then destination so the cab picks the rider
        // up before drop-off.
        mutateLocal(pick.cab.id) { e in
            e.enqueue(floor: f)
            e.enqueue(floor: t)
        }
        let call = DestinationCall(id: UUID(),
                                   sequence: nextDestinationSequence,
                                   from: f,
                                   to: t,
                                   cabId: pick.cab.id,
                                   cabLabel: displayLabel(for: pick.cab),
                                   etaSeconds: pick.eta,
                                   createdAt: Date())
        nextDestinationSequence += 1
        destinationLog.insert(call, at: 0)
        if destinationLog.count > 20 {
            destinationLog.removeLast(destinationLog.count - 20)
        }
        return call
    }

    /// Coarse ETA estimate: time to finish the cab's current queue
    /// (treating each stop as ~1.5 s of dwell + travel at max profile
    /// speed) plus the trip from the last queued floor to `floor`.
    /// Good enough to rank candidate cabs; not a real motion model.
    private func estimatedSecondsToFloor(cab: Elevator, floor: Int) -> Double {
        var time = 0.0
        var position = cab.position
        let maxSpeed = cab.profile.travelFloorsPerSecond
        let stops = cab.queue + [floor]
        for stop in stops {
            let dist = abs(Double(stop) - position)
            time += dist / maxSpeed + 1.5
            position = Double(stop)
        }
        return time
    }

    var remotePeerIds: [String] {
        Array(Set(elevators.compactMap { $0.ownerPeerId != localPeerId ? $0.ownerPeerId : nil })).sorted()
    }

    func peerLetter(for peerId: String) -> String {
        let remoteIds = remotePeerIds
        let index = remoteIds.firstIndex(of: peerId) ?? 0
        return String(UnicodeScalar(UInt32(UnicodeScalar("A").value) + UInt32(index))!)
    }

    /// The node letter shown as a cab-label prefix: "L" for the local node,
    /// "A"/"B"/... for remote peers (matching `displayLabel(for:)`). Used to
    /// scope diagnostics to one node via `RUN <image> /NODE=<letter>`.
    func nodeLetter(for elev: Elevator) -> String {
        elev.ownerPeerId == localPeerId ? "L" : peerLetter(for: elev.ownerPeerId)
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

    // MARK: -- Hall calls (landing-fixture button presses)

    /// Register a landing-fixture hall call. Distinct entry point from
    /// `enqueue(floor:)` which models an in-cab car-call: a hall call
    /// goes onto `world.hallCalls` first, then gets allocated to the
    /// best cab (under collective mode that means nearest cab moving
    /// in the requested direction; under destination mode a hall call
    /// must be re-issued through `allocateDestination` since the
    /// rider's destination is also required).
    @discardableResult
    func registerHallCall(floor: Int, direction: Direction, allocate: Bool = true) -> HallCall? {
        guard direction == .up || direction == .down else { return nil }
        let f = max(Sim.firstFloor, min(Sim.lastFloor, floor))
        // Coalesce duplicates -- one riser button latches, one entry.
        if let existing = hallCalls.first(where: { $0.floor == f && $0.direction == direction }) {
            return existing
        }
        let assigned = allocate ? allocateHallCall(floor: f, direction: direction) : nil
        let call = HallCall(id: UUID(),
                            sequence: nextHallCallSequence,
                            floor: f,
                            direction: direction,
                            createdAt: Date(),
                            assignedCabId: assigned)
        nextHallCallSequence += 1
        hallCalls.insert(call, at: 0)
        if hallCalls.count > 40 {
            hallCalls.removeLast(hallCalls.count - 40)
        }
        return call
    }

    /// Remove a single hall call by id. Used by the LAMP_TEST diagnostic
    /// to extinguish a test-induced lantern entry without dispatching
    /// a cab.
    func removeHallCall(id: UUID) {
        hallCalls.removeAll { $0.id == id }
    }

    /// Pick the cab best suited to answer a hall call: lowest ETA,
    /// with a soft bias for cabs already heading in the requested
    /// direction (a rider pressing UP gets a cab travelling up rather
    /// than one heading down past them). Pre-loads the cab's queue
    /// with the origin floor so motion starts the next tick.
    private func allocateHallCall(floor: Int, direction: Direction) -> UUID? {
        let candidates = elevators.filter { cab in
            guard cab.ownerPeerId == localPeerId else { return false }
            if cab.phaseTwoActive || cab.independentActive { return false }
            switch buildingMode {
            case .normal: return true
            case .fireRecall: return false
            case .emergencyPower: return cab.id == epoCabId
            }
        }
        guard !candidates.isEmpty else { return nil }
        var best: (cab: Elevator, score: Double)?
        for cab in candidates {
            let dist = abs(Double(floor) - cab.position)
            var score = dist / cab.profile.travelFloorsPerSecond
            // Same-direction bias: a cab heading the rider's way is
            // worth a soft 3-second bonus over one heading away.
            if cab.direction == direction { score -= 3.0 }
            if cab.direction != .idle && cab.direction != direction { score += 4.0 }
            if best == nil || score < best!.score {
                best = (cab, score)
            }
        }
        guard let pick = best else { return nil }
        mutateLocal(pick.cab.id) { e in e.enqueue(floor: floor) }
        return pick.cab.id
    }

    /// Called after `advance()` opens the doors at a floor. Any hall
    /// call latched for this floor in a direction the cab can serve
    /// is cleared; from the rider's perspective the up / down lantern
    /// in the lobby goes out.
    private func clearServicedHallCalls(at floor: Int) {
        hallCalls.removeAll { call in call.floor == floor }
    }

    /// Apply a cab-control action to a LOCALLY-OWNED cab. This is the
    /// single choke point both the local operator path and the inbound
    /// peer `.command` handler funnel through: because it goes via
    /// `mutateLocal`, a request for a cab this node doesn't own is
    /// silently ignored (returns nil) -- a node never mutates a cab it
    /// doesn't own, no matter who asked. On success the resulting state
    /// is published to peers via `onLocalChange`.
    @discardableResult
    func applyControl(cabId: UUID, kind: CabCommandKind, floor: Int?) -> Elevator? {
        mutateLocal(cabId) { e in
            switch kind {
            case .call:
                if let floor { e.enqueue(floor: floor) }
            case .open:
                e.requestDoorsOpen()
            case .close:
                e.requestDoorsClose()
            case .stop:
                e.queue.removeAll()
            }
        }
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
