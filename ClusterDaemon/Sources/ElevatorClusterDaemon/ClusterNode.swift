import Foundation

/// Selects the peer transport for a node. A supplied discovery engine means the
/// hand-rolled mDNS + BSD-socket backend (always the case off-Apple; on Apple
/// only when forced for verification); otherwise Network.framework/Bonjour.
func makePeerLink(peerId: String, label: String, queue: DispatchQueue, logger: Logger,
                  discovery: MDNSEngine?, cabsProvider: @escaping () -> [Elevator],
                  commandSink: @escaping (CabCommand) -> Void) -> PeerLink {
    if let discovery {
        return SocketPeerLink(peerId: peerId, label: label, queue: queue, logger: logger,
                              discovery: discovery, cabsProvider: cabsProvider, commandSink: commandSink)
    }
    #if canImport(Network)
    return ApplePeerLink(peerId: peerId, label: label, queue: queue, logger: logger,
                         cabsProvider: cabsProvider, commandSink: commandSink)
    #else
    // Unreachable: off-Apple, `main` always supplies a discovery engine.
    fatalError("no peer transport available without a discovery engine")
    #endif
}

/// A single simulated dispatcher node: a `CabSimulator` (its own cluster of
/// cabs) plus a `PeerLink` (its Bonjour identity and connections). To the
/// app this looks exactly like another Mac running ElevatorSystem.
///
/// Three timers, all on the shared serial queue:
///   * sim       (60 Hz)          -- step the cab physics.
///   * broadcast (`broadcastHz`)  -- push each cab's `.state` to every peer.
///                                   At 60 Hz (the default) the app snaps our
///                                   cabs authoritatively every one of its own
///                                   frames; lower rates lean on the app's
///                                   60 Hz extrapolation of our cabs between
///                                   snapshots, trading traffic for tightness.
///   * stats     (0.2 Hz)         -- push a host `.stats` snapshot for MONITOR CLUSTER.
final class ClusterNode {
    let label: String
    let peerId: String
    let broadcastHz: Int

    private let queue: DispatchQueue
    private let logger: Logger
    private let sim: CabSimulator
    private let link: PeerLink
    private let sampler = HostStats()

    private var simTimer: DispatchSourceTimer?
    private var broadcastTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var lastTickAt = Date()

    /// `.state` broadcast rounds since the last `drainBroadcastRounds()` --
    /// lets the heartbeat report the actual outbound rate. Only touched on
    /// the shared serial queue, so no synchronisation is needed.
    private var broadcastRounds = 0

    private let broadcastInterval: TimeInterval
    private static let statsInterval: TimeInterval = 5.0

    init(label: String, cabCount: Int, floors: Int, broadcastHz: Int,
         queue: DispatchQueue, logger: Logger, discovery: MDNSEngine?) {
        let peerId = UUID().uuidString
        self.label = label
        self.peerId = peerId
        self.broadcastHz = broadcastHz
        self.broadcastInterval = 1.0 / Double(broadcastHz)
        self.queue = queue
        self.logger = logger
        let sim = CabSimulator(ownerPeerId: peerId, cabCount: cabCount, floors: floors)
        self.sim = sim
        self.link = makePeerLink(peerId: peerId, label: label, queue: queue, logger: logger,
                                 discovery: discovery, cabsProvider: { sim.cabs },
                                 commandSink: { sim.apply($0) })
    }

    var connectionCount: Int { link.connectionCount }
    var cabCount: Int { sim.cabs.count }

    /// Returns the number of `.state` broadcast rounds since the last call and
    /// resets the counter. Must be called on `queue`.
    func drainBroadcastRounds() -> Int {
        defer { broadcastRounds = 0 }
        return broadcastRounds
    }

    /// Must be called on `queue`.
    func start() {
        let cabList = sim.cabs.map { "\($0.label)(\($0.profile == .freight ? "FRT" : "PAX"))" }.joined(separator: " ")
        logger.log("[\(label)] node up  peerId [\(String(peerId.prefix(8)))]  cabs: \(cabList)")
        link.start()

        lastTickAt = Date()
        simTimer = makeTimer(interval: Sim.tickInterval) { [weak self] in self?.tick() }
        broadcastTimer = makeTimer(interval: broadcastInterval) { [weak self] in self?.broadcastState() }
        statsTimer = makeTimer(interval: Self.statsInterval) { [weak self] in self?.broadcastStats() }
    }

    /// Must be called on `queue`.
    func stop(sendBye: Bool) {
        simTimer?.cancel(); simTimer = nil
        broadcastTimer?.cancel(); broadcastTimer = nil
        statsTimer?.cancel(); statsTimer = nil
        link.stop(sendBye: sendBye)
    }

    // MARK: -- timer bodies

    private func tick() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastTickAt))
        lastTickAt = now
        sim.tick(dt: dt, now: now)
    }

    private func broadcastState() {
        guard link.connectionCount > 0 else { return }
        for cab in sim.cabs { link.broadcast(.state(cab)) }
        broadcastRounds += 1
    }

    private func broadcastStats() {
        guard link.connectionCount > 0 else { return }
        link.broadcast(.stats(peerId: peerId, snapshot: sampler.snapshot()))
    }

    private func makeTimer(interval: TimeInterval, handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Tight leeway (1 ms, or 5% of the period for slow timers) so the sim
        // and broadcast timers hold close to their nominal rate instead of
        // being coalesced ~10% slow by GCD's default leeway. Cheap here: the
        // whole daemon is one lightly-loaded serial queue.
        let leeway = DispatchTimeInterval.nanoseconds(max(1_000_000, Int(interval * 1e9 * 0.05)))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
}

/// Minimal timestamped stdout logger. `print` lines are serialized under a
/// lock; stdout is set line-buffered in `main` so logs appear promptly even
/// when piped to a file. `--quiet` suppresses everything except the banner
/// and heartbeat (which use `raw`).
final class Logger {
    private let quiet: Bool
    private let lock = NSLock()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(quiet: Bool) { self.quiet = quiet }

    /// `HH:mm:ss` stamp for the current instant. Exposed so callers that use
    /// `raw` (which never prefixes a time) can still show one -- e.g. the
    /// heartbeat, which must print even under `--quiet`.
    static func clock() -> String { formatter.string(from: Date()) }

    func log(_ message: String) {
        guard !quiet else { return }
        emit("\(Logger.clock())  \(message)")
    }

    /// Always printed, ignoring `--quiet` (banner, heartbeat, shutdown).
    func raw(_ message: String) {
        emit(message)
    }

    private func emit(_ line: String) {
        lock.lock()
        print(line)
        lock.unlock()
    }
}
