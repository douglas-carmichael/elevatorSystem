import Foundation

// Non-Apple peer transport: raw BSD-socket TCP + the shared `MDNSEngine`.
//
// One `SocketPeerLink` per node owns its own TCP listener (bind :0 → the kernel
// assigns a port we read back with getsockname and advertise), registers that
// service with the process-wide `MDNSEngine`, and dials peers the engine
// resolves — applying the same "higher peerId dials" rule the Apple path uses.
// Everything that isn't socket/mDNS plumbing lives in the shared `PeerSession`.

final class SocketPeerLink: PeerLink {
    private let session: PeerSession
    private let queue: DispatchQueue
    private let logger: Logger
    private let discovery: MDNSEngine

    private let instanceName: String
    private let hostName: String

    private var listenFD: SocketFD = invalidSocketFD
    private var acceptThread: Thread?
    private var running = false
    /// peerIds with a dial in flight — closes the window where the blocking
    /// connect() hasn't produced a `pending` entry yet, so the periodic
    /// re-offer doesn't spawn a second dial. Queue-only.
    private var dialing: Set<String> = []

    var connectionCount: Int { session.connectionCount }
    private var peerId: String { session.peerId }
    private var label: String { session.label }

    init(peerId: String, label: String, queue: DispatchQueue, logger: Logger,
         discovery: MDNSEngine, cabsProvider: @escaping () -> [Elevator]) {
        self.session = PeerSession(peerId: peerId, label: label, logger: logger, cabsProvider: cabsProvider)
        self.queue = queue
        self.logger = logger
        self.discovery = discovery
        let short = String(peerId.prefix(8))
        self.instanceName = "\(label)-\(short)." + MDNSEngine.serviceType
        // A synthetic host name we alone are authoritative for — never the
        // machine's <hostname>.local, which the system responder owns.
        self.hostName = "clusterd-\(short).local"
    }

    // MARK: -- lifecycle (on `queue`)

    func start() {
        let fd = Net.makeTCP()
        guard isValidSocket(fd) else {
            logger.log("[\(label)] failed to create listener socket")
            return
        }
        Net.setReuse(fd)
        guard Net.bindAny(fd, port: 0), let port = Net.boundPort(fd), Net.listen(fd) else {
            logger.log("[\(label)] failed to bind/listen")
            Net.closeFD(fd)
            return
        }
        listenFD = fd
        running = true

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "clusterd.accept.\(String(peerId.prefix(8)))"
        t.stackSize = 256 * 1024
        acceptThread = t
        t.start()

        discovery.register(MDNSService(instanceName: instanceName, hostName: hostName,
                                       port: port, peerId: peerId, label: label))
        discovery.subscribe { [weak self] found in
            guard let self else { return }
            self.queue.async { self.onDiscovered(found) }
        }
        logger.log("[\(label)] tcp listening on :\(port)  host \(hostName)")
    }

    func stop(sendBye: Bool) {
        running = false
        discovery.unregister(instanceName: instanceName)
        session.stop(sendBye: sendBye)
        if isValidSocket(listenFD) {
            Net.shutdownBoth(listenFD)   // unblock the parked accept()
            Net.closeFD(listenFD)
            listenFD = invalidSocketFD
        }
    }

    func broadcast(_ msg: PeerMessage) {
        session.broadcast(msg)
    }

    // MARK: -- accept (server side)

    private func acceptLoop() {
        while running {
            guard let (client, _) = Net.accept(listenFD) else { break }
            queue.async { [weak self] in
                guard let self, self.running else { Net.closeFD(client); return }
                self.session.adopt(SocketConn(fd: client, queue: self.queue))
            }
        }
    }

    // MARK: -- dial (client side), on `queue`

