import Foundation

// MONITOR continuous full-screen utility and per-class renderers.
extension DCLEngine {
    func monitorCmd(_ cmd: Parsed) -> String {
        let cls: String = cmd.positional.first.map { resolveMonitorClass($0) } ?? "SYSTEM"
        var interval: TimeInterval = 3.0
        if let raw = cmd.qualifierValue("INTERVAL"), let n = Double(raw), n >= 1 {
            interval = n
        }
        if dryRun {
            return "%MONITOR-S-START, would start MONITOR \(cls) /INTERVAL=\(Int(interval)) (dry-run)\n"
        }
        startMonitor(class: cls, interval: interval)
        return ""
    }

    func resolveMonitorClass(_ what: String) -> String {
        switch true {
        case matches(what, "SYSTEM",      min: 3): return "SYSTEM"
        case matches(what, "PROCESSES",   min: 4): return "PROCESSES"
        case matches(what, "DISK"):                return "DISK"
        case matches(what, "IO"):                  return "IO"
        case matches(what, "PAGE"):                return "PAGE"
        case matches(what, "STATES",      min: 3): return "STATES"
        case matches(what, "MODES",       min: 3): return "MODES"
        case matches(what, "LOCK",        min: 4): return "LOCK"
        case matches(what, "CLUSTER",     min: 3): return "CLUSTER"
        case matches(what, "FCP"):                 return "FCP"
        case matches(what, "DYNAMICS",    min: 3): return "DYNAMICS"
        case matches(what, "ALL_CLASSES", min: 3): return "ALL_CLASSES"
        default: return "SYSTEM"
        }
    }

    func renderMonitor(_ cls: String) -> String {
        switch cls {
        case "SYSTEM":      return monitorSystem()
        case "MODES":       return monitorModes()
        case "PROCESSES":   return monitorProcesses()
        case "IO":          return monitorIO()
        case "PAGE":        return monitorPage()
        case "STATES":      return monitorStates()
        case "DISK":        return monitorDisk()
        case "LOCK":        return monitorLock()
        case "CLUSTER":     return monitorCluster()
        case "FCP":         return monitorFCP()
        case "DYNAMICS":    return monitorDynamics()
        case "ALL_CLASSES": return monitorSystem() + monitorIO() + monitorStates()
        default:            return monitorSystem()
        }
    }

