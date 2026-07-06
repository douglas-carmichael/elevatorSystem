#if canImport(Network)
import Foundation
import Network

// Apple-platform peer transport, on Network.framework.
//
// This is the daemon's original `PeerLink`, unchanged in behaviour: publish an
// `_elevatorsys._tcp` Bonjour service with a peerId/label TXT record, browse for
// others, and dial only when we hold the higher peerId so each pair forms one
// link. The only structural change is that the transport-agnostic handshake /
// dedup now lives in the shared `PeerSession`; this file is just the
// Network.framework plumbing that feeds it `NWConnection`-backed `RawConn`s.
//
// Compiled only where Network.framework exists; Linux/Windows use
// `SocketPeerLink` + `MDNSEngine` instead.
final class ApplePeerLink: PeerLink {
    private let session: PeerSession
    private let queue: DispatchQueue
    private let logger: Logger

    private var listener: NWListener?
    private var browser: NWBrowser?

    var connectionCount: Int { session.connectionCount }
    private var peerId: String { session.peerId }
    private var label: String { session.label }

    init(peerId: String, label: String, queue: DispatchQueue, logger: Logger,
         cabsProvider: @escaping () -> [Elevator]) {
        self.session = PeerSession(peerId: peerId, label: label, logger: logger, cabsProvider: cabsProvider)
        self.queue = queue
        self.logger = logger
    }

    // MARK: -- lifecycle

    func start() {
        startListener()
        startBrowser()
    }

    func stop(sendBye: Bool) {
        session.stop(sendBye: sendBye)
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
    }

    func broadcast(_ msg: PeerMessage) {
        session.broadcast(msg)
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
            guard let self else { return }
            self.session.adopt(AppleConn(connection: nwConn, queue: self.queue))
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
            if session.hasPeer(remoteId) { continue }
            // Only the higher peerId dials out, so each pair has one link.
            if remoteId > peerId { continue }
            let nwConn = NWConnection(to: result.endpoint, using: Self.tcpParameters())
            session.adopt(AppleConn(connection: nwConn, queue: queue))
        }
    }
}

/// A single framed JSON-over-TCP connection carried by `NWConnection`.
/// Newline-delimited: inbound bytes accumulate and drain on every `0x0A`.
/// Its callbacks fire on the `NWConnection`'s queue, which is the node's serial
/// queue — satisfying `PeerSession`'s single-queue contract.
final class AppleConn: RawConn {
    var remotePeerId: String?
    var remoteLabel: String?
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
#endif
