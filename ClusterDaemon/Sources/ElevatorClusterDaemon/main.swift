import Foundation
import Dispatch
// Foundation does NOT re-export the C library on Linux/Windows, so the raw
// stdio/signal symbols (`setvbuf`, `signal`, `_IOLBF`, `SIG_IGN`, …) must be
// imported explicitly per platform.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

// elevator-clusterd -- headless cluster-peer daemon for ElevatorSystem.
//
// Publishes one or more OpenVMS-style dispatcher "nodes" on the LAN. On macOS
// discovery + transport run on Bonjour/Network.framework; on Linux/Windows (or
// with ELEVATORD_TRANSPORT=socket) they run on a hand-rolled mDNS + BSD-socket
// stack that speaks the same wire, so the same cabs appear as remote peers.
// Running it alongside the app on one machine demonstrates the multi-peer
// networking without a second box.

// Line-buffer stdout so log lines appear promptly even when piped to a file or
// a pager. On Windows `_IOLBF` means *full* buffering, so use unbuffered there
// to keep logs prompt.
#if os(Windows)
setvbuf(stdout, nil, _IONBF, 0)
#else
setvbuf(stdout, nil, _IOLBF, 0)
#endif

// Hidden `--selftest`: exercise the hand-rolled wire codecs (mirrors the app's
// SELFTEST ethos) and exit non-zero on any failure. Cheap confidence that the
// DNS/mDNS parsing round-trips (the riskiest part of the transport) and that the
// peer wire (JSON via WireCodec) encodes+decodes identically on this platform —
// the CI matrix runs this on macOS, Linux, and Windows to lock wire-compat.
if CommandLine.arguments.contains("--selftest") {
    func wireSelfTest() -> Bool {
        let cab = Elevator.newAt(floor: 3, label: "07", ownerPeerId: "PEER-1",
                                 automatic: true, profile: .freight)
        guard let sBytes = WireCodec.encode(.state(cab)),
              let sMsg = WireCodec.decode(Data(sBytes.dropLast())),   // drop the newline frame byte
              let rt = sMsg.elevator, rt.id == cab.id, rt.label == "07",
              rt.profile == .freight, rt.doors == .closed else { return false }
        let snap = HostSnapshot(cpuBusy: 12.5, memUsedPercent: 40, bufferedIORate: 100,
                                directIORate: 50, lockRate: 200, processCount: 210, sampledAt: Date())
        guard let stBytes = WireCodec.encode(.stats(peerId: "PEER-1", snapshot: snap)),
              let stMsg = WireCodec.decode(Data(stBytes.dropLast())),
              let rs = stMsg.snapshot, abs(rs.cpuBusy - 12.5) < 0.001,
              rs.processCount == 210 else { return false }
        return true
    }
    let dnsOK = DNSMessage.selfTest()
    let wireOK = wireSelfTest()
    print("DNS codec self-test:  \(dnsOK ? "PASS" : "FAIL")")
    print("peer wire self-test:  \(wireOK ? "PASS" : "FAIL")")
    exit(dnsOK && wireOK ? 0 : 1)
}

// MARK: -- options

struct Options {
    var nodeCount = 1
    var cabsPerNode = 4
    var label = "SIMNODE"
    var floors = Sim.floorCount
    var rate = Int(Sim.tickHz)   // state broadcasts / sec; default = sim tick rate (60)
    var quiet = false
}

func printUsage() {
    print("""
    elevator-clusterd — headless elevator cluster peer for ElevatorSystem

    Publishes one or more dispatcher nodes on the LAN via Bonjour
    (\(Sim.bonjourServiceType)); each node owns a cluster of auto-driven cabs
    that the ElevatorSystem app discovers and shows as remote peers. Lets you
    demonstrate the multi-peer networking with a single machine.

    USAGE:
      swift run elevator-clusterd [options]

    OPTIONS:
      -n, --nodes   N   Independent peer nodes to publish (default 1)
      -c, --cabs    N   Cabs per node (default 4)
      -l, --label   S   Node label / Bonjour name prefix (default "SIMNODE")
      -f, --floors  N   Top floor cabs travel to (2…\(Sim.floorCount), default \(Sim.floorCount))
      -r, --rate    N   State broadcasts / sec (1…\(Int(Sim.tickHz)), default \(Int(Sim.tickHz)))
      -q, --quiet       Suppress per-event logging (banner + heartbeat only)
      --socket          Force the mDNS + BSD-socket transport (Linux/Windows
                        default; on macOS this exercises that path against the
                        app). Same as ELEVATORD_TRANSPORT=socket.
      --selftest        Run the wire codec self-tests and exit (used by CI)
      -h, --help        Show this help and exit

    EXAMPLES:
      swift run elevator-clusterd
      swift run elevator-clusterd --nodes 3 --cabs 2
      swift run elevator-clusterd -n 1 -c 6 -l DAUPHINE
      swift run elevator-clusterd --rate 20        # lean on the app's extrapolation
    """)
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("elevator-clusterd: \(message)\n".utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    func takeValue(for flag: String) -> String {
        guard !args.isEmpty else { die("missing value for \(flag)") }
        return args.removeFirst()
    }
    func takeInt(for flag: String) -> Int {
        let raw = takeValue(for: flag)
        guard let value = Int(raw) else { die("invalid integer for \(flag): \(raw)") }
        return value
    }

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "-n", "--nodes":  options.nodeCount = takeInt(for: arg)
        case "-c", "--cabs":   options.cabsPerNode = takeInt(for: arg)
        case "-l", "--label":  options.label = takeValue(for: arg)
        case "-f", "--floors": options.floors = takeInt(for: arg)
        case "-r", "--rate":   options.rate = takeInt(for: arg)
        case "-q", "--quiet":  options.quiet = true
        // Verification lever: force the mDNS + socket transport even on Apple.
        // Consumed here so the parser accepts it; read separately via
        // CommandLine when choosing the transport.
        case "--socket":       break
        case "-h", "--help":   printUsage(); exit(0)
        default:               die("unknown option: \(arg) (try --help)")
        }
    }

    options.nodeCount = max(1, options.nodeCount)
    options.cabsPerNode = max(1, options.cabsPerNode)
    options.floors = max(2, min(Sim.floorCount, options.floors))
    // Broadcasting faster than the sim tick would just resend identical
    // state, so cap the rate at the tick rate.
    options.rate = max(1, min(Int(Sim.tickHz), options.rate))
    if options.label.isEmpty { options.label = "SIMNODE" }
    return options
}

