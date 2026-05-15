import Foundation
import Combine

@MainActor
final class ElevatorWorld: ObservableObject {
    @Published var elevators: [Elevator] = []
    @Published var localPeerId: String
    @Published var localPeerLabel: String

    private var timer: Timer?
    private var lastTickAt: Date = .init()
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
        for index in elevators.indices {
            advance(&elevators[index], dt: dt)
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
            elev.direction = .idle
            return
        }

        let dy = Double(target) - elev.position
        if abs(dy) < 0.005 {
            elev.position = Double(target)
            elev.queue.removeFirst()
            elev.doors = .opening
            elev.doorProgress = 0
            elev.direction = .idle
            return
        }

        elev.direction = dy > 0 ? .up : .down
        let step = prof.travelFloorsPerSecond * dt * (dy > 0 ? 1 : -1)
        if abs(step) >= abs(dy) {
            elev.position = Double(target)
        } else {
            elev.position += step
        }
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
