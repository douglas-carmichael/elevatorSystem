import Foundation

enum CabProfile: String, Codable, CaseIterable, Identifiable {
    case pax
    case freight

    var id: String { rawValue }

    var travelFloorsPerSecond: Double {
        switch self {
        case .pax:     return Sim.paxSpeed
        case .freight: return Sim.freightSpeed
        }
    }

    /// Acceleration ceiling in floors / sec². Used by the trapezoidal
    /// velocity profile in ElevatorWorld.advance() and surfaced by
    /// MONITOR DYNAMICS.
    var travelAccel: Double {
        switch self {
        case .pax:     return Sim.paxAccel
        case .freight: return Sim.freightAccel
        }
    }

    var doorOpenDuration: Double {
        switch self {
        case .pax:     return Sim.paxDoorOpen
        case .freight: return Sim.freightDoorOpen
        }
    }

    var doorCloseDuration: Double {
        switch self {
        case .pax:     return Sim.paxDoorClose
        case .freight: return Sim.freightDoorClose
        }
    }

    var doorDwellDuration: Double {
        switch self {
        case .pax:     return Sim.paxDoorDwell
        case .freight: return Sim.freightDoorDwell
        }
    }

    /// Rated load capacity in kg. The cab platform load cells (typically
    /// strain-gauge bridges under the floor isolation pads) report
    /// against this baseline; the dispatcher uses the 80% threshold for
    /// anti-nuisance ("FULL LOAD") and the 110% threshold for the
    /// overload interlock that forbids door-close per ASME A17.1 §3.6.
    var ratedLoadKg: Double {
        switch self {
        case .pax:     return 1000     // ~13 passengers @ 75 kg avg
        case .freight: return 2000
        }
    }
}

enum DoorState: String, Codable, CaseIterable {
    case closed
    case opening
    case open
    case closing
}

enum Direction: String, Codable, CaseIterable {
    case up
    case down
    case idle
}

