import Foundation

// elevator-clusterd -- headless cluster-peer daemon for ElevatorSystem.
//
// Publishes one or more OpenVMS-style dispatcher "nodes" on the LAN via
// Bonjour; each owns a cluster of auto-driven cabs that the ElevatorSystem
// app (or another daemon) discovers and displays as remote peers. Running it
// alongside the app on a single Mac demonstrates the multi-peer networking
// without needing a second machine.

// Line-buffer stdout so log lines appear promptly even when piped to a file
// or a pager rather than a TTY.
setvbuf(stdout, nil, _IOLBF, 0)

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

let nodes: [ClusterNode] = (0..<options.nodeCount).map { index in
    // With a single node keep the bare label; multiple nodes get a 1-based
    // suffix so they show up as distinct peers (SIMNODE1, SIMNODE2, …).
    let nodeLabel = options.nodeCount == 1 ? options.label : "\(options.label)\(index + 1)"
    return ClusterNode(label: nodeLabel, cabCount: options.cabsPerNode, floors: options.floors,
                       broadcastHz: options.rate, queue: queue, logger: logger)
}

logger.raw("""
==============================================================
 elevator-clusterd — ElevatorSystem headless cluster peer
   nodes: \(options.nodeCount)   cabs/node: \(options.cabsPerNode)   floors: 1…\(options.floors)
   sim tick: \(Int(Sim.tickHz)) Hz   state broadcast: \(options.rate) Hz
   service: \(Sim.bonjourServiceType)
   Launch the ElevatorSystem app (this Mac or another on the LAN)
   to see these cabs appear as remote peers. Ctrl-C to stop.
==============================================================
""")

queue.async { nodes.forEach { $0.start() } }

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
// cleanly rather than waiting for the TCP keepalive to time out, then exit
// after a short grace period to let those frames flush.
func makeSignalSource(_ sig: Int32) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)   // disable default handler; DispatchSource takes over
    let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    source.setEventHandler {
        logger.raw("\nsignal received — notifying peers and shutting down…")
        nodes.forEach { $0.stop(sendBye: true) }
        queue.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
    source.resume()
    return source
}
let signalSources = [makeSignalSource(SIGINT), makeSignalSource(SIGTERM)]
_ = signalSources   // retain for process lifetime

dispatchMain()
