import Foundation
import Network

/// One node's Bonjour transport. Mirrors the app's `PeerNetwork`: publishes
/// an `_elevatorsys._tcp` service with a `peerId`/`label` TXT record,
/// browses for other services, and maintains one connection per remote
/// peer. All work runs on the shared serial `queue` handed in by the node,
/// so there are no locks -- every callback and timer for the whole daemon
/// is serialized onto that one queue.
///
/// Connection dedup matches the app exactly: both sides listen AND browse,
/// but only the peer with the lexicographically greater peerId dials out,
/// so each pair ends up with a single connection.
final class PeerLink {
    let peerId: String
    let label: String

    private let queue: DispatchQueue
    private let logger: Logger
    /// Supplies the node's current cabs so a freshly-connected peer can be
    /// sent a `.state` for each straight after the `.hello` handshake.
    private let cabsProvider: () -> [Elevator]

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: PeerConnection] = [:]
    private var pending: [ObjectIdentifier: PeerConnection] = [:]

    var connectionCount: Int { connections.count }

    init(peerId: String, label: String, queue: DispatchQueue, logger: Logger,
         cabsProvider: @escaping () -> [Elevator]) {
        self.peerId = peerId
        self.label = label
        self.queue = queue
        self.logger = logger
        self.cabsProvider = cabsProvider
    }

    // MARK: -- lifecycle

    func start() {
        startListener()
        startBrowser()
    }

    func stop(sendBye: Bool) {
        if sendBye { broadcast(.bye(peerId: peerId)) }
        for (_, conn) in connections { conn.cancel() }
        connections.removeAll()
        for (_, conn) in pending { conn.cancel() }
        pending.removeAll()
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
    }

    func broadcast(_ msg: PeerMessage) {
        for (_, conn) in connections { conn.send(msg) }
    }

    // MARK: -- transport parameters

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    // MARK: -- listener (server side)

    private func startListener() {
        let listener: NWListener
        do {
            listener = try NWListener(using: Self.tcpParameters())
        } catch {
            logger.log("[\(label)] failed to create listener: \(error)")
            return
        }
        let txt = NWTXTRecord([
            "peerId": peerId,
            "label": label,
        ])
        listener.service = NWListener.Service(
            name: label + "-" + String(peerId.prefix(8)),
            type: Sim.bonjourServiceType,
            txtRecord: txt
        )
        listener.newConnectionHandler = { [weak self] nwConn in
            self?.handleIncoming(nwConn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: -- browser (client side)

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Sim.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowse(results: results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleBrowse(results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .bonjour(txt) = result.metadata else { continue }
            let remoteId = txt["peerId"] ?? ""
            if remoteId.isEmpty || remoteId == peerId { continue }   // skip self
            if connections[remoteId] != nil { continue }
            // Only the higher peerId dials out, so each pair has one link.
            if remoteId > peerId { continue }
            openConnection(to: result, expectedPeerId: remoteId)
        }
    }

    private func openConnection(to result: NWBrowser.Result, expectedPeerId: String) {
        let nwConn = NWConnection(to: result.endpoint, using: Self.tcpParameters())
        let peer = PeerConnection(connection: nwConn, queue: queue)
        attachHandlers(peer)
        peer.start()
        pending[ObjectIdentifier(peer)] = peer
    }

    private func handleIncoming(_ nwConn: NWConnection) {
        let peer = PeerConnection(connection: nwConn, queue: queue)
        attachHandlers(peer)
        peer.start()
        pending[ObjectIdentifier(peer)] = peer
    }

    // MARK: -- connection handlers

    private func attachHandlers(_ peer: PeerConnection) {
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            peer.send(.hello(peerId: self.peerId, label: self.label))
            for cab in self.cabsProvider() { peer.send(.state(cab)) }
        }
        peer.onMessage = { [weak self, weak peer] msg in
            guard let self, let peer else { return }
            self.handle(message: msg, from: peer)
        }
        peer.onClosed = { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.cleanup(peer: peer)
        }
    }

    private func handle(message: PeerMessage, from peer: PeerConnection) {
        switch message.op {
        case .hello:
            guard let remoteId = message.peerId else { return }
            if connections[remoteId] != nil {
                // A link to this peer already exists (the other dedup race
                // path won) -- drop this duplicate.
                peer.cancel()
                pending.removeValue(forKey: ObjectIdentifier(peer))
                return
            }
            peer.remotePeerId = remoteId
            peer.remoteLabel = message.label ?? remoteId
            connections[remoteId] = peer
            pending.removeValue(forKey: ObjectIdentifier(peer))
            logger.log("[\(label)] peer UP  \(peer.remoteLabel ?? remoteId) [\(String(remoteId.prefix(8)))] — \(connections.count) link(s)")
        case .bye:
            cleanup(peer: peer)
        case .state:
            // The daemon doesn't maintain a world of other peers' cabs, but
            // logging the first decoded `.state` per peer confirms the full
            // wire round-trip (their encode → our WireCodec.decode of the
            // shared Elevator shape) -- the same path the app uses to render
            // our cabs.
            if !peer.didLogInboundState, let cab = message.elevator {
                peer.didLogInboundState = true
                logger.log("[\(label)] rx STATE ok — cab \(cab.label) @ floor \(cab.displayFloor) from \(peer.remoteLabel ?? "?")")
            }
        case .stats:
            if !peer.didLogInboundStats, let snap = message.snapshot {
                peer.didLogInboundStats = true
                logger.log(String(format: "[%@] rx STATS ok — %@ cpu %.0f%% mem %.0f%%",
                                  label, peer.remoteLabel ?? "?", snap.cpuBusy, snap.memUsedPercent))
            }
        case .remove:
            break
        }
    }

    private func cleanup(peer: PeerConnection) {
        pending.removeValue(forKey: ObjectIdentifier(peer))
        if let remoteId = peer.remotePeerId {
            connections.removeValue(forKey: remoteId)
            logger.log("[\(label)] peer DOWN \(peer.remoteLabel ?? remoteId) [\(String(remoteId.prefix(8)))] — \(connections.count) link(s)")
        }
        peer.cancel()
    }
}

/// A single framed JSON-over-TCP connection. Newline-delimited: inbound
/// bytes accumulate in a buffer that is drained on every `0x0A`.
final class PeerConnection: @unchecked Sendable {
    var remotePeerId: String?
    var remoteLabel: String?
    /// One-shot flags so inbound `.state` / `.stats` are logged once per peer
    /// (as a wire-round-trip confirmation) rather than at the broadcast rate.
    var didLogInboundState = false
    var didLogInboundStats = false
    var onReady: (() -> Void)?
    var onMessage: ((PeerMessage) -> Void)?
    var onClosed: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var inboundBuffer = Data()
    private var hasClosed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveLoop()
            case .failed, .cancelled:
                self.fireClosedOnce()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ msg: PeerMessage) {
        guard let data = WireCodec.encode(msg) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    private func fireClosedOnce() {
        guard !hasClosed else { return }
        hasClosed = true
        onClosed?()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inboundBuffer.append(data)
                self.drainLines()
            }
            if isComplete || error != nil {
                self.fireClosedOnce()
                return
            }
            self.receiveLoop()
        }
    }

    private func drainLines() {
        while let idx = inboundBuffer.firstIndex(of: 0x0A) {
            let line = inboundBuffer[..<idx]
            inboundBuffer.removeSubrange(...idx)
            if let msg = WireCodec.decode(Data(line)) {
                onMessage?(msg)
            }
        }
    }
}