struct Elevator: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var ownerPeerId: String
    var automatic: Bool
    var profile: CabProfile
    /// Absolute cab position in floor-units (1.0 = floor 1, 5.5 = mid-
    /// way between floors 5 and 6). In a real install this is derived
    /// from the hoist-motor encoder (typically a 1024-PPR incremental
    /// or absolute SSI device read by the controller's position card).
    /// Here it's a continuous Double updated by the dispatcher's scan
    /// loop -- treat the value as if it had been quantized to ~0.01 fl
    /// (10 mm in a 1-m floor-pitch building) coming off the encoder.
    var position: Double
    var queue: [Int]
    var doors: DoorState
    var doorProgress: Double
    var doorDwellRemaining: Double
    var direction: Direction
    /// Phase II Fire Service ("fireman's operation"): doors stay open
    /// indefinitely once at a floor and the auto-driver does not push
    /// new destinations. The car can still be called manually from DCL
    /// or Modbus -- it just won't auto-close. Only meaningful after
    /// Phase I has recalled the cab.
    var phaseTwoActive: Bool = false
    /// Independent service: cab ignores hall / group-dispatch calls and
    /// keeps its doors open at the current floor. Used for moving
    /// freight or VIP escort. Effectively a stronger form of /MANUAL.
    var independentActive: Bool = false
    /// Current cab velocity in floors / second. Positive means going
    /// up. Driven by the trapezoidal velocity profile in
    /// ElevatorWorld.advance() and surfaced by MONITOR DYNAMICS.
    var velocity: Double = 0
    /// Current cab acceleration in floors / second², the per-tick change in
    /// `velocity`. Signed (positive = speeding up in the +position sense).
    /// Surfaced by MONITOR DYNAMICS and Modbus IR.
    var acceleration: Double = 0
    /// Holding brake state. ASME A17.1 §2.24 requires the brake to
    /// remain set whenever the car is stopped at a landing and to be
    /// released only after the motor controller has built up holding
    /// torque. The dispatcher releases the brake when motion is about
    /// to start (`doors == .closed && queue.first != nil`) and engages
    /// it on arrival. Defaults to engaged so a newly spawned cab is in
    /// the safe state.
    var brakeEngaged: Bool = true
    /// Door light-curtain / safety-edge state. While true, the door
    /// controller is forbidden from closing -- a closing cycle that
    /// detects an obstruction reverses to .opening and re-arms the
    /// dwell. Cleared automatically once the obstruction is gone.
    var doorObstructed: Bool = false
    /// Current cab platform load in kilograms (passengers + freight,
    /// excluding the tare weight of the empty cab). Driven by the
    /// boarding model in ElevatorWorld and overridable from DCL via
    /// `SET CAB <label> /LOAD=<kg>`. Reported by the diagnostic
    /// weight-cal test and by Modbus IR 48..55.
    var loadKg: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, label, ownerPeerId, automatic, profile, position, queue
        case doors, doorProgress, doorDwellRemaining, direction
        case phaseTwoActive, independentActive, velocity, acceleration
        case brakeEngaged, doorObstructed, loadKg
    }

    init(id: UUID, label: String, ownerPeerId: String, automatic: Bool,
         profile: CabProfile, position: Double, queue: [Int],
         doors: DoorState, doorProgress: Double, doorDwellRemaining: Double,
         direction: Direction,
         phaseTwoActive: Bool = false, independentActive: Bool = false,
         velocity: Double = 0, acceleration: Double = 0,
         brakeEngaged: Bool = true, doorObstructed: Bool = false,
         loadKg: Double = 0) {
        self.id = id
        self.label = label
        self.ownerPeerId = ownerPeerId
        self.automatic = automatic
        self.profile = profile
        self.position = position
        self.queue = queue
        self.doors = doors
        self.doorProgress = doorProgress
        self.doorDwellRemaining = doorDwellRemaining
        self.direction = direction
        self.phaseTwoActive = phaseTwoActive
        self.independentActive = independentActive
        self.velocity = velocity
        self.acceleration = acceleration
        self.brakeEngaged = brakeEngaged
        self.doorObstructed = doorObstructed
        self.loadKg = loadKg
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        ownerPeerId = try c.decode(String.self, forKey: .ownerPeerId)
        automatic = try c.decode(Bool.self, forKey: .automatic)
        profile = try c.decode(CabProfile.self, forKey: .profile)
        position = try c.decode(Double.self, forKey: .position)
        queue = try c.decode([Int].self, forKey: .queue)
        doors = try c.decode(DoorState.self, forKey: .doors)
        doorProgress = try c.decode(Double.self, forKey: .doorProgress)
        doorDwellRemaining = try c.decode(Double.self, forKey: .doorDwellRemaining)
        direction = try c.decode(Direction.self, forKey: .direction)
        // Safety / dynamics fields are optional on the wire so a peer
        // running an older build whose Elevator struct didn't have
        // them can still be decoded.
        phaseTwoActive = try c.decodeIfPresent(Bool.self, forKey: .phaseTwoActive) ?? false
        independentActive = try c.decodeIfPresent(Bool.self, forKey: .independentActive) ?? false
        velocity = try c.decodeIfPresent(Double.self, forKey: .velocity) ?? 0
        acceleration = try c.decodeIfPresent(Double.self, forKey: .acceleration) ?? 0
        brakeEngaged = try c.decodeIfPresent(Bool.self, forKey: .brakeEngaged) ?? true
        doorObstructed = try c.decodeIfPresent(Bool.self, forKey: .doorObstructed) ?? false
        loadKg = try c.decodeIfPresent(Double.self, forKey: .loadKg) ?? 0
    }

    var nearestFloor: Int {
        let clamped = max(Double(Sim.firstFloor), min(Double(Sim.lastFloor), position.rounded()))
        return Int(clamped)
    }

    var isStoppedAtFloor: Bool {
        abs(position - Double(nearestFloor)) < 0.01
    }

    var displayFloor: Int { nearestFloor }

    static func newAt(floor: Int, label: String, ownerPeerId: String, automatic: Bool, profile: CabProfile = .pax) -> Elevator {
        Elevator(
            id: UUID(),
            label: label,
            ownerPeerId: ownerPeerId,
            automatic: automatic,
            profile: profile,
            position: Double(floor),
            queue: [],
            doors: .closed,
            doorProgress: 0,
            doorDwellRemaining: 0,
            direction: .idle
        )
    }

    mutating func enqueue(floor: Int) {
        let clamped = max(Sim.firstFloor, min(Sim.lastFloor, floor))
        guard !queue.contains(clamped) else { return }
        guard !(isStoppedAtFloor && nearestFloor == clamped && doors != .closed) else { return }
        queue.append(clamped)
    }

    mutating func requestDoorsOpen() {
        guard isStoppedAtFloor else { return }
        if doors == .closed || doors == .closing {
            doors = .opening
            if doors == .closing {
                doorProgress = 1.0 - doorProgress
            } else {
                doorProgress = 0
            }
        } else if doors == .open {
            doorDwellRemaining = profile.doorDwellDuration
        }
    }

    mutating func requestDoorsClose() {
        if doors == .open {
            doors = .closing
            doorProgress = 0
            doorDwellRemaining = 0
        } else if doors == .opening {
            doors = .closing
            doorProgress = 1.0 - doorProgress
        }
    }

    // MARK: -- Safety-chain predicates
    //
    // Pure functions of cab telemetry, shared by the SCADA alarm samplers
    // (ElevatorWorld.sample*Alarm) and the Modbus safety-chain discrete
    // inputs, so a chaîne-de-sécurité contact and its alarm can never
    // disagree. Because they read only fields carried on the peer wire,
    // they hold for remote (ClusterDaemon) cabs exactly as for local ones.

    /// Overspeed governor tripping condition: cab speed 15% over the
    /// profile's rated speed (ASME A17.1 §2.17 / EN 81-20 §5.6.2.2 margin).
    var isOverspeed: Bool {
        abs(velocity) > profile.travelFloorsPerSecond * 1.15
    }

    /// Holding brake dragging -- commanded set while the car is moving.
    var isBrakeDragging: Bool {
        brakeEngaged && abs(velocity) > 0.10
    }

    /// Landing/car door interlock proven: the car is at rest with doors
    /// fully closed and locked. The series safety chain only closes here.
    var doorInterlockLocked: Bool {
        doors == .closed
    }

    /// Car sitting on a terminal landing with a queued target beyond it --
    /// the condition the final (terminal) limit switch guards against.
    var atTerminalOvertravel: Bool {
        let atBottom = position <= Double(Sim.firstFloor) + 0.001
        let atTop = position >= Double(Sim.lastFloor) - 0.001
        let badBottom = atBottom && (queue.first.map { $0 < Sim.firstFloor } ?? false)
        let badTop = atTop && (queue.first.map { $0 > Sim.lastFloor } ?? false)
        return badBottom || badTop
    }
}
