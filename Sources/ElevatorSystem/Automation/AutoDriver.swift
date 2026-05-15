import Foundation

@MainActor
final class AutoDriver: ObservableObject {
    private weak var world: ElevatorWorld?
    private weak var network: PeerNetwork?
    private var bootstrapTimer: Timer?
    private var tickTimer: Timer?
    private var autoElevatorIds: Set<UUID> = []
    private var nextDecisionAt: [UUID: Date] = [:]

    func attach(world: ElevatorWorld, network: PeerNetwork) {
        self.world = world
        self.network = network
    }

    func start() {
        scheduleBootstrap()
        scheduleTick()
    }

    /// Returns true if this cab is currently being driven by the auto-driver.
    func isAutomatic(cabId: UUID) -> Bool {
        autoElevatorIds.contains(cabId)
    }

    /// Disable the auto-driver for a cab (manual control). The cab keeps any
    /// queued floors but no new destinations will be issued automatically.
    /// Returns true if the cab was being auto-driven and is now manual.
    @discardableResult
    func takeManualControl(cabId: UUID) -> Bool {
        guard autoElevatorIds.contains(cabId) else { return false }
        autoElevatorIds.remove(cabId)
        nextDecisionAt.removeValue(forKey: cabId)
        _ = world?.mutateLocal(cabId) { e in
            e.automatic = false
        }
        return true
    }

    /// Re-enable the auto-driver for a cab. Returns true if the cab now
    /// participates in automatic dispatch (false if the cab is unknown or
    /// not locally owned).
    @discardableResult
    func returnToAutomatic(cabId: UUID) -> Bool {
        guard let world else { return false }
        guard let cab = world.elevators.first(where: { $0.id == cabId }) else { return false }
        guard cab.ownerPeerId == world.localPeerId else { return false }
        autoElevatorIds.insert(cabId)
        nextDecisionAt[cabId] = Date().addingTimeInterval(Double.random(in: Sim.autoMinIdleSeconds...Sim.autoMaxIdleSeconds))
        _ = world.mutateLocal(cabId) { e in
            e.automatic = true
        }
        return true
    }

    func stop() {
        bootstrapTimer?.invalidate()
        bootstrapTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func scheduleBootstrap() {
        bootstrapTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Sim.autoDiscoveryGracePeriod, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.maybeSpawn() }
        }
        bootstrapTimer = t
    }

    private func scheduleTick() {
        tickTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoTick() }
        }
        tickTimer = t
    }

    private func maybeSpawn() {
        guard let world else { return }
        let alreadySpawned = !autoElevatorIds.isEmpty
        guard !alreadySpawned else { return }
        let userOwnedCount = world.elevators.filter { $0.ownerPeerId == world.localPeerId && !$0.automatic }.count
        let labelOffset = userOwnedCount + 1
        let freightIndex = Int.random(in: 0..<Sim.autoSpawnCount)
        for i in 0..<Sim.autoSpawnCount {
            let floor = Int.random(in: Sim.firstFloor...Sim.lastFloor)
            let label = String(format: "%02d", labelOffset + i)
            let profile: CabProfile = i == freightIndex ? .freight : .pax
            var elev = Elevator.newAt(floor: floor,
                                       label: label,
                                       ownerPeerId: world.localPeerId,
                                       automatic: true,
                                       profile: profile)
            elev.queue = [Int.random(in: Sim.firstFloor...Sim.lastFloor)]
            world.elevators.append(elev)
            autoElevatorIds.insert(elev.id)
            nextDecisionAt[elev.id] = Date().addingTimeInterval(Double.random(in: Sim.autoMinIdleSeconds...Sim.autoMaxIdleSeconds))
        }
    }

    private func autoTick() {
        guard let world else { return }
        let now = Date()
        for elev in world.elevators where autoElevatorIds.contains(elev.id) {
            guard elev.queue.isEmpty, elev.doors == .closed else { continue }
            let due = nextDecisionAt[elev.id] ?? now
            if now >= due {
                var nextFloor: Int
                repeat {
                    nextFloor = Int.random(in: Sim.firstFloor...Sim.lastFloor)
                } while nextFloor == elev.displayFloor
                _ = world.mutateLocal(elev.id) { e in
                    e.enqueue(floor: nextFloor)
                }
                nextDecisionAt[elev.id] = now.addingTimeInterval(Double.random(in: Sim.autoMinIdleSeconds...Sim.autoMaxIdleSeconds))
            }
        }
    }
}
