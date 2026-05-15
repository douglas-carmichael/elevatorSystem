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