// MARK: -- wiring

let options = parseOptions()
let logger = Logger(quiet: options.quiet)
let queue = DispatchQueue(label: "net.dcarmichael.clusterd.sim")

// Transport selection. Apple defaults to Network.framework/Bonjour; everywhere
// else (and on macOS when forced, for cross-platform verification) we run the
// hand-rolled mDNS + socket stack. A single shared discovery engine serves all
// nodes — N sockets can't each own :5353.
let forceSocket = ProcessInfo.processInfo.environment["ELEVATORD_TRANSPORT"] == "socket"
    || CommandLine.arguments.contains("--socket")
let discovery: MDNSEngine?
#if canImport(Network)
discovery = forceSocket ? MDNSEngine(queue: queue, logger: logger) : nil
#else
discovery = MDNSEngine(queue: queue, logger: logger)
#endif
if discovery != nil { Net.initialize() }   // WSAStartup on Windows; ignore SIGPIPE on POSIX
let transportName = discovery == nil ? "Bonjour/Network.framework" : "mDNS + BSD sockets"

let nodes: [ClusterNode] = (0..<options.nodeCount).map { index in
    // With a single node keep the bare label; multiple nodes get a 1-based
    // suffix so they show up as distinct peers (SIMNODE1, SIMNODE2, …).
    let nodeLabel = options.nodeCount == 1 ? options.label : "\(options.label)\(index + 1)"
    return ClusterNode(label: nodeLabel, cabCount: options.cabsPerNode, floors: options.floors,
                       broadcastHz: options.rate, queue: queue, logger: logger, discovery: discovery)
}

logger.raw("""
==============================================================
 elevator-clusterd — ElevatorSystem headless cluster peer
   nodes: \(options.nodeCount)   cabs/node: \(options.cabsPerNode)   floors: 1…\(options.floors)
   sim tick: \(Int(Sim.tickHz)) Hz   state broadcast: \(options.rate) Hz
   service: \(Sim.bonjourServiceType)   transport: \(transportName)
   Launch the ElevatorSystem app (this Mac or another on the LAN)
   to see these cabs appear as remote peers. Ctrl-C to stop.
==============================================================
""")

// Start the shared discovery engine (opens :5353) before the nodes register
// their services with it.
queue.async {
    discovery?.start()
    nodes.forEach { $0.start() }
}

// Aggregate heartbeat so the operator can see liveness at a glance, including
// the measured outbound `.state` rate (rounds/sec summed across nodes) so the
// configured broadcast rate is observable, not just asserted.
var lastHeartbeatAt = Date()
let heartbeat = DispatchSource.makeTimerSource(queue: queue)
heartbeat.schedule(deadline: .now() + 10, repeating: 10)
heartbeat.setEventHandler {
    let now = Date()
    let elapsed = now.timeIntervalSince(lastHeartbeatAt)
    lastHeartbeatAt = now
    let cabs = nodes.reduce(0) { $0 + $1.cabCount }
    let links = nodes.reduce(0) { $0 + $1.connectionCount }
    let rounds = nodes.reduce(0) { $0 + $1.drainBroadcastRounds() }
    let hz = elapsed > 0 ? Double(rounds) / elapsed : 0
    logger.raw(String(format: "%@  heartbeat — %d node(s), %d cab(s), %d peer link(s), ~%.0f state bcast/s",
                      Logger.clock(), nodes.count, cabs, links, hz))
}
heartbeat.resume()

// Graceful shutdown: send `.bye` from every node so the app drops our cabs
// cleanly rather than waiting for the TCP keepalive to time out, then exit after
// a short grace period to let those frames flush. Must run on `queue`.
func performShutdown() {
    logger.raw("\nsignal received — notifying peers and shutting down…")
    nodes.forEach { $0.stop(sendBye: true) }
    discovery?.stop()
    queue.asyncAfter(deadline: .now() + 0.3) {
        Net.teardown()
        exit(0)
    }
}

#if os(Windows)
// Windows has no POSIX signals; the console control handler fires on an OS-
// injected thread, so it marshals the shutdown onto the serial queue and then
// briefly blocks (Windows allows ~5 s) so the `.bye` frames can flush.
let ctrlHandler: @convention(c) (DWORD) -> WindowsBool = { _ in
    queue.async { performShutdown() }
    Thread.sleep(forTimeInterval: 0.6)
    return true
}
SetConsoleCtrlHandler(ctrlHandler, true)
#else
// POSIX (macOS + Linux): DispatchSource signal sources deliver SIGINT/SIGTERM
// onto the serial queue.
func makeSignalSource(_ sig: Int32) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)   // disable default handler; DispatchSource takes over
    let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    source.setEventHandler { performShutdown() }
    source.resume()
    return source
}
let signalSources = [makeSignalSource(SIGINT), makeSignalSource(SIGTERM)]
_ = signalSources   // retain for process lifetime
#endif

dispatchMain()