    private func onDiscovered(_ found: DiscoveredService) {
        // `< peerId` folds in both filters: self (==) is skipped, and only the
        // higher peerId dials so each pair forms exactly one link.
        guard running, found.peerId < peerId else { return }
        guard !session.hasPeer(found.peerId), !dialing.contains(found.peerId) else { return }
        dialing.insert(found.peerId)
        let ip = found.ip, port = found.port, pid = found.peerId
        let t = Thread { [weak self] in
            let fd = Net.makeTCP()
            let ok = isValidSocket(fd) && Net.connect(fd, ip: ip, port: port)
            guard let self else { Net.closeFD(fd); return }
            self.queue.async {
                self.dialing.remove(pid)
                guard ok, self.running, !self.session.hasPeer(pid) else { Net.closeFD(fd); return }
                self.session.adopt(SocketConn(fd: fd, queue: self.queue))
            }
        }
        t.name = "clusterd.dial"
        t.stackSize = 256 * 1024
        t.start()
    }
}

/// A framed JSON-over-TCP connection on a raw socket.
///
/// A dedicated **writer thread** drains a bounded, drop-oldest outbound queue so
/// one slow peer can't block the shared serial queue (and thus every node's
/// physics) on a full send buffer — `.state` is last-wins and re-sent at 60 Hz,
/// so dropping a stale frame is harmless. A **reader thread** does blocking
/// recv, frames on `0x0A`, and marshals every decoded message onto the serial
/// queue, honouring `PeerSession`'s single-queue contract.
final class SocketConn: RawConn {
    var remotePeerId: String?
    var remoteLabel: String?
    var didLogInboundState = false
    var didLogInboundStats = false
    var onReady: (() -> Void)?
    var onMessage: ((PeerMessage) -> Void)?
    var onClosed: (() -> Void)?

    private let fd: SocketFD
    private let queue: DispatchQueue

    private let outLock = NSCondition()
    private var outQueue: [[UInt8]] = []
    private var stopped = false                 // guarded by outLock
    private static let maxQueued = 256

    private var cancelled = false               // queue-only
    private var closedFired = false             // queue-only
    private var inbound: [UInt8] = []           // reader-thread-only

    init(fd: SocketFD, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        // The socket is already connected/accepted, so we're ready at once.
        // Dispatched (not called inline) so it runs on the serial queue and
        // before any inbound message the reader will enqueue afterwards.
        queue.async { [weak self] in self?.onReady?() }

        let r = Thread { [weak self] in self?.readLoop() }
        r.name = "clusterd.conn.read"; r.stackSize = 256 * 1024; r.start()
        let w = Thread { [weak self] in self?.writeLoop() }
        w.name = "clusterd.conn.write"; w.stackSize = 256 * 1024; w.start()
    }

    func send(_ msg: PeerMessage) {
        guard let data = WireCodec.encode(msg) else { return }
        let bytes = [UInt8](data)
        outLock.lock()
        if outQueue.count >= Self.maxQueued {
            outQueue.removeFirst(outQueue.count - (Self.maxQueued - 1))   // drop oldest
        }
        outQueue.append(bytes)
        outLock.signal()
        outLock.unlock()
    }

    func cancel() {
        // Runs on the serial queue. Idempotent.
        guard !cancelled else { return }
        cancelled = true
        outLock.lock(); stopped = true; outLock.signal(); outLock.unlock()
        Net.shutdownBoth(fd)   // unblock a parked recv
        Net.closeFD(fd)
    }

    private func fireClosedOnce() {
        queue.async { [weak self] in
            guard let self, !self.closedFired else { return }
            self.closedFired = true
            // If we initiated the teardown, PeerSession already dropped us.
            if !self.cancelled { self.onClosed?() }
        }
    }

    private func readLoop() {
        while true {
            guard let chunk = Net.recvSome(fd, max: 64 * 1024) else { fireClosedOnce(); return }
            inbound.append(contentsOf: chunk)
            while let idx = inbound.firstIndex(of: 0x0A) {
                let line = Array(inbound[..<idx])
                inbound.removeSubrange(...idx)
                if let msg = WireCodec.decode(Data(line)) {
                    queue.async { [weak self] in self?.onMessage?(msg) }
                }
            }
        }
    }

    private func writeLoop() {
        while true {
            outLock.lock()
            while outQueue.isEmpty && !stopped { outLock.wait() }
            if stopped && outQueue.isEmpty { outLock.unlock(); return }
            let batch = outQueue
            outQueue.removeAll(keepingCapacity: true)
            outLock.unlock()
            for bytes in batch {
                if !Net.sendAll(fd, bytes) { fireClosedOnce(); return }
            }
        }
    }
}
