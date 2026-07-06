import Foundation

/// Owns one node's cluster of cabs and steps them through the same
/// door-state + trapezoidal-motion model the app runs in
/// `ElevatorWorld.advance()`. Faithfulness matters: the app advances every
/// cab it knows about -- including ours -- on its own 60 Hz tick and only
/// re-syncs from our `.state` broadcasts, so if our physics diverged from
/// the app's the cab would visibly stutter between corrections.
///
/// Deliberately omitted vs. the app: SCADA alarm sampling, building-mode
/// (fire / EPO) enforcement, hall-call allocation and destination dispatch.
/// Those are per-node local concerns in the app and are not carried on the
/// peer protocol, so a daemon cab simply runs normal automatic dispatch.
final class CabSimulator {
    private(set) var cabs: [Elevator] = []
    private let ownerPeerId: String
    private let topFloor: Int
    private var nextDecisionAt: [UUID: Date] = [:]

    init(ownerPeerId: String, cabCount: Int, floors: Int) {
        self.ownerPeerId = ownerPeerId
        self.topFloor = max(2, min(Sim.floorCount, floors))
        spawn(count: max(1, cabCount))
    }

    private func spawn(count: Int) {
        let now = Date()
        // One randomly-chosen cab per node runs the freight profile, mirroring
        // the app's AutoDriver so a demo cluster shows a mix of car types.
        let freightIndex = Int.random(in: 0..<count)
        for i in 0..<count {
            let floor = Int.random(in: Sim.firstFloor...topFloor)
            let profile: CabProfile = (i == freightIndex) ? .freight : .pax
            var cab = Elevator.newAt(floor: floor,
                                     label: String(format: "%02d", i + 1),
                                     ownerPeerId: ownerPeerId,
                                     automatic: true,
                                     profile: profile)
            // Seed an initial destination so the cab starts moving right away
            // instead of sitting idle until its first decision tick.
            var dest = Int.random(in: Sim.firstFloor...topFloor)
            if dest == floor { dest = (floor == topFloor) ? Sim.firstFloor : floor + 1 }
            cab.queue = [dest]
            cabs.append(cab)
            nextDecisionAt[cab.id] = now.addingTimeInterval(Double.random(in: Sim.autoMinIdleSeconds...Sim.autoMaxIdleSeconds))
        }
    }

    func tick(dt: Double, now: Date) {
        for index in cabs.indices {
            autoDecide(&cabs[index], now: now)
            advance(&cabs[index], dt: dt)
        }
    }

    /// Apply a remote-control request forwarded by a peer (the app) to one
    /// of this node's cabs. Mirrors the app's `ElevatorWorld.applyControl`:
    /// the change lands on the owned cab and is picked up by the next
    /// `.state` broadcast. Requests for a cab this node doesn't own are
    /// ignored. Must be called on the node's serial queue.
    func apply(_ cmd: CabCommand) {
        guard let index = cabs.firstIndex(where: { $0.id == cmd.elevatorId && $0.ownerPeerId == ownerPeerId }) else { return }
        switch cmd.kind {
        case .call:
            if let floor = cmd.floor { cabs[index].enqueue(floor: floor) }
        case .open:
            cabs[index].requestDoorsOpen()
        case .close:
            cabs[index].requestDoorsClose()
        case .stop:
            cabs[index].queue.removeAll()
        }
    }

    // MARK: -- automatic dispatch

    /// Mirrors the app's `AutoDriver.autoTick`: an idle cab with no queued
    /// call picks a fresh random destination once its decision timer elapses.
    private func autoDecide(_ cab: inout Elevator, now: Date) {
        guard cab.automatic, cab.queue.isEmpty, cab.doors == .closed else { return }
        guard !cab.phaseTwoActive, !cab.independentActive else { return }
        let due = nextDecisionAt[cab.id] ?? now
        guard now >= due else { return }
        var next = Int.random(in: Sim.firstFloor...topFloor)
        while next == cab.displayFloor { next = Int.random(in: Sim.firstFloor...topFloor) }
        cab.enqueue(floor: next)
        nextDecisionAt[cab.id] = now.addingTimeInterval(Double.random(in: Sim.autoMinIdleSeconds...Sim.autoMaxIdleSeconds))
    }

    // MARK: -- physics (ported from ElevatorWorld.advance)

