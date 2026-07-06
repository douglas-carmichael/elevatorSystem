import Foundation

// Process-wide mDNS / DNS-SD engine — the non-Apple replacement for what
// Network.framework's `NWListener`(service) + `NWBrowser` do for free on macOS.
//
// ONE engine per process owns ONE UDP socket on 224.0.0.251:5353 and multiplexes
// every node: the app's `mDNSResponder` can hand N services off one socket, but
// N sockets each bound to :5353 can't co-exist cleanly, so all nodes register
// their `(instance, host, port, txt)` here and share the responder + browser.
//
// It must make each node fully *resolvable*, not merely listed: the macOS app
// dials an `NWEndpoint.service`, so Network.framework runs its own SRV→A
// resolution against us. We therefore answer PTR **and** SRV/TXT/A on demand,
// advertise a synthetic host name we alone own (never the machine's
// `<hostname>.local`, which the system responder is authoritative for), and
// send with IP TTL 255 (RFC 6762 §11).
//
// Threading: the blocking `recvfrom` runs on a dedicated reader thread that
// hands every packet to the shared serial `queue`; all engine state (registry,
// resolution caches, subscribers) is touched only on that queue, so there are
// no locks — matching the rest of the daemon.

/// A service one node asks the engine to publish.
struct MDNSService {
    let instanceName: String   // "<label>-<peerId8>._elevatorsys._tcp.local"
    let hostName: String       // "clusterd-<peerId8>.local" — synthetic, ours alone
    let port: UInt16           // the node's actual bound TCP port
    let peerId: String
    let label: String
}

/// A fully-resolved remote service handed to discovery subscribers.
struct DiscoveredService {
    let peerId: String
    let label: String
    let ip: UInt32             // network order, ready for TCP connect
    let port: UInt16
}

final class MDNSEngine {
    private let queue: DispatchQueue
    private let logger: Logger

    private var fd: SocketFD = invalidSocketFD
    private var reader: Thread?
    private var running = false
    private var localIP: UInt32 = Net.ipv4(127, 0, 0, 1)

    /// Registered services, keyed by lowercased instance name.
    private var services: [String: MDNSService] = [:]
    private var subscribers: [(DiscoveredService) -> Void] = []

    // Browser resolution caches, filled from every inbound response and joined
    // once an instance has all of SRV + TXT + (A for its target).
    private var srvByInstance: [String: (target: String, port: UInt16)] = [:]
    private var txtByInstance: [String: [String: String]] = [:]
    private var aByHost: [String: UInt32] = [:]
    /// Fully-resolved peers by peerId. Re-offered to subscribers periodically so
    /// a link that drops is re-dialed (subscribers dedup on connection state) —
    /// mirroring how `NWBrowser` keeps re-reporting live results.
    private var resolved: [String: DiscoveredService] = [:]

    private var announceTimer: DispatchSourceTimer?
    private var queryTimer: DispatchSourceTimer?

    /// "_elevatorsys._tcp.local" — the DNS-SD service type in the .local domain.
    static let serviceType = Sim.bonjourServiceType + ".local"
    private static let serviceTypeLower = serviceType.lowercased()

    init(queue: DispatchQueue, logger: Logger) {
        self.queue = queue
        self.logger = logger
    }

    // MARK: -- lifecycle (all on `queue`)

    func start() {
        localIP = Net.primaryIPv4() ?? Net.ipv4(127, 0, 0, 1)

        let s = Net.makeUDP()
        guard isValidSocket(s) else {
            logger.log("[mdns] failed to create socket")
            return
        }
        Net.setReuse(s)
        Net.setMulticastTTL(s, 255)
        Net.setMulticastLoop(s, true)   // hear co-hosted responders (and our own nodes)
        guard Net.bindAny(s, port: Net.mdnsPort) else {
            logger.log("[mdns] failed to bind :\(Net.mdnsPort) (is another responder holding it without SO_REUSEPORT?)")
            Net.closeFD(s)
            return
        }
        if !Net.joinMulticast(s, group: Net.mdnsGroup) {
            logger.log("[mdns] warning: could not join \(Net.ipv4String(Net.mdnsGroup)) — discovery may be receive-only")
        }
        fd = s
        running = true
        logger.log("[mdns] engine up on \(Net.ipv4String(localIP)):\(Net.mdnsPort)")

        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "clusterd.mdns.reader"
        t.stackSize = 256 * 1024
        reader = t
        t.start()

        // Browse: repeated PTR queries prompt responders to (re)send full
        // records; peers' own periodic announcements fill the caches too.
        let q = DispatchSource.makeTimerSource(queue: queue)
        q.schedule(deadline: .now() + 0.3, repeating: 3.0, leeway: .milliseconds(200))
        q.setEventHandler { [weak self] in
            self?.sendBrowseQuery()
            self?.reoffer()
        }
        q.resume()
        queryTimer = q

        // Announce: unsolicited multicast of everything we publish, so peers
        // discover us without having to query first.
        let a = DispatchSource.makeTimerSource(queue: queue)
        a.schedule(deadline: .now() + 0.5, repeating: 5.0, leeway: .milliseconds(500))
        a.setEventHandler { [weak self] in self?.announceAll() }
        a.resume()
        announceTimer = a
    }