    func startMonitor(class cls: String, interval: TimeInterval = 3.0) {
        liveTimer?.invalidate()
        liveMode = .monitor
        monitorClass = cls
        monitorIntervalSec = interval
        monitorStartedAt = Date()
        enterLiveScreen()
        refreshLiveDisplay()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveDisplay() }
        }
        liveTimer = t
    }

    /// Stops whichever live-screen mode is active. Ctrl-Y in the DCL window
    /// triggers this.
    func stopMonitor(interrupt: Bool = true) {
        guard liveActive else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        let wasTest: Bool
        if case .testUtility = liveMode { wasTest = true } else { wasTest = false }
        liveMode = .none

        // If the test was launched from the DIAGNOSE menu, pop back to
        // the menu instead of dropping to the DCL prompt. The alt-screen
        // buffer is already active, so we just repaint over the
        // finished test view -- no exit / re-enter needed, and no
        // "%RUN-I-ABORTED" message (it would only be visible after the
        // operator later left the menu).
        if wasTest && diagInvokedFromMenu {
            diagInvokedFromMenu = false
            startDiagnosticMenu()
            return
        }

        exitLiveScreen()
        if interrupt {
            if wasTest {
                out("%RUN-I-ABORTED, diagnostic was interrupted by Ctrl/Y\n")
            } else {
                out("%MONITOR-I-INTERRUPT, request was interrupted by Ctrl/Y\n")
            }
        }
        out(prompt)
    }

    func refreshLiveDisplay() {
        let now = Date()
        let elapsed = uptimeString(from: monitorStartedAt, to: now)
        let body = renderMonitor(monitorClass)
        var s = body
        s += "\n" + String(repeating: "-", count: 76) + "\n"
        s += "  From: \(stamp(monitorStartedAt))   To: \(stamp(now))\n"
        s += "  Elapsed: \(elapsed)   Interval: \(Int(monitorIntervalSec))s\n"
        s += "  Press  Ctrl/Y  or  ESC ESC  to interrupt and return to the DCL prompt.\n"
        // Full clear (CSI 2 J) + home (CSI H) before each frame is what
        // real SMG$ emits and is the only sequence that reliably wipes
        // the previous refresh on terminals whose row count we don't
        // know -- without this, taller body content scrolls and leaves
        // duplicate rows from earlier frames visible under the new one
        // (especially on external clients like ghostty via nc).
        // CSI 0 m resets any leftover SGR before the clear so reverse-
        // video erase cells don't bleed into the new frame.
        outRaw("\u{1B}[0m\u{1B}[2J\u{1B}[H" + s.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    /// Enter the VT220/320 alternate screen buffer so a continuous-monitor
    /// or full-screen test utility can repaint without scrolling the
    /// transcript.
    func enterLiveScreen() {
        liveActive = true
        outRaw("\u{1B}[?1049h\u{1B}[2J\u{1B}[H")
    }

    /// Pop the alternate screen buffer. The terminal restores whatever
    /// was on the screen before MONITOR / RUN started.
    func exitLiveScreen() {
        guard liveActive else { return }
        liveActive = false
        outRaw("\u{1B}[?1049l")
    }

    // MARK: -- formatting helpers shared by the MONITOR class renderers

    /// Deterministic jitter so AVE / MIN / MAX move with CUR but stay stable
    /// from one redraw to the next.
    func mjitter(_ cur: Double) -> (ave: Double, min: Double, max: Double) {
        let ave = cur * 0.94
        let lo  = max(0.0, cur * 0.42)
        let hi  = cur * 1.62
        return (ave, lo, hi)
    }

    func mjitteri(_ cur: Int) -> (ave: Int, min: Int, max: Int) {
        let ave = max(0, Int(Double(cur) * 0.94))
        let lo  = max(0, Int(Double(cur) * 0.65))
        let hi  = Int(Double(cur) * 1.32) + 1
        return (ave, lo, hi)
    }

    func mheader(_ title: String) -> String {
        // Real OpenVMS MONITOR draws a plain four-line centered banner --
        // "OpenVMS Monitor Utility", the class title, "on node <node>", and
        // the timestamp -- with no decorative rule around the title. SMG$
        // renders the top two lines (utility name + class title) in reverse
        // video; SGR 7 / SGR 27 toggle that on/off and the RetroTerminalView
        // emulator (and external telnet clients) honor them.
        var s = "\n"
        s += reverseCentered("\(osTitle) Monitor Utility") + "\n"
        s += reverseCentered(title) + "\n"
        s += centered("on node \(nodeName)") + "\n"
        s += centered(stamp(Date())) + "\n\n"
        return s
    }

    func mcolHeader(percent: Bool = false) -> String {
        // Column headers (CUR / AVE / MIN / MAX) in bold to match the
        // attribute SMG$ applies on real VMS displays. Percentage classes
        // (MODES, STATES) suffix each heading with "%" -- "CUR% AVE% ..." --
        // exactly as the real utility does.
        let suffix = percent ? "%" : ""
        let row = mlabel("") +
                  mvalHeader("CUR" + suffix) + mvalHeader("AVE" + suffix) +
                  mvalHeader("MIN" + suffix) + mvalHeader("MAX" + suffix)
        return "\u{1B}[1m" + row + "\u{1B}[22m" + "\n\n"
    }

    /// Centers `s` in `width` columns and wraps the visible text (not the
    /// leading padding) in SGR-7 reverse-video so the highlight matches
    /// exactly the printable banner length, not the whole row.
    func reverseCentered(_ s: String, width: Int = 80) -> String {
        let pad = max(0, (width - s.count) / 2)
        return String(repeating: " ", count: pad) + "\u{1B}[7m" + s + "\u{1B}[27m"
    }

    func mlabel(_ s: String) -> String {
        return s.padding(toLength: 32, withPad: " ", startingAt: 0)
    }

    func mvalHeader(_ s: String) -> String {
        return rightPad(s, width: 11)
    }

    func mrow(_ label: String, _ cur: Double) -> String {
        let j = mjitter(cur)
        return String(format: "%@%11.2f%11.2f%11.2f%11.2f\n",
                      mlabel(label), cur, j.ave, j.min, j.max)
    }

    /// A `mrow` for percentage classes (MODES, STATES): CUR and the derived
    /// AVE/MIN/MAX are clamped to 0..100 so the table never reports an
    /// impossible figure like 160% Idle Time -- real MONITOR percentage
    /// columns can't exceed 100.
    func mrowPct(_ label: String, _ cur: Double) -> String {
        let c = min(100.0, max(0.0, cur))
        let j = mjitter(c)
        return String(format: "%@%11.2f%11.2f%11.2f%11.2f\n",
                      mlabel(label), c,
                      min(100.0, j.ave), min(100.0, j.min), min(100.0, j.max))
    }

    func mrowi(_ label: String, _ cur: Int) -> String {
        let j = mjitteri(cur)
        return String(format: "%@%11d%11d%11d%11d\n",
                      mlabel(label), cur, j.ave, j.min, j.max)
    }

    func centered(_ s: String, width: Int = 80) -> String {
        let pad = max(0, (width - s.count) / 2)
        return String(repeating: " ", count: pad) + s
    }

    func rightPad(_ s: String, width: Int) -> String {
        let need = max(0, width - s.count)
        return String(repeating: " ", count: need) + s
    }

    // MARK: -- MONITOR class renderers

    func monitorSystem() -> String {
        let usage = host.cpuUsage()
        let kernel = usage.system * 0.55
        let exec   = usage.system * 0.25
        let super_ = usage.system * 0.15
        let intr   = usage.system * 0.05
        let user   = usage.user + usage.nice
        let procCount = host.processCount()
        let rates = host.vmRates()
        let vm = host.vmStats()
        let disks = host.diskRates()
        let totalDiskOps = disks.reduce(0.0) { $0 + $1.totalOpsPerSec }

        // Row set and order are exactly the real SYSTEM class: the eight
        // processor-mode lines, Process Count, the two page rates, the Free
        // and Modified list sizes (in pages), then the two I/O rates. MP
        // Synchronization and Compatibility Mode are always 0.00 on x86_64
        // VSI OpenVMS but real MONITOR still lists them, so we keep the rows.
        var s = mheader("SYSTEM STATISTICS")
        s += mcolHeader()
        s += mrow("Interrupt State",            intr)
        s += mrow("MP Synchronization",         0.0)
        s += mrow("Kernel Mode",                kernel)
        s += mrow("Executive Mode",             exec)
        s += mrow("Supervisor Mode",            super_)
        s += mrow("User Mode",                  user)
        s += mrow("Compatibility Mode",         0.0)
        s += mrow("Idle Time",                  usage.idle)
        s += mrowi("Process Count",             procCount)
        s += mrow("Page Fault Rate",            rates.pageFaultRate)
        s += mrow("Page Read I/O Rate",         rates.pageInRate)
        s += mrow("Free List Size",             Double(vm.freePages))
        s += mrow("Modified List Size",         Double(vm.inactivePages))
        s += mrow("Direct I/O Rate",            totalDiskOps)
        s += mrow("Buffered I/O Rate",          rates.lookupRate)
        return s
    }

    func monitorModes() -> String {
        let usage = host.cpuUsage()
        let kernel = usage.system * 0.55
        let exec   = usage.system * 0.25
        let super_ = usage.system * 0.15
        let intr   = usage.system * 0.05
        let user   = usage.user + usage.nice

        // Real MONITOR MODES titles the class "(%)" and heads the columns
        // CUR% AVE% MIN% MAX%. MP Synchronization and Compatibility Mode are
        // always 0.00 on x86_64 VSI OpenVMS but the utility still lists them;
        // the eight-row frame fits comfortably inside a 24-line terminal.
        var s = mheader("TIME IN PROCESSOR MODES (%)")
        s += mcolHeader(percent: true)
        s += mrowPct("Interrupt State",            intr)
        s += mrowPct("MP Synchronization",         0.0)
        s += mrowPct("Kernel Mode",                kernel)
        s += mrowPct("Executive Mode",             exec)
        s += mrowPct("Supervisor Mode",            super_)
        s += mrowPct("User Mode",                  user)
        s += mrowPct("Compatibility Mode",         0.0)
        s += mrowPct("Idle Time",                  usage.idle)
        return s
    }

    func monitorProcesses() -> String {
        let usage = host.cpuUsage()
        var rows: [(pid: String, name: String, pct: Double, state: String)] = []
        rows.append(("00000403", "ELEVATOR_CTL",   max(2.0, usage.busy * 0.42), "LEF"))
        for (i, cab) in (world?.elevators ?? []).prefix(6).enumerated() {
            let pid = String(format: "%08X", 0x0404 + i)
            let pct = max(0.5, min(40.0, Double((i * 7 + Int(usage.busy)) % 35)))
            let st  = cab.direction == .idle ? "HIB" : "COM"
            let dLabel = world?.displayLabel(for: cab) ?? cab.label
            rows.append((pid, "CAB_\(dLabel)_TASK", pct, st))
        }
        rows.append(("0000040A", "COMM_NETSRV",    1.2, "LEF"))
        rows.append(("0000040B", "BONJOUR_PUBSRV", 0.4, "LEF"))
        rows.append((pid,        "DCL_\(username)", max(0.5, min(20.0, usage.user * 0.20)), "CUR"))

        var s = mheader("TOP CPU TIME PROCESSES")
        s += "    0     10    20    30    40    50    60    70    80    90    100\n"
        s += "    + - - + - - + - - + - - + - - + - - + - - + - - + - - + - - +\n"
        for r in rows {
            let bars = String(repeating: "*", count: max(0, min(50, Int(r.pct / 2.0))))
            let hdr  = String(format: "%@ %@ %5.1f  %@",
                              r.pid,
                              r.name.padding(toLength: 16, withPad: " ", startingAt: 0),
                              r.pct, r.state)
            s += "\(hdr)\n"
            s += "    |\(bars)\n"
        }
        return s
    }

    func monitorIO() -> String {
        let rates = host.vmRates()
        let disks = host.diskRates()
        let totalOps = disks.reduce(0.0) { $0 + $1.totalOpsPerSec }
        let totalReadOps = disks.reduce(0.0) { $0 + $1.readOpsPerSec }
        let totalWriteOps = disks.reduce(0.0) { $0 + $1.writeOpsPerSec }
        // Total cache lookups/sec stands in for the VMS Buffered I/O Rate
        // (per-process buffered I/O isn't broken out at the Mach layer).
        let bufIO = rates.lookupRate
        // Window turn rate has no direct Mac analogue; use reactivations
        // (pages reclaimed from the inactive list) which is the closest
        // "page-table fixup" event Mach exposes.
        let windowTurn = rates.reactivationRate
        var s = mheader("I/O SYSTEM STATISTICS")
        s += mcolHeader()
        s += mrow("Direct I/O Rate",             totalOps)
        s += mrow("Buffered I/O Rate",           bufIO)
        s += mrow("Mailbox Write Rate",          0.0)
        s += mrow("Split Transfer Rate",         0.0)
        s += mrow("Log Name Translation Rate",   rates.hitRate)
        s += mrow("File Open Rate",              0.0)
        s += mrow("Page Fault Rate",             rates.pageFaultRate)
        s += mrow("Page Read Rate",              rates.pageInRate)
        s += mrow("Page Read I/O Rate",          totalReadOps)
        s += mrow("Page Write Rate",             rates.pageOutRate)
        s += mrow("Page Write I/O Rate",         totalWriteOps)
        s += mrow("Inswap Rate",                 0.0)
        s += mrow("Free List Fault Rate",        rates.reactivationRate)
        s += mrow("Modified List Fault Rate",    rates.pageOutRate)
        s += mrow("Demand Zero Fault Rate",      rates.zeroFillRate)
        s += mrow("System Fault Rate",           rates.copyOnWriteRate)
        s += mrow("Window Turn Rate",            windowTurn)
        return s
    }

    func monitorPage() -> String {
        let vm = host.vmStats()
        let rates = host.vmRates()
        var s = mheader("PAGE MANAGEMENT STATISTICS")
        s += mcolHeader()
        s += mrow("Page Fault Rate",             rates.pageFaultRate)
        s += mrow("Page Read Rate",              rates.pageInRate)
        s += mrow("Page Read I/O Rate",          rates.pageInRate)
        s += mrow("Page Write Rate",             rates.pageOutRate)
        s += mrow("Page Write I/O Rate",         rates.pageOutRate)
        s += mrow("Free List Fault Rate",        rates.reactivationRate)
        s += mrow("Modified List Fault Rate",    rates.pageOutRate)
        s += mrow("Demand Zero Fault Rate",      rates.zeroFillRate)
        s += mrow("Global Valid Fault Rate",     rates.hitRate)
        s += mrow("Wrt In Progress Fault Rate",  0.0)
        s += mrow("System Fault Rate",           rates.copyOnWriteRate)
        s += "\n"
        s += String(format: "%@%11lld pages\n", mlabel("Free List Size"),     vm.freePages)
        s += String(format: "%@%11lld pages\n", mlabel("Modified List Size"), vm.inactivePages)
        return s
    }

    func monitorStates() -> String {
        let cabs = world?.elevators ?? []
        let lef = cabs.filter { $0.doors == .open || $0.doors == .opening }.count + 4
        let hib = cabs.filter { $0.direction == .idle && $0.doors == .closed }.count + 2
        let com = cabs.filter { $0.direction != .idle }.count + 1
        let cur = 1

        // Real MONITOR STATES defaults to a percentage display -- each row is
        // the share of the process population in that scheduler state, titled
        // "PROCESS STATES (%)" with CUR% AVE% MIN% MAX% column heads. Convert
        // the synthetic populations to percentages of the total so the rows
        // sum to ~100 the way the live utility's do.
        let total = Double(max(1, lef + hib + com + cur))
        func pct(_ n: Int) -> Double { Double(n) / total * 100.0 }

        var s = mheader("PROCESS STATES (%)")
        s += mcolHeader(percent: true)
        s += mrowPct("Collided Page Wait",          0.0)
        s += mrowPct("Mutex & Misc Resource Wait",  0.0)
        s += mrowPct("Common Event Flag Wait",      0.0)
        s += mrowPct("Page Fault Wait",             0.0)
        s += mrowPct("Local Event Flag Wait",       pct(lef))
        s += mrowPct("Local Evt Flg (Outswapped)",  0.0)
        s += "\n"
        s += mrowPct("Hibernate",                   pct(hib))
        s += mrowPct("Hibernate (Outswapped)",      0.0)
        s += mrowPct("Suspended",                   0.0)
        s += mrowPct("Suspended (Outswapped)",      0.0)
        s += mrowPct("Free Page Wait",              0.0)
        s += mrowPct("Compute",                     pct(com))
        s += mrowPct("Compute (Outswapped)",        0.0)
        s += mrowPct("Current Process",             pct(cur))
        return s
    }

    func monitorDisk() -> String {
        var s = mheader("DISK I/O STATISTICS")
        s += mcolHeader()
        // Show one row per mounted volume so MONITOR DISK lines up exactly
        // with the device list in SHOW DEVICES. Each volume's rate is
        // pulled from `diskRate(forBSD:)`, which walks up the IORegistry
        // to find the underlying IOBlockStorageDriver -- so an APFS
        // volume mounted on `disk3s3s1` correctly reports the rate of
        // the physical SSD (`disk0`) underneath.
        let volumes = host.mountedVolumes()
        if volumes.isEmpty {
            s += mrow("(no mounted volumes)", 0.0)
            return s
        }
        for (idx, vol) in volumes.enumerated() {
            let opsPerSec: Double
            if let bsd = vol.bsdName, let r = host.diskRate(forBSD: bsd) {
                opsPerSec = r.totalOpsPerSec
            } else {
                opsPerSec = 0.0
            }
            let label = vol.bsdName ?? "?"
            let vmsName = String(format: "_$1$DUA%d: (%@)", idx, label)
            s += mrow(vmsName, opsPerSec)
        }
        return s
    }

    func monitorLock() -> String {
        // The Mach kernel doesn't expose VMS-distributed-lock-manager
        // counters, so we synthesize believable rates anchored to the
        // live VM lookup rate (a per-second figure that genuinely
        // changes refresh-to-refresh) plus a per-row sin oscillation so
        // each lock-rate row drifts independently rather than tracking
        // every other row in lockstep.
        let rates = host.vmRates()
        let t = Date().timeIntervalSinceReferenceDate
        let base = max(0.4, rates.lookupRate / 800.0)
        func wob(_ amp: Double, _ phase: Double) -> Double {
            max(0, amp * base * (1.0 + 0.45 * sin(t / 7.0 + phase)))
        }
        // Cluster lock traffic only happens if there are remote peers.
        let hasPeers = (network?.peers.count ?? 0) > 0
        let netScale = hasPeers ? 1.0 : 0.0

        var s = mheader("LOCK MANAGEMENT STATISTICS")
        s += mcolHeader()
        s += mrow("New ENQ Rate (Local)",          wob(3.2, 0.0))
        s += mrow("Converted ENQ Rate (Local)",    wob(1.05, 1.1))
        s += mrow("DEQ Rate (Local)",              wob(3.18, 2.2))
        s += mrow("Blocking AST Rate (Local)",     wob(0.04, 3.3))
        s += mrow("New ENQ Rate (Incoming)",       netScale * wob(0.6, 4.4))
        s += mrow("Converted ENQ Rate (Incoming)", netScale * wob(0.2, 5.5))
        s += mrow("DEQ Rate (Incoming)",           netScale * wob(0.6, 0.7))
        s += mrow("New ENQ Rate (Outgoing)",       netScale * wob(0.6, 1.8))
        s += mrow("Converted ENQ Rate (Outgoing)", netScale * wob(0.2, 2.9))
        s += mrow("DEQ Rate (Outgoing)",           netScale * wob(0.6, 4.0))
        s += mrow("Blocking AST Rate (Outgoing)",  netScale * wob(0.02, 0.5))
        s += mrow("Dir Function Rate (Incoming)",  netScale * wob(0.04, 1.6))
        s += mrow("Dir Function Rate (Outgoing)",  netScale * wob(0.04, 2.7))
        s += mrow("Deadlock Search Rate",          0.0)
        s += mrow("Deadlock Find Rate",           0.0)
        return s
    }

    func monitorCluster() -> String {
        var s = mheader("CLUSTER STATISTICS")
        // Fixed-width, right-aligned columns shared by the header and every
        // data row. Numeric fields are wide enough to hold large values (a
        // five-figure BIO rate, a busy lock rate) so a wide value can't
        // widen its field and shove every column after it out of alignment
        // -- which is what the old hand-spaced header + `%6.2f` rows did.
        let nodeW = 12
        let colW  = [11, 12, 11, 10, 12]   // CPU / BIO / DIO / Mem / Lock

        func clusterRow(_ node: String, _ cells: [String]) -> String {
            var line = node.padding(toLength: nodeW, withPad: " ", startingAt: 0)
            for (cell, w) in zip(cells, colW) { line += rightPad(cell, width: w) }
            return line + "\n"
        }

        s += clusterRow("Node", ["CPU Busy", "BIO Rate", "DIO Rate", "Mem Use", "Lock Rate"]) + "\n"

        func statCells(_ cpu: Double, _ bio: Double, _ dio: Double, _ mem: Double, _ lock: Double) -> [String] {
            [String(format: "%.2f", cpu), String(format: "%.2f", bio),
             String(format: "%.2f", dio), String(format: "%.1f%%", mem),
             String(format: "%.2f", lock)]
        }

        // Local node: pulled from HostStats directly.
        let local = host.snapshot()
        s += clusterRow(nodeName, statCells(local.cpuBusy, local.bufferedIORate,
                                            local.directIORate, local.memUsedPercent, local.lockRate))
        // Remote nodes: snapshots that peers broadcast every 5s.
        let snapshots = network?.peerStats ?? [:]
        for peer in network?.peers ?? [] {
            let nm = String(peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
            if let snap = snapshots[peer.id] {
                s += clusterRow(nm, statCells(snap.cpuBusy, snap.bufferedIORate,
                                              snap.directIORate, snap.memUsedPercent, snap.lockRate))
            } else {
                // Connected but no snapshot has arrived yet (under 5s old or
                // the peer is a pre-stats build).
                s += clusterRow(nm, Array(repeating: "--", count: colW.count))
            }
        }
        return s
    }

    func monitorFCP() -> String {
        // VMS FCP (Files-11 XQP) counters have no direct Mac equivalent,
        // so the rates are anchored where they make semantic sense to a
        // live host counter -- disk read/write to physicalDiskRates, page
        // faults to vmRates -- and the remaining FCP-only rows oscillate
        // around their baseline so the table looks like a live filesystem.
        let rates = host.vmRates()
        let disks = host.diskRates()
        let totalDiskOps = disks.reduce(0.0) { $0 + $1.totalOpsPerSec }
        let totalDiskRead = disks.reduce(0.0) { $0 + $1.readOpsPerSec }
        let totalDiskWrite = disks.reduce(0.0) { $0 + $1.writeOpsPerSec }
        let t = Date().timeIntervalSinceReferenceDate
        // Cache hit rate sourced from real VM lookups vs hits, falling
        // back to ~93% if the kernel hasn't yet served any lookups.
        let cacheHits: Double
        if rates.lookupRate > 0.1 {
            cacheHits = min(99.5, max(50.0, rates.hitRate * 100.0 / max(1.0, rates.lookupRate)))
        } else {
            cacheHits = 92.0 + sin(t / 9.0) * 3.5
        }
        func osc(_ amp: Double, _ phase: Double) -> Double {
            max(0, amp * (1.0 + 0.35 * sin(t / 6.0 + phase)))
        }
        var s = mheader("FILE PRIMITIVE STATISTICS")
        s += mcolHeader()
        s += mrow("FCP Call Rate",                osc(4.2, 0.0))
        s += mrow("Allocation Rate",              osc(0.4, 1.1))
        s += mrow("Create Rate",                  osc(0.04, 2.2))
        s += mrow("Disk Read Rate",               totalDiskRead)
        s += mrow("Disk Write Rate",              totalDiskWrite)
        s += mrow("Cache Hit Rate",               cacheHits)
        s += mrow("Volume Lock Wait Rate",        osc(0.04, 3.3))
        s += mrow("CPU Tick Rate",                osc(4.2, 4.4) + totalDiskOps * 0.01)
        s += mrow("File Sys Page Fault Rate",     rates.pageFaultRate * 0.0004)
        return s
    }

    /// LPD layered-product monitor utility: shows the live trapezoidal
    /// velocity-profile state for every cab on the dispatcher. Position
    /// is reported in floors (×100 = % between floors), velocity in
    /// floors / sec with a sign for direction, acceleration in floors /
    /// sec² derived from the velocity delta against the previous frame
    /// (so refresh-to-refresh the figure follows the motor command),
    /// target is the next queued floor, and the state column tells you
    /// which segment of the profile the cab is in.
    func monitorDynamics() -> String {
        let now = Date()
        var s = mheader("CAB DYNAMICS (LPD)")
        s += "  Cab     Position    Velocity      Accel       Target   State\n"
        s += "  ---     --------    ----------    --------    ------   -----\n"

        let cabs = world?.sortedElevators ?? []
        if cabs.isEmpty {
            s += "  (no cabs registered)\n"
            return s
        }
        let dt = max(0.001, now.timeIntervalSince(lastDynamicsSampleAt))
        for cab in cabs {
            let dLabel = world?.displayLabel(for: cab) ?? cab.label
            let prevVel = lastDynamicsVelocity[cab.id] ?? cab.velocity
            let accel = (cab.velocity - prevVel) / dt
            lastDynamicsVelocity[cab.id] = cab.velocity
            let targetStr: String
            if let q = cab.queue.first {
                targetStr = String(format: "%6d", q)
            } else {
                targetStr = "    --"
            }
            let state = dynamicsState(for: cab)
            s += String(format: "  %-6@  %7.2f fl   %+6.3f fl/s   %+6.3f     %@   %@\n",
                        dLabel as NSString,
                        cab.position,
                        cab.velocity,
                        accel,
                        targetStr,
                        state)
        }
        lastDynamicsSampleAt = now

        s += "\n"
        s += String(format: "  Profile limits:  PAX  %.2f fl/s  / %.2f fl/s²    FRT  %.2f fl/s  / %.2f fl/s²\n",
                    Sim.paxSpeed, Sim.paxAccel, Sim.freightSpeed, Sim.freightAccel)
        return s
    }

    private func dynamicsState(for cab: Elevator) -> String {
        if cab.doorObstructed { return "OBSTR" }
        if cab.doors == .opening || cab.doors == .closing { return "DOORS" }
        if cab.doors == .open { return "PARKED" }
        if cab.phaseTwoActive { return "PHASE-II" }
        if cab.independentActive { return "INDEP" }
        if cab.brakeEngaged && cab.queue.first != nil { return "BRAKE" }
        guard let target = cab.queue.first else {
            return abs(cab.velocity) > 0.05 ? "STOPPING" : "IDLE"
        }
        let dy = Double(target) - cab.position
        let stoppingDistance = (cab.velocity * cab.velocity) / (2 * cab.profile.travelAccel)
        let cruise = abs(cab.velocity) >= cab.profile.travelFloorsPerSecond * 0.95
        if abs(dy) <= stoppingDistance + 0.05 { return "DECEL" }
        if cruise                              { return "CRUISE" }
        return "ACCEL"
    }
}
