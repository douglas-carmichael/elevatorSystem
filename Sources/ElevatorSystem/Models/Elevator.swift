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

    enum CodingKeys: String, CodingKey {
        case id, label, ownerPeerId, automatic, profile, position, queue
        case doors, doorProgress, doorDwellRemaining, direction
        case phaseTwoActive, independentActive, velocity
    }

    init(id: UUID, label: String, ownerPeerId: String, automatic: Bool,
         profile: CabProfile, position: Double, queue: [Int],
         doors: DoorState, doorProgress: Double, doorDwellRemaining: Double,
         direction: Direction,
         phaseTwoActive: Bool = false, independentActive: Bool = false,
         velocity: Double = 0) {
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
}