    private func advance(_ elev: inout Elevator, dt: Double) {
        let prof = elev.profile
        switch elev.doors {
        case .opening:
            elev.doorProgress += dt / prof.doorOpenDuration
            if elev.doorProgress >= 1.0 {
                elev.doorProgress = 1.0
                elev.doors = .open
                elev.doorDwellRemaining = prof.doorDwellDuration
                applyBoarding(&elev)
            }
            elev.direction = .idle
            elev.brakeEngaged = true
            return
        case .open:
            if elev.phaseTwoActive || elev.independentActive {
                elev.direction = .idle
                elev.brakeEngaged = true
                return
            }
            elev.doorDwellRemaining -= dt
            // Overload interlock (ASME A17.1 §3.6): a cab above 110% rated
            // load can't depart -- the dwell latches until weight drops.
            let overloaded = elev.loadKg > prof.ratedLoadKg * 1.10
            if elev.doorDwellRemaining <= 0 && !elev.doorObstructed && !overloaded {
                elev.doors = .closing
                elev.doorProgress = 0
            }
            elev.direction = .idle
            elev.brakeEngaged = true
            return
        case .closing:
            // Door reversal on obstruction (EN 81-20 §5.3.6.2.2).
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

        // Safety chain: motion is only commanded with doors confirmed closed.
        guard elev.doors == .closed else {
            elev.velocity = 0
            elev.direction = .idle
            elev.brakeEngaged = true
            return
        }

        guard let target = elev.queue.first else {
            // No call queued -- decelerate to rest, then set the brake.
            decelerateToStop(&elev, dt: dt)
            elev.direction = .idle
            if abs(elev.velocity) < 0.01 { elev.brakeEngaged = true }
            return
        }

        // A motion command is imminent -- release the holding brake.
        elev.brakeEngaged = false

        // Trapezoidal velocity profile: aim for max cruise speed while far
        // from the target, then for the speed that coasts to zero exactly at
        // the floor (v² = 2·a·s). Velocity change clamped to ±maxAccel·dt.
        let dy = Double(target) - elev.position
        let maxSpeed = prof.travelFloorsPerSecond
        let maxAccel = prof.travelAccel
        let dirSign: Double = dy >= 0 ? 1 : -1
        let absDistance = abs(dy)
        let stoppingDistance = (elev.velocity * elev.velocity) / (2 * maxAccel)
        let targetSpeedMag = absDistance > stoppingDistance
            ? maxSpeed
            : sqrt(2 * maxAccel * absDistance)
        let targetVelocity = dirSign * targetSpeedMag
        let dv = targetVelocity - elev.velocity
        let maxDv = maxAccel * dt
        elev.velocity += max(-maxDv, min(maxDv, dv))

        elev.position += elev.velocity * dt

        // Terminal limit switches clamp position at the shaft ends.
        let top = Double(Sim.lastFloor)
        let bottom = Double(Sim.firstFloor)
        if elev.position <= bottom && elev.velocity < 0 {
            elev.position = bottom
            elev.velocity = 0
            elev.brakeEngaged = true
        } else if elev.position >= top && elev.velocity > 0 {
            elev.position = top
            elev.velocity = 0
            elev.brakeEngaged = true
        }

        // Arrival: close enough and slow enough -- snap to the floor and open.
        if abs(elev.position - Double(target)) < 0.05,
           abs(elev.velocity) < (maxAccel * dt * 1.5) {
            elev.position = Double(target)
            elev.velocity = 0
            elev.queue.removeFirst()
            elev.doors = .opening
            elev.doorProgress = 0
            elev.direction = .idle
            elev.brakeEngaged = true
            return
        }

        // Publish travel direction from the velocity sign.
        if elev.velocity > 0.01 {
            elev.direction = .up
        } else if elev.velocity < -0.01 {
            elev.direction = .down
        } else {
            elev.direction = .idle
        }
    }

    /// Cheap boarding / alighting model run once per door-open cycle so the
    /// load cells (and the app's WEIGHT_CAL diagnostic / Modbus IR 48..55)
    /// show realistic fluctuation. Lobby is floor 1.
    private func applyBoarding(_ elev: inout Elevator) {
        let floor = Int(elev.position.rounded())
        let isLobby = floor == Sim.firstFloor
        switch elev.profile {
        case .pax:
            let boarders = isLobby ? Int.random(in: 1...4) : Int.random(in: 0...2)
            let alighters = isLobby ? 0 : Int.random(in: 0...3)
            elev.loadKg = max(0, elev.loadKg + Double(boarders - alighters) * 75.0)
        case .freight:
            elev.loadKg = max(0, elev.loadKg + Double.random(in: -240...240))
        }
    }

    private func decelerateToStop(_ elev: inout Elevator, dt: Double) {
        let maxDv = elev.profile.travelAccel * dt
        if abs(elev.velocity) <= maxDv {
            elev.velocity = 0
        } else {
            elev.velocity -= maxDv * (elev.velocity > 0 ? 1 : -1)
        }
        elev.position += elev.velocity * dt
    }
}
