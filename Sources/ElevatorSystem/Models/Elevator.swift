import Foundation

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

    static func newAt(floor: Int, label: String, ownerPeerId: String, automatic: Bool) -> Elevator {
        Elevator(
            id: UUID(),
            label: label,
            ownerPeerId: ownerPeerId,
            automatic: automatic,
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
            doorDwellRemaining = Sim.doorDwellDuration
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