    func stop() {
        guard running else { return }
        running = false
        sendGoodbye()
        announceTimer?.cancel(); announceTimer = nil
        queryTimer?.cancel(); queryTimer = nil
        // Unblock the parked reader, then close.
        if isValidSocket(fd) {
            Net.shutdownBoth(fd)
            Net.closeFD(fd)
            fd = invalidSocketFD
        }
    }

    // MARK: -- registration (all on `queue`)

    func register(_ service: MDNSService) {
        services[service.instanceName.lowercased()] = service
        // Announce the newcomer immediately (a small burst would be more RFC-
        // pure; one prompt announce plus the 5 s timer is plenty for a demo).
        if running { announce(service, ttl: nil) }
    }

    func unregister(instanceName: String) {
        let key = instanceName.lowercased()
        if let s = services[key], running { announce(s, ttl: 0) }   // goodbye
        services.removeValue(forKey: key)
    }

    func subscribe(_ cb: @escaping (DiscoveredService) -> Void) {
        subscribers.append(cb)
    }

    // MARK: -- reader thread

    private func readLoop() {
        while running {
            guard let (bytes, ip, port) = Net.recvFrom(fd, max: 9000) else { break }
            queue.async { [weak self] in self?.handle(bytes, fromIP: ip, fromPort: port) }
        }
    }

    // MARK: -- inbound handling (on `queue`)

    private func handle(_ bytes: [UInt8], fromIP: UInt32, fromPort: UInt16) {
        guard let msg = DNSMessage.decode(bytes) else { return }
        // Any packet's records may advance a resolution (responses carry them;
        // queries can carry known-answers).
        ingest(msg.allRecords)
        if !msg.isResponse { respond(to: msg, fromIP: fromIP, fromPort: fromPort) }
    }

    // MARK: responder

    private func respond(to query: DNSMessage, fromIP: UInt32, fromPort: UInt16) {
        guard !services.isEmpty else { return }
        var answers: [DNSRecord] = []
        var additionals: [DNSRecord] = []
        var wantUnicast = false

        // Legacy unicast (RFC 6762 §6.7): a querier whose source port isn't 5353
        // must be answered by unicast with short TTLs and no cache-flush bit.
        let legacy = fromPort != Net.mdnsPort

        for q in query.questions {
            if q.unicastResponse || legacy { wantUnicast = true }
            let qnameLower = q.name.lowercased()
            let t = q.type

            if qnameLower == Self.serviceTypeLower && (t == DNSType.ptr.rawValue || t == DNSType.any.rawValue) {
                for s in services.values {
                    answers.append(ptrRecord(s, legacy: legacy))
                    additionals.append(srvRecord(s, legacy: legacy))
                    additionals.append(txtRecord(s, legacy: legacy))
                    additionals.append(aRecord(s, legacy: legacy))
                }
                continue
            }
            for s in services.values where s.instanceName.lowercased() == qnameLower {
                if t == DNSType.srv.rawValue || t == DNSType.any.rawValue {
                    answers.append(srvRecord(s, legacy: legacy)); additionals.append(aRecord(s, legacy: legacy))
                }
                if t == DNSType.txt.rawValue || t == DNSType.any.rawValue {
                    answers.append(txtRecord(s, legacy: legacy))
                }
            }
            for s in services.values where s.hostName.lowercased() == qnameLower {
                if t == DNSType.a.rawValue || t == DNSType.any.rawValue {
                    answers.append(aRecord(s, legacy: legacy))
                }
            }
        }

        answers = dedup(answers)
        additionals = dedup(additionals).filter { add in
            !answers.contains { $0.name.lowercased() == add.name.lowercased() && $0.type == add.type }
        }
        guard !answers.isEmpty else { return }

        var resp = DNSMessage()
        resp.id = legacy ? query.id : 0          // legacy replies mirror the query id
        resp.flags = dnsFlagResponse | dnsFlagAuthoritative
        resp.answers = answers
        resp.additionals = additionals
        let bytes = resp.encode()

        if wantUnicast {
            _ = Net.sendTo(fd, bytes, ip: fromIP, port: fromPort)
        } else {
            _ = Net.sendTo(fd, bytes, ip: Net.mdnsGroup, port: Net.mdnsPort)
        }
    }

