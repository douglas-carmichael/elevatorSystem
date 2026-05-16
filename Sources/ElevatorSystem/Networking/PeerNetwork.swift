import Foundation
import Network
import Combine

// SIMULATION TRANSPORT.
//
// This module uses Bonjour / mDNS (service type `_elevatorsys._tcp`)
// to discover other instances of the simulator running on the same
// LAN. In a real elevator install, group dispatchers do NOT find each
// other by mDNS -- they talk over a hard-wired fieldbus (CANopen-Lift,
// KNX, BACnet, LON, or a vendor-specific RS-485 trunk) with statically
// configured node addresses, redundancy, and a deterministic scan
// cycle. Bonjour is used here only because the simulator runs on
// regular macOS hardware where a real fieldbus isn't available; the
// peer-protocol payloads (`Networking/Protocol.swift`) are kept small
// and idempotent so the same code could in principle run over a
// fieldbus driver substituted at this layer.

struct DiscoveredPeer: Identifiable, Hashable {
    let id: String          // remote peerId
    let displayName: String
    let address: String
}

enum PeerNetworkState: String {
    case idle
    case discovering
    case ready
}

@MainActor
final class PeerNetwork: ObservableObject {
    @Published var peers: [DiscoveredPeer] = []
    @Published var state: PeerNetworkState = .idle
    /// Most-recent host-stats snapshot received from each remote peer,
    /// keyed by remote peer id. MONITOR CLUSTER reads this so the
    /// per-node row shows real CPU/mem/IO numbers for every member, not
    /// just the local node.
    @Published var peerStats: [String: HostStats.HostSnapshot] = [:]

