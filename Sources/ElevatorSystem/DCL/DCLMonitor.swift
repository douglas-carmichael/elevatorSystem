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
        refreshLiveDisplay()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveDisplay() }
        }
        liveTimer = t
    }

    /// Stops whichever live-screen mode is active. Ctrl-Y in the DCL window
    /// triggers this.
    func stopMonitor(interrupt: Bool = true) {
        guard liveTimer != nil || liveDisplay != nil else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        let wasTest: Bool
        if case .testUtility = liveMode { wasTest = true } else { wasTest = false }
        liveMode = .none
        liveDisplay = nil
        if interrupt {
            if wasTest {
                transcript += "\n%RUN-I-ABORTED, diagnostic was interrupted by Ctrl/Y\n"
            } else {
                transcript += "\n%MONITOR-I-INTERRUPT, request was interrupted by Ctrl/Y\n"
            }
        }
    }

    func refreshLiveDisplay() {
        let now = Date()
        let elapsed = uptimeString(from: monitorStartedAt, to: now)
        let body = renderMonitor(monitorClass)
        var s = body
        s += "\n" + String(repeating: "-", count: 76) + "\n"
        s += "  From: \(stamp(monitorStartedAt))   To: \(stamp(now))\n"
        s += "  Elapsed: \(elapsed)   Interval: \(Int(monitorIntervalSec))s\n"
        s += "  Press  Ctrl/Y  to interrupt the request and return to the DCL prompt.\n"
        liveDisplay = s
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
        var s = "\n"
        s += "                            \(osTitle) Monitor Utility\n"
        s += centered("+ + + + + + + + + + + + + + \(title) + + + + + + + + + + + + + +") + "\n"
        s += centered("on node \(nodeName)") + "\n"
        s += centered(stamp(Date())) + "\n\n"
        return s
    }

    func mcolHeader() -> String {
        return mlabel("") +
               mvalHeader("CUR") + mvalHeader("AVE") +
               mvalHeader("MIN") + mvalHeader("MAX") + "\n\n"
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
        let vm = host.vmStats()
        let activeMod = Double(vm.activePages % 4096) / 100.0

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
        s += "\n"
        s += mrowi("Process Count",             procCount)
        s += mrow("Page Fault Rate",            activeMod)
        s += mrow("Page Read I/O Rate",         activeMod * 0.05)
        s += mrow("Page Write I/O Rate",        activeMod * 0.01)
        s += mrow("Direct I/O Rate",            12.4 + Double(vm.freePages % 100) / 100.0)
        s += mrow("Buffered I/O Rate",          48.21 + Double(vm.activePages % 100) / 50.0)
        return s
    }

    func monitorModes() -> String {
        let usage = host.cpuUsage()
        let kernel = usage.system * 0.55
        let exec   = usage.system * 0.25
        let super_ = usage.system * 0.15
        let intr   = usage.system * 0.05
        let user   = usage.user + usage.nice

        var s = mheader("TIME IN PROCESSOR MODES")
        s += mcolHeader()
        s += mrow("Interrupt State",            intr)
        s += mrow("MP Synchronization",         0.0)
        s += mrow("Kernel Mode",                kernel)
        s += mrow("Executive Mode",             exec)
        s += mrow("Supervisor Mode",            super_)
        s += mrow("User Mode",                  user)
        s += mrow("Compatibility Mode",         0.0)
        s += mrow("Idle Time",                  usage.idle)
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
        let vm = host.vmStats()
        let pf = Double(vm.activePages % 4096) / 100.0
        var s = mheader("I/O SYSTEM STATISTICS")
        s += mcolHeader()
        s += mrow("Direct I/O Rate",             12.4 + Double(vm.freePages % 100) / 100.0)
        s += mrow("Buffered I/O Rate",           48.21 + Double(vm.activePages % 100) / 50.0)
        s += mrow("Mailbox Write Rate",          4.10)
        s += mrow("Split Transfer Rate",         0.20)
        s += mrow("Log Name Translation Rate",   8.40)
        s += mrow("File Open Rate",              0.40)
        s += mrow("Page Fault Rate",             pf)
        s += mrow("Page Read Rate",              pf * 0.30)
        s += mrow("Page Read I/O Rate",          pf * 0.05)
        s += mrow("Page Write Rate",             pf * 0.10)
        s += mrow("Page Write I/O Rate",         pf * 0.01)
        s += mrow("Inswap Rate",                 0.0)
        s += mrow("Free List Fault Rate",        0.40)
        s += mrow("Modified List Fault Rate",    0.04)
        s += mrow("Demand Zero Fault Rate",      pf * 0.25)
        s += mrow("System Fault Rate",           0.04)
        s += mrow("Window Turn Rate",            0.0)
        return s
    }

    func monitorPage() -> String {
        let vm = host.vmStats()
        let pf = Double(vm.activePages % 4096) / 100.0
        var s = mheader("PAGE MANAGEMENT STATISTICS")
        s += mcolHeader()
        s += mrow("Page Fault Rate",             pf)
        s += mrow("Page Read Rate",              pf * 0.30)
        s += mrow("Page Read I/O Rate",          pf * 0.05)
        s += mrow("Page Write Rate",             pf * 0.10)
        s += mrow("Page Write I/O Rate",         pf * 0.01)
        s += mrow("Free List Fault Rate",        0.40)
        s += mrow("Modified List Fault Rate",    0.04)
        s += mrow("Demand Zero Fault Rate",      pf * 0.25)
        s += mrow("Global Valid Fault Rate",     pf * 0.05)
        s += mrow("Wrt In Progress Fault Rate",  0.0)
        s += mrow("System Fault Rate",           0.04)
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

        var s = mheader("PROCESS STATES")
        s += mcolHeader()
        s += mrowi("Collided Page Wait",          0)
        s += mrowi("Mutex & Misc Resource Wait",  0)
        s += mrowi("Common Event Flag Wait",      0)
        s += mrowi("Page Fault Wait",             0)
        s += mrowi("Local Event Flag Wait",       lef)
        s += mrowi("Local Evt Flg (Outswapped)",  0)
        s += mrowi("Hibernate",                   hib)
        s += mrowi("Hibernate (Outswapped)",      0)
        s += mrowi("Suspended",                   0)
        s += mrowi("Suspended (Outswapped)",      0)
        s += mrowi("Free Page Wait",              0)
        s += mrowi("Compute",                     com)
        s += mrowi("Compute (Outswapped)",        0)
        s += mrowi("Current Process",             1)
        return s
    }

    func monitorDisk() -> String {
        var s = mheader("DISK I/O STATISTICS")
        s += mcolHeader()

        struct D { let name: String; let cur: Double }
        let disks: [D] = [
            D(name: "_$1$DUA0: (CAB$DKA0)",     cur: 12.4),
            D(name: "_$1$DUA1: (CAB$DKA1)",     cur: 3.1),
            D(name: "_$2$DUB0: (DOORS$DKB0)",   cur: 1.2),
            D(name: "_$2$DUB1: (EVTLOG$DKB1)",  cur: 0.8),
        ]
        for d in disks {
            s += mrow(d.name, d.cur)
        }
        return s
    }

    func monitorLock() -> String {
        var s = mheader("LOCK MANAGEMENT STATISTICS")
        s += mcolHeader()
        s += mrow("New ENQ Rate (Local)",         3.21)
        s += mrow("Converted ENQ Rate (Local)",   1.04)
        s += mrow("DEQ Rate (Local)",             3.18)
        s += mrow("Blocking AST Rate (Local)",    0.04)
        s += mrow("New ENQ Rate (Incoming)",      0.0)
        s += mrow("Converted ENQ Rate (Incoming)", 0.0)
        s += mrow("DEQ Rate (Incoming)",          0.0)
        s += mrow("New ENQ Rate (Outgoing)",      0.0)
        s += mrow("Converted ENQ Rate (Outgoing)", 0.0)
        s += mrow("DEQ Rate (Outgoing)",          0.0)
        s += mrow("Blocking AST Rate (Outgoing)", 0.0)
        s += mrow("Dir Function Rate (Incoming)", 0.0)
        s += mrow("Dir Function Rate (Outgoing)", 0.0)
        s += mrow("Deadlock Search Rate",         0.0)
        s += mrow("Deadlock Find Rate",           0.0)
        return s
    }

    func monitorCluster() -> String {
        var s = mheader("CLUSTER STATISTICS")
        s += "Node           CPU Busy    BIO Rate    DIO Rate     Mem Use    Lock Rate\n\n"
        let busy = host.cpuUsage().busy
        let nodePad = nodeName.padding(toLength: 12, withPad: " ", startingAt: 0)
        s += String(format: "%@   %6.2f      %6.2f      %6.2f      %5.1f%%      %6.2f\n",
                    nodePad, busy, 48.21, 12.4,
                    100.0 - (Double(host.vmStats().freePages) * 100.0 / Double(max(1, host.vmStats().totalPages))),
                    4.21)
        for peer in network?.peers ?? [] {
            let nm = String(peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
            let nmPad = nm.padding(toLength: 12, withPad: " ", startingAt: 0)
            s += String(format: "%@   %6.2f      %6.2f      %6.2f      %5.1f%%      %6.2f\n",
                        nmPad, busy * 0.7, 22.10, 8.10, 41.0, 1.10)
        }
        return s
    }

    func monitorFCP() -> String {
        var s = mheader("FILE PRIMITIVE STATISTICS")
        s += mcolHeader()
        s += mrow("FCP Call Rate",                4.21)
        s += mrow("Allocation Rate",              0.40)
        s += mrow("Create Rate",                  0.04)
        s += mrow("Disk Read Rate",               12.41)
        s += mrow("Disk Write Rate",              4.04)
        s += mrow("Cache Hit Rate",               92.81)
        s += mrow("Volume Lock Wait Rate",        0.04)
        s += mrow("CPU Tick Rate",                4.21)
        s += mrow("File Sys Page Fault Rate",     0.40)
        return s
    }
}