    // MARK: browser

    private func sendBrowseQuery() {
        var q = DNSMessage()
        q.questions = [DNSQuestion(name: Self.serviceType, type: DNSType.ptr.rawValue, unicastResponse: false)]
        _ = Net.sendTo(fd, q.encode(), ip: Net.mdnsGroup, port: Net.mdnsPort)
    }

    private func ingest(_ records: [DNSRecord]) {
        for rec in records {
            let nameLower = rec.name.lowercased()
            switch rec.rdata {
            case let .srv(_, _, port, target):
                srvByInstance[nameLower] = (target: target.lowercased(), port: port)
            case .txt:
                txtByInstance[nameLower] = rec.txtPairs
            case let .a(ip):
                aByHost[nameLower] = ip
            default:
                break
            }
        }
        resolvePending()
    }

    /// Emit any instance that now has SRV + TXT(peerId) + A(for its target).
    private func resolvePending() {
        for (instance, srv) in srvByInstance {
            guard let txt = txtByInstance[instance],
                  let peerId = txt["peerId"], !peerId.isEmpty,
                  let ip = aByHost[srv.target] else { continue }
            let label = txt["label"] ?? peerId
            let found = DiscoveredService(peerId: peerId, label: label, ip: ip, port: srv.port)
            if let prev = resolved[peerId], prev.ip == ip, prev.port == srv.port { continue }
            resolved[peerId] = found
            logger.log("[mdns] resolved \(label) [\(String(peerId.prefix(8)))] at \(Net.ipv4String(ip)):\(srv.port)")
            for cb in subscribers { cb(found) }
        }
    }

    /// Replay all resolved peers to subscribers (they dedup on connection state)
    /// so a dropped link re-dials within a query cycle.
    private func reoffer() {
        guard !resolved.isEmpty, !subscribers.isEmpty else { return }
        for s in resolved.values {
            for cb in subscribers { cb(s) }
        }
    }

    // MARK: announcements

    private func announceAll() {
        for s in services.values { announce(s, ttl: nil) }
    }

    private func announce(_ s: MDNSService, ttl: UInt32?) {
        var m = DNSMessage()
        m.flags = dnsFlagResponse | dnsFlagAuthoritative
        m.answers = [ptrRecord(s, legacy: false, ttlOverride: ttl)]
        m.additionals = [
            srvRecord(s, legacy: false, ttlOverride: ttl),
            txtRecord(s, legacy: false, ttlOverride: ttl),
            aRecord(s, legacy: false, ttlOverride: ttl),
        ]
        _ = Net.sendTo(fd, m.encode(), ip: Net.mdnsGroup, port: Net.mdnsPort)
    }

    private func sendGoodbye() {
        for s in services.values { announce(s, ttl: 0) }
    }

    // MARK: record builders

    private func ptrRecord(_ s: MDNSService, legacy: Bool, ttlOverride: UInt32? = nil) -> DNSRecord {
        DNSRecord(name: Self.serviceType, type: DNSType.ptr.rawValue,
                  cacheFlush: false,                       // shared PTR: never cache-flush
                  ttl: ttlOverride ?? (legacy ? 10 : 4500),
                  rdata: .ptr(s.instanceName))
    }

    private func srvRecord(_ s: MDNSService, legacy: Bool, ttlOverride: UInt32? = nil) -> DNSRecord {
        DNSRecord(name: s.instanceName, type: DNSType.srv.rawValue,
                  cacheFlush: !legacy,
                  ttl: ttlOverride ?? (legacy ? 10 : 120),
                  rdata: .srv(priority: 0, weight: 0, port: s.port, target: s.hostName))
    }

    private func txtRecord(_ s: MDNSService, legacy: Bool, ttlOverride: UInt32? = nil) -> DNSRecord {
        DNSRecord(name: s.instanceName, type: DNSType.txt.rawValue,
                  cacheFlush: !legacy,
                  ttl: ttlOverride ?? (legacy ? 10 : 120),
                  rdata: .txt(["peerId=\(s.peerId)", "label=\(s.label)"]))
    }

    private func aRecord(_ s: MDNSService, legacy: Bool, ttlOverride: UInt32? = nil) -> DNSRecord {
        DNSRecord(name: s.hostName, type: DNSType.a.rawValue,
                  cacheFlush: !legacy,
                  ttl: ttlOverride ?? (legacy ? 10 : 120),
                  rdata: .a(localIP))
    }

    private func dedup(_ records: [DNSRecord]) -> [DNSRecord] {
        var seen = Set<String>()
        var out: [DNSRecord] = []
        for r in records {
            let key = "\(r.name.lowercased())|\(r.type)"
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }
}