    private weak var world: ElevatorWorld?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "net.dcarmichael.elevator.net")
    private var statsTimer: Timer?
    private static let statsBroadcastInterval: TimeInterval = 5.0

    private var connections: [String: PeerConnection] = [:]
    private var pendingConnections: [ObjectIdentifier: PeerConnection] = [:]

    // Plain constants captured at init so non-main-actor callbacks can read them.
    nonisolated let localPeerId: String
    nonisolated let localPeerLabel: String

    init(peerId: String = UUID().uuidString,
         label: String = Host.current().localizedName ?? "LOCAL") {
        self.localPeerId = peerId
        self.localPeerLabel = label
    }

    func attach(world: ElevatorWorld) {
        self.world = world
        world.onLocalChange = { [weak self] elev in
            guard let self else { return }
            Task { @MainActor in
                self.broadcast(.state(elev))
            }
        }
    }

    func start() {
        guard listener == nil else { return }
        state = .discovering
        startListener()
        startBrowser()
        startStatsBroadcast()
    }

    func stop() {
        broadcast(.bye(peerId: localPeerId))
        for (_, conn) in connections { conn.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        statsTimer?.invalidate()
        statsTimer = nil
        peerStats.removeAll()
        state = .idle
    }

    private func startStatsBroadcast() {
        statsTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Self.statsBroadcastInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.broadcastLocalSnapshot() }
        }
        statsTimer = t
    }

    private func broadcastLocalSnapshot() {
        guard !connections.isEmpty else { return }
        let snap = HostStats.shared.snapshot()
        broadcast(.stats(peerId: localPeerId, snapshot: snap))
    }

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func startListener() {
        let parameters = Self.tcpParameters()
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            NSLog("Failed to create NWListener: \(error)")
            return
        }
        let txt = NWTXTRecord([
            "peerId": localPeerId,
            "label": localPeerLabel,
        ])
        listener.service = NWListener.Service(
            name: localPeerLabel + "-" + String(localPeerId.prefix(8)),
            type: Sim.bonjourServiceType,
            txtRecord: txt
        )
        listener.newConnectionHandler = { [weak self] nwConn in
            guard let self else { return }
            Task { @MainActor in
                self.handleIncoming(nwConn)
            }
        }
        listener.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            Task { @MainActor in
                if case .ready = s { self.state = .ready }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Sim.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleBrowse(results: results)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleBrowse(results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .bonjour(txt) = result.metadata else { continue }
            let remoteId = txt["peerId"] ?? ""
            if remoteId.isEmpty || remoteId == localPeerId { continue }
            if connections[remoteId] != nil { continue }
            if remoteId > localPeerId {
                // Only the higher peerId initiates, so each pair has one connection.
                continue
            }
            openConnection(to: result, expectedPeerId: remoteId)
        }
    }

    private func openConnection(to result: NWBrowser.Result, expectedPeerId: String) {
        let nwConn = NWConnection(to: result.endpoint, using: Self.tcpParameters())
        let peer = PeerConnection(connection: nwConn,
                                   isClientSide: true,
                                   expectedPeerId: expectedPeerId,
                                   queue: queue)
        attachHandlers(peer)
        peer.start()
        pendingConnections[ObjectIdentifier(peer)] = peer
    }

    private func handleIncoming(_ nwConn: NWConnection) {
        let peer = PeerConnection(connection: nwConn,
                                   isClientSide: false,
                                   expectedPeerId: nil,
                                   queue: queue)
        attachHandlers(peer)
        peer.start()
        pendingConnections[ObjectIdentifier(peer)] = peer
    }

    private func attachHandlers(_ peer: PeerConnection) {
        let myId = self.localPeerId
        let myLabel = self.localPeerLabel
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            peer.send(.hello(peerId: myId, label: myLabel))
            Task { @MainActor in
                guard let world = self.world else { return }
                for elev in world.locallyOwned() {
                    peer.send(.state(elev))
                }
            }
        }
        peer.onMessage = { [weak self, weak peer] msg in
            guard let self, let peer else { return }
            Task { @MainActor in
                self.handle(message: msg, from: peer)
            }
        }
        peer.onClosed = { [weak self, weak peer] in
            guard let self, let peer else { return }
            Task { @MainActor in
                self.cleanup(peer: peer)
            }
        }
    }

    private func handle(message: PeerMessage, from peer: PeerConnection) {
        switch message.op {
        case .hello:
            guard let remoteId = message.peerId else { return }
            if connections[remoteId] != nil {
                peer.cancel()
                pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
                return
            }
            peer.remotePeerId = remoteId
            peer.remoteLabel = message.label ?? remoteId
            connections[remoteId] = peer
            pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
            peers.append(DiscoveredPeer(id: remoteId,
                                        displayName: peer.remoteLabel ?? remoteId,
                                        address: peer.remoteEndpoint))
        case .state:
            guard let elev = message.elevator else { return }
            world?.upsert(elev)
        case .remove:
            guard let id = message.elevatorId, let world else { return }
            if let idx = world.elevators.firstIndex(where: { $0.id == id }) {
                world.elevators.remove(at: idx)
            }
        case .stats:
            guard let remoteId = peer.remotePeerId, let snap = message.snapshot else { return }
            peerStats[remoteId] = snap
        case .bye:
            cleanup(peer: peer)
        }
    }

    private func cleanup(peer: PeerConnection) {
        pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
        if let remoteId = peer.remotePeerId {
            connections.removeValue(forKey: remoteId)
            peers.removeAll { $0.id == remoteId }
            peerStats.removeValue(forKey: remoteId)
            world?.removeAll(ownedBy: remoteId)
        }
        peer.cancel()
    }

    private func broadcast(_ msg: PeerMessage) {
        for (_, peer) in connections {
            peer.send(msg)
        }
    }
}

final class PeerConnection: @unchecked Sendable {
    let isClientSide: Bool
    let expectedPeerId: String?
    var remotePeerId: String?
    var remoteLabel: String?
    var onReady: (() -> Void)?
    var onMessage: ((PeerMessage) -> Void)?
    var onClosed: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var inboundBuffer = Data()
    private var hasClosed = false

    init(connection: NWConnection, isClientSide: Bool, expectedPeerId: String?, queue: DispatchQueue) {
        self.connection = connection
        self.isClientSide = isClientSide
        self.expectedPeerId = expectedPeerId
        self.queue = queue
    }

    var remoteEndpoint: String {
        switch connection.endpoint {
        case let .hostPort(host, port): return "\(host):\(port.rawValue)"
        case let .service(name, _, _, _): return name
        default: return "?"
        }
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
