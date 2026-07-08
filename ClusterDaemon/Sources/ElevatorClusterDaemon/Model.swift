import Foundation

// WIRE-COMPATIBLE MIRROR of the host app's simulation model.
//
// The app decodes the `Elevator` values this daemon broadcasts, so the
// Codable shape here (property names via CodingKeys, and the optional-on-
// wire handling in `init(from:)`) must match
// Sources/ElevatorSystem/Models/Elevator.swift exactly. The physics
// constants must match Sources/ElevatorSystem/Models/Constants.swift so a
// daemon-owned cab animates identically whether the app is extrapolating it
// with its own 60 Hz tick or snapping it to one of our `.state` broadcasts.

/// Simulation constants. Keep in lockstep with the app's `enum Sim`.
enum Sim {
    static let floorCount: Int = 10
    static let firstFloor: Int = 1
    static let lastFloor: Int = floorCount

    // Passenger cab profile.
    static let paxSpeed: Double = 0.9
    static let paxAccel: Double = 1.0
    static let paxDoorOpen: Double = 0.7
    static let paxDoorClose: Double = 0.7
    static let paxDoorDwell: Double = 2.8

    // Freight cab profile.
    static let freightSpeed: Double = 0.5
    static let freightAccel: Double = 0.6
    static let freightDoorOpen: Double = 1.4
    static let freightDoorClose: Double = 1.6
    static let freightDoorDwell: Double = 5.0

    static let autoMinIdleSeconds: Double = 1.5
    static let autoMaxIdleSeconds: Double = 6.0

    static let tickHz: Double = 60.0
    static var tickInterval: Double { 1.0 / tickHz }

    static let bonjourServiceType: String = "_elevatorsys._tcp"
}

enum CabProfile: String, Codable, CaseIterable {
    case pax
    case freight

    var travelFloorsPerSecond: Double {
        switch self {
        case .pax:     return Sim.paxSpeed
        case .freight: return Sim.freightSpeed
        }
    }

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

    /// Rated load capacity in kg -- the overload interlock in `advance()`
    /// forbids departure above 110% of this.
    var ratedLoadKg: Double {
        switch self {
        case .pax:     return 1000
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
    /// Absolute cab position in floor-units (1.0 = floor 1, 5.5 = midway
    /// between floors 5 and 6).
    var position: Double
    var queue: [Int]
    var doors: DoorState
    var doorProgress: Double
    var doorDwellRemaining: Double
    var direction: Direction
    var phaseTwoActive: Bool = false
    var independentActive: Bool = false
    /// Current cab velocity in floors / second; positive is up.
    var velocity: Double = 0
    /// Current cab acceleration in floors / second² (per-tick velocity delta).
    var acceleration: Double = 0
    /// Holding-brake state; defaults engaged so a fresh cab is safe.
    var brakeEngaged: Bool = true
    /// Door light-curtain / safety-edge obstruction flag.
    var doorObstructed: Bool = false
    /// Current platform load in kg (passengers + freight, tare excluded).
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
        // Safety / dynamics fields are optional on the wire so a peer on an
        // older build (whose struct predates them) still decodes.
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

    static func newAt(floor: Int, label: String, ownerPeerId: String,
                      automatic: Bool, profile: CabProfile = .pax) -> Elevator {
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

    // Door request mirrors of the app's Elevator, used when a peer forwards
    // an OPEN / CLOSE command to a daemon-owned cab (see CabSimulator.apply).
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
