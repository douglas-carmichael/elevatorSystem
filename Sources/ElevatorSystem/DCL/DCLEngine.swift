import Foundation

@MainActor
final class DCLEngine: ObservableObject {
    @Published var transcript: String = ""
    @Published var prompt: String = "$ "
    @Published var loggedOut: Bool = false

    /// When non-nil, the DCL window paints this as a full-screen "terminal"
    /// view, replacing the transcript and prompt. Used by continuous MONITOR
    /// and by the RUN <diagnostic> test utilities.
    @Published var liveDisplay: String? = nil

    private enum LiveMode {
        case none
        case monitor
        case testUtility(name: String, header: String)
    }
    private var liveMode: LiveMode = .none
    private var liveTimer: Timer?

    private var monitorClass: String = "SYSTEM"
    private var monitorIntervalSec: TimeInterval = 3.0
    private var monitorStartedAt: Date = Date()

    // Test utility state
    private var testSteps: [TestStep] = []
    private var testCurrent: Int = 0
    private var testResults: [(label: String, reading: String, status: String)] = []
    private var testStartedAt: Date = Date()
    private struct TestStep {
        let label: String
        let run: () -> (reading: String, status: String)
    }

    private weak var world: ElevatorWorld?
    private weak var network: PeerNetwork?
    private weak var automation: AutoDriver?
    private weak var language: AppLanguage?

    private let host = HostStats.shared
    private let osVersion: String = "V9.2-3"
    private let osTitle: String = "VSI OpenVMS"
    private let username: String
    private let nodeName: String = "ASCEN1"
    private let terminalName: String = "TT$VTA0418:"
    private let pid: String
    private var lastStatus: String = "%X00000001"
    private var lastStatusLabel: String = "SS$_NORMAL"

    // SET DEFAULT state
    private var defaultDevice: String = "ELEVATOR$ROOT:"
    private var defaultDirectory: String       // e.g. "[OPERATOR]"

    // SET TERMINAL state
    private var terminalWidth: Int = 132
    private var terminalPage: Int = 24

    // ASSIGN / DEASSIGN / DEFINE
    private var processLogicals: [String: String] = [:]
    private var symbols: [String: String] = [:]

    // RECALL
    private var history: [String] = []
    private let maxHistory: Int = 254     // VMS default

    // ALLOCATE / DEALLOCATE state
    private var allocatedDevices: Set<String> = []
    // MOUNT / DISMOUNT state -- volume label per mounted device.
    private var mountedVolumes: [String: String] = [:]

    /// Set during SELFTEST so verbs that would normally take over the screen
    /// (RUN <diagnostic>, MONITOR ...) just report what they'd do instead.
    private var dryRun: Bool = false

    private var bootTime: Date { host.bootDate }

    init() {
        let raw = NSUserName()
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        self.username = cleaned.isEmpty ? "OPERATOR" : String(cleaned.prefix(12))
        self.pid = String(format: "%08X", Int.random(in: 0x0000_0400...0x0000_04FF))
        self.defaultDirectory = "[\(self.username)]"
    }

    func attach(world: ElevatorWorld, network: PeerNetwork,
                automation: AutoDriver? = nil, language: AppLanguage? = nil) {
        self.world = world
        self.network = network
        self.automation = automation
        self.language = language
        // Render the banner now that the language reference is available.
        transcript = banner() + lpdSplash()
    }

    /// LPD ELEVATOR-CTRL layered-product splash printed after the OpenVMS
    /// login banner. Real OpenVMS sites typically print these from
    /// SYS$MANAGER:SYLOGIN.COM after the system banner, so the operator sees
    /// which optional product packages are loaded and how to invoke them.
    private func lpdSplash() -> String {
        var s = "\n"
        s += "    " + tr("login.lpd.line1") + "\n"
        s += "    " + tr("login.lpd.line2") + "\n\n"
        s += "    " + tr("login.lpd.brake")  + "\n"
        s += "    " + tr("login.lpd.door")   + "\n"
        s += "    " + tr("login.lpd.weight") + "\n"
        s += "    " + tr("login.lpd.lamp")   + "\n\n"
        s += "    " + tr("login.lpd.help") + "\n\n"
        return s
    }

    /// Translate via the attached AppLanguage, falling back to the raw key if
    /// no language is wired (so SELFTEST still works in unit-style scenarios).
    private func tr(_ key: String) -> String {
        guard let lang = language else { return Strings.lookup(key, lang: .en) }
        return lang.t(key)
    }

    func submit(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        appendPromptEcho(line)
        guard !line.isEmpty else { return }
        if history.last != line {
            history.append(line)
            if history.count > maxHistory { history.removeFirst() }
        }
        let body = execute(line)
        if !body.isEmpty {
            transcript += body
            if !body.hasSuffix("\n") { transcript += "\n" }
        }
    }

    // MARK: -- output framing

    private func banner() -> String {
        let lang = language?.current ?? .en
        func t(_ key: String, _ args: CVarArg...) -> String {
            String(format: Strings.lookup(key, lang: lang), arguments: args)
        }
        var s = "\n"
        s += "            " + t("dcl.banner.welcome", osTitle, osVersion) + "\n"
        s += "                            " + t("dcl.banner.onnode", nodeName) + "\n\n"
        s += "    " + t("dcl.banner.lastinter", stamp(bootTime)) + "\n"
        s += "    " + t("dcl.banner.lastnon", stamp(bootTime.addingTimeInterval(-43200))) + "\n\n"
        s += "    *** " + t("dcl.banner.shelltag", "ELEVATOR$ROOT:[\(username)]") + " ***\n"
        s += "    " + t("dcl.banner.help") + "\n\n"
        return s
    }

    private func appendPromptEcho(_ s: String) {
        transcript += "\(prompt)\(s)\n"
    }

    // MARK: -- parsed line

    private struct Parsed {
        let verb: String
        let positional: [String]
        let qualifiers: [(name: String, value: String?)]

        func hasQualifier(_ name: String, min: Int = 3) -> Bool {
            return qualifiers.contains { matchesPrefix($0.name, name, min: min) }
        }

        func qualifierValue(_ name: String, min: Int = 3) -> String? {
            for q in qualifiers where matchesPrefix(q.name, name, min: min) {
                return q.value
            }
            return nil
        }

        private func matchesPrefix(_ token: String, _ canonical: String, min: Int) -> Bool {
            let t = token.uppercased()
            let c = canonical.uppercased()
            return t.count >= min && c.hasPrefix(t)
        }
    }

    private func parse(_ line: String) -> Parsed {
        // Split on whitespace honoring "double quoted" strings.
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for ch in line {
            if ch == "\"" { inQuote.toggle(); current.append(ch); continue }
            if ch.isWhitespace && !inQuote {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }

        // The verb itself can carry a qualifier: e.g. "DIR/SIZE FOO.TXT"
        // -> first token splits into verb + qualifiers on "/".
        var verb = ""
        var positional: [String] = []
        var qualifiers: [(String, String?)] = []

        for (idx, raw) in tokens.enumerated() {
            if idx == 0 {
                let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                verb = parts[0].uppercased()
                for p in parts.dropFirst() where !p.isEmpty {
                    let (n, v) = splitQual(p)
                    qualifiers.append((n, v))
                }
            } else if raw.hasPrefix("/") {
                let body = String(raw.dropFirst())
                if !body.isEmpty {
                    let (n, v) = splitQual(body)
                    qualifiers.append((n, v))
                }
            } else {
                positional.append(raw)
            }
        }
        return Parsed(verb: verb, positional: positional, qualifiers: qualifiers)
    }

    private func splitQual(_ s: String) -> (String, String?) {
        if let eq = s.firstIndex(of: "=") {
            let n = String(s[..<eq]).uppercased()
            let v = String(s[s.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (n, v)
        }
        return (s.uppercased(), nil)
    }

    // MARK: -- dispatch

    private func execute(_ line: String) -> String {
        let cmd = parse(line)
        let head = cmd.verb
        guard !head.isEmpty else { return "" }

        // Logical-name and symbol indirection: '@file' executes a COM file.
        if head.hasPrefix("@") {
            let file = String(head.dropFirst()).uppercased()
            return execComFile(file)
        }

        succeed()

        switch true {
        case matches(head, "HELP") || head == "?":           return helpText(topic: cmd.positional.first)
        case matches(head, "SHOW"):                           return showCmd(cmd)
        case matches(head, "SET"):                            return setCmd(cmd)
        case matches(head, "DIRECTORY", min: 3):              return directoryCmd(cmd)
        case matches(head, "MONITOR", min: 3):                return monitorCmd(cmd)
        case matches(head, "TYPE"):                           return typeCmd(cmd)
        case matches(head, "WRITE"):                          return writeCmd(cmd)
        case matches(head, "ASSIGN"):                         return assignCmd(cmd)
        case matches(head, "DEFINE"):                         return assignCmd(cmd)   // alias of ASSIGN/PROCESS
        case matches(head, "DEASSIGN"):                       return deassignCmd(cmd)
        case matches(head, "MAIL"):                           return mailCmd()
        case matches(head, "PHONE"):                          return phoneCmd()
        case matches(head, "FINGER", min: 3):                 return fingerCmd(cmd)
        case matches(head, "RECALL", min: 3):                 return recallCmd(cmd)
        case matches(head, "SPAWN"):                          return spawnCmd()
        case matches(head, "ATTACH"):                         return attachCmd()
        case matches(head, "WAIT"):                           return waitCmd(cmd)
        case matches(head, "ACCOUNTING", min: 4):             return accountingCmd()
        case matches(head, "INSTALL", min: 3):                return installCmd()
        case matches(head, "PRODUCT", min: 4):                return productCmd()
        case matches(head, "SEARCH", min: 4):                 return searchCmd(cmd)
        case matches(head, "PRINT"):                          return printCmd(cmd)
        case matches(head, "SUBMIT", min: 3):                 return submitCmd(cmd)
        case matches(head, "CALL"):                           return callCmd(cmd)
        case matches(head, "OPEN"):                           return openCmd(cmd)
        case matches(head, "CLOSE"):                          return closeCmd(cmd)
        case matches(head, "STOP"):                           return stopCmd(cmd)
        case matches(head, "CLEAR"):                          transcript = ""; return ""
        case matches(head, "SELFTEST", min: 4):               return selfTest()
        case matches(head, "LOGOUT") || matches(head, "EXIT"):
            loggedOut = true
            return logoutText(full: cmd.hasQualifier("FULL", min: 1))

        // Operator-level verbs that an elevator-control operator can run.
        case matches(head, "RUN"):                            return runCmd(cmd)
        case matches(head, "ANALYZE", min: 4):                return analyzeCmd(cmd)
        case matches(head, "MOUNT"):                          return mountCmd(cmd)
        case matches(head, "DISMOUNT", min: 4):               return dismountCmd(cmd)
        case matches(head, "BACKUP"):                         return backupCmd(cmd)
        case matches(head, "EXAMINE", min: 4):                return examineCmd(cmd)
        case matches(head, "ALLOCATE", min: 3):               return allocateCmd(cmd)
        case matches(head, "DEALLOCATE", min: 5):             return deallocateCmd(cmd)
        case matches(head, "REPLY"):                          return replyCmd(cmd)
        case matches(head, "REQUEST", min: 4):                return requestCmd(cmd)

        // Genuinely privileged verbs -- correct OpenVMS behaviour for a
        // non-SYSPRV operator account is to refuse with %SYSTEM-F-NOPRIV.
        case matches(head, "INITIALIZE", min: 4):             return noPriv("INITIALIZE")
        case matches(head, "PATCH"):                          return noPriv("PATCH")
        case matches(head, "DEPOSIT", min: 4):                return noPriv("DEPOSIT")

        // File-touching verbs that act like real DCL but always fail with RMS
        case matches(head, "COPY"):                           return rmsFNF("COPY", cmd, op: "COPYIN")
        case matches(head, "DELETE", min: 3):                 return rmsFNF("DELETE", cmd, op: "OPENIN")
        case matches(head, "PURGE", min: 3):                  return rmsFNF("PURGE", cmd, op: "OPENIN")
        case matches(head, "RENAME", min: 3):                 return rmsFNF("RENAME", cmd, op: "OPENIN")
        case matches(head, "APPEND", min: 3):                 return rmsFNF("APPEND", cmd, op: "OPENIN")
        case matches(head, "EDIT"):                           return rmsFNF("EDT", cmd, op: "OPENIN")
        case matches(head, "DIFFERENCES", min: 4):            return rmsFNF("DIFFERENCES", cmd, op: "OPENIN")
        case matches(head, "CREATE", min: 3):                 return createCmd(cmd)
        case matches(head, "CONTINUE", min: 3):               return ""

        default:
            return ivverb(head)
        }
    }

    // MARK: -- SHOW family

    private func showCmd(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else {
            return missQual("SHOW")
        }
        switch true {
        case matches(what, "PROCESS",     min: 4): return showProcess(cmd)
        case matches(what, "SYSTEM",      min: 3): return showSystem()
        case matches(what, "USERS",       min: 4): return showUsers()
        case matches(what, "DEVICES",     min: 3): return showDevices()
        case matches(what, "MEMORY",      min: 3): return showMemory()
        case matches(what, "TIME"):                return showTime()
        case matches(what, "NETWORK",     min: 3): return showNetwork()
        case matches(what, "QUEUE",       min: 4): return showQueue()
        case matches(what, "LOGICAL",     min: 3): return showLogical(cmd)
        case matches(what, "SYMBOL",      min: 3): return showSymbol(cmd)
        case matches(what, "ERROR",       min: 3): return showError()
        case matches(what, "STATUS",      min: 4): return showStatus()
        case matches(what, "LICENSE",     min: 3): return showLicense()
        case matches(what, "CPU"):                 return showCPU()
        case matches(what, "DEFAULT",     min: 3): return showDefault()
        case matches(what, "QUOTA",       min: 4): return showQuota()
        case matches(what, "PROTECTION",  min: 4): return showProtection()
        case matches(what, "TERMINAL",    min: 4): return showTerminal()
        case matches(what, "WORKING_SET", min: 4): return showWorkingSet()
        case matches(what, "VERSION",     min: 3): return showVersion()
        case matches(what, "RMS_DEFAULT", min: 3): return showRMS()
        case matches(what, "INTRUSION",   min: 3): return showIntrusion()
        case matches(what, "CLUSTER",     min: 3): return showCluster()
        case matches(what, "CONNECTIONS", min: 4): return showConnections()
        case matches(what, "AUDIT",       min: 3): return showAudit()
        default:
            fail("DCL-W-IVKEYW", "%X00038088")
            return "%DCL-W-IVKEYW, unrecognized keyword - check validity and spelling\n   \\\(what)\\\n"
        }
    }

    private func showProcess(_ cmd: Parsed) -> String {
        // Layout per VSI OpenVMS DCL Dictionary -- one field per line in the
        // header block, "User Identifier:" with a capital I, UIC formatted
        // [group,member].
        let now = Date()
        let upS = Int(host.uptime())
        var s = "\n\(stamp(now))   User: \(username.padding(toLength: 12, withPad: " ", startingAt: 0))   Process ID:   \(pid)\n"
        s += "                          Node: \(nodeName.padding(toLength: 8, withPad: " ", startingAt: 0))       Process name: \"DCL_\(username)\"\n\n"
        s += "Terminal:            \(terminalName)\n"
        s += "User Identifier:     [ELEVATOR,\(username)]\n"
        s += "Base priority:       4\n"
        s += "Default file spec:   \(defaultDevice)\(defaultDirectory)\n"
        s += "Devices allocated:   none\n\n"
        s += "Process Quotas:\n"
        s += " Account name:                  CONTROL_ROOM\n"
        s += " CPU limit:                     Infinite       Direct I/O limit:      150\n"
        s += " Buffered I/O byte count quota: 65536          Buffered I/O limit:    150\n"
        s += " Timer queue entry quota:       20             Open file quota:       100\n"
        s += " Paging file quota:             50000          Subprocess quota:      8\n"
        s += " Default page fault cluster:    64             AST quota:             250\n"
        s += " Enqueue quota:                 200            Shared file limit:     0\n"
        s += " Max detached processes:        0              Max active jobs:       0\n\n"
        s += "Accounting information:\n"
        s += String(format: " Buffered I/O count:            %-12d  Peak working set size:    1648\n", upS / 4)
        s += String(format: " Direct I/O count:              %-12d  Peak page file size:     20384\n", upS / 8)
        s += String(format: " Page faults:                   %-12d  Mounted volumes:             0\n", upS / 2)
        s += " Images activated:              3\n"
        s += String(format: " Elapsed CPU time:              0 00:%02d:%02d.%02d\n",
                    (upS / 60) % 60, upS % 60, (upS * 7) % 100)
        s += String(format: " Connect time:                  %@\n", uptimeString(from: bootTime, to: now))
        if cmd.hasQualifier("ALL", min: 1) {
            s += "\nProcess rights:\n"
            s += "  INTERACTIVE\n"
            s += "  LOCAL\n"
            s += "  ELEVATOR_OPERATOR\n"
            s += "System rights:\n"
            s += "  SYS$NODE_\(nodeName)\n"
        }
        return s
    }

    private func showSystem() -> String {
        let now = Date()
        let uptime = uptimeString(from: bootTime, to: now)
        let loads = host.loadAverages()
        let procCount = host.processCount()
        var s = "\n\(osTitle) \(osVersion) on node \(nodeName)  \(stamp(now))  Uptime  \(uptime)\n"
        s += String(format: "  Load average: %.2f  %.2f  %.2f    Active processes: %d\n",
                    loads.one, loads.five, loads.fifteen, procCount)
        s += "  Pid    Process Name      State  Pri      I/O       CPU       Page flts Pages\n"
        s += line("00000401", "SWAPPER",          "HIB",   16, 0,     "0 00:00:01.21",         0,     0)
        s += line("00000402", "NULL",             "COM",    0, 0,     "3 00:00:00.00",         0,     0)
        s += line("00000403", "ELEVATOR_CTL",     "LEF",    8, 4823,  "0 00:01:32.14",      1842,  3104)
        s += line("00000404", "DISPATCH",         "LEF",    7, 2204,  "0 00:00:48.21",       412,  1480)
        s += line("00000405", "HALL_CALL_MGR",    "LEF",    6, 1187,  "0 00:00:24.04",       284,   720)
        s += line("00000406", "DOOR_SVC",         "LEF",    6,  942,  "0 00:00:18.42",       212,   612)
        s += line("00000407", "BRAKE_MON",        "HIB",    7,   84,  "0 00:00:02.18",        48,   180)
        s += line("00000408", "WEIGHT_MON",       "HIB",    6,   62,  "0 00:00:01.42",        38,   148)
        s += line("00000409", "LOGGER",           "LEF",    4,  208,  "0 00:00:04.81",        72,   246)

        let cabs = world?.elevators ?? []
        for (i, cab) in cabs.prefix(6).enumerated() {
            let cabPid = String(format: "%08X", 0x040A + i)
            let name = String(format: "CAB_%@_TASK", cab.label).padding(toLength: 16, withPad: " ", startingAt: 0)
            let state = cab.doors == .open ? "LEF" : (cab.direction == .idle ? "HIB" : "COM")
            let io = 800 + (i * 47)
            let cpu = String(format: "0 00:00:%02d.%02d", 12 + i, (i * 17 + 9) % 100)
            let faults = 320 + (i * 18)
            let pages = 610 + i * 8
            s += "\(cabPid) \(name) \(state)     6   \(String(format: "%6d", io))   \(cpu)       \(String(format: "%3d", faults))   \(String(format: "%4d", pages))\n"
        }
        s += line("00000414", "COMM_NETSRV",      "LEF",    6, 612,   "0 00:00:08.71",       412, 1024)
        s += line("00000415", "BONJOUR_PUBSRV",   "LEF",    6, 144,   "0 00:00:01.95",       108,  384)
        s += line("00000416", "MAINT_AGENT",      "HIB",    4,  72,   "0 00:00:00.94",        36,  158)
        s += "\(pid) DCL_\(username.padding(toLength: 12, withPad: " ", startingAt: 0).prefix(12)) CUR     4       21   0 00:00:00.18        24   148\n"
        return s
    }

    private func line(_ pid: String, _ name: String, _ state: String, _ pri: Int, _ io: Int, _ cpu: String, _ faults: Int, _ pages: Int) -> String {
        let padName = name.padding(toLength: 16, withPad: " ", startingAt: 0)
        return "\(pid) \(padName) \(state)    \(String(format: "%2d", pri))   \(String(format: "%6d", io))   \(cpu)       \(String(format: "%4d", faults))  \(String(format: "%4d", pages))\n"
    }

    private func showUsers() -> String {
        // Real DCL header is "OpenVMS User Processes at <stamp>" (no arch
        // qualifier in the title) with a 2-space indent on data rows.
        var s = "\n       OpenVMS User Processes at \(stamp(Date()))\n"
        s += "       Total number of users = \(1 + (network?.peers.count ?? 0)), number of processes = \((world?.elevators.count ?? 0) + 4)\n\n"
        s += "  Username     Process Name        PID    Terminal\n"
        s += "  \(username.padding(toLength: 12, withPad: " ", startingAt: 0)) DCL_\(username.prefix(12).padding(toLength: 16, withPad: " ", startingAt: 0)) \(pid) \(terminalName)\n"
        for (i, peer) in (network?.peers ?? []).enumerated() {
            let upper = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
            let uname = String(upper.prefix(12)).padding(toLength: 12, withPad: " ", startingAt: 0)
            let pname = ("DCL_" + upper.prefix(12)).padding(toLength: 16, withPad: " ", startingAt: 0)
            let ppid = String(format: "%08X", 0x0500 + i)
            s += "  \(uname) \(pname) \(ppid) TT$NTA00\(i + 1):\n"
        }
        return s
    }

    private func showDevices() -> String {
        var s = "\nDevice                  Device           Error    Volume         Free  Trans Mnt\n"
        s += " Name                   Status           Count     Label         Blocks Count Cnt\n"
        s += "CAB$DKA0:               Mounted              0  ELEV_SYS         18742    44   1\n"
        s += "CAB$DKA1:               Mounted              0  ELEV_DATA        92188    12   1\n"
        s += "DOORS$DKB0:             Mounted              2  ELEV_DOORS        4928     8   1\n"
        s += "EVENTLOG$DKB1:          Mounted              0  ELEV_LOGS        24441     1   1\n"
        s += "NET$EBA0:               Online               0      (none)            -     -   -\n"
        s += "BONJOUR$EBA1:           Online               0      (none)            -     -   -\n"
        s += "\(terminalName)             Online               0      (none)            -     -   -\n"
        return s
    }

    private func showMemory() -> String {
        // Real host VM stats projected onto the OpenVMS display. VSI
        // OpenVMS on x86_64 means modern memory sizes are plausible here.
        let vm = host.vmStats()
        let totalMb = Double(host.physicalMemoryBytes) / (1024.0 * 1024.0)
        let procCount = host.processCount()
        let resident = max(1, procCount - 8)

        var s = "\n                System Memory Resources on \(stamp(Date()))\n\n"
        s += "Physical Memory Usage (pages):     Total       Free      In Use     Modified\n"
        s += String(format: "  Main Memory (%8.2fMb)      %8llu   %8llu    %8llu     %8llu\n",
                    totalMb, vm.totalPages, vm.freePages, vm.inUsePages, vm.modifiedPages)
        s += "\nSlot Usage (slots):                Total       Free   Resident      Swapped\n"
        s += String(format: "  Process Entry Slots             %4d       %4d       %4d            0\n",
                    max(procCount + 32, 160), 32, procCount)
        s += String(format: "  Balance Set Slots               %4d       %4d       %4d            0\n",
                    max(resident + 18, 140), 18, resident)
        s += "\nDynamic Memory Usage (bytes):      Total       Free    In Use      Largest\n"
        s += "  Non-Paged Dynamic Memory        524288      94216    430072        18432\n"
        s += "  Paged Dynamic Memory            262144      72488    189656        12104\n\n"
        s += "Paging File Usage (pages):     Free  Reservable      Total\n"
        s += "  DISK$ELEV_SYS:[SYS0.SYSEXE]PAGEFILE.SYS\n"
        s += String(format: "                              %8llu    %8llu   %8llu\n",
                    vm.freePages, vm.freePages + vm.inactivePages, vm.totalPages)
        return s
    }

    private func showTime() -> String {
        return "  \(stamp(Date()))\n"
    }

    private func showNetwork() -> String {
        var s = "\n  Node     State            Active Links   Delay   Cost   Hops  Name\n"
        s += "  -----    -----            ------------   -----   ----   ----  ----\n"
        s += "  1.1      LOCAL                       2       0      0      0  \(nodeName)\n"
        if let peers = network?.peers, !peers.isEmpty {
            for (i, peer) in peers.enumerated() {
                let addr = "1.\(2 + i)"
                let upper = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
                let nm = String(upper.prefix(6))
                s += "  \(addr.padding(toLength: 8, withPad: " ", startingAt: 0)) REACHABLE                1       \(2 + i)      1      1  \(nm)\n"
            }
        } else {
            s += "  -        -                        -       -      -      -  (no adjacent nodes)\n"
        }
        return s
    }

    private func showQueue() -> String {
        let cabs = world?.elevators ?? []
        var s = "\nPending floor calls -- \(stamp(Date()))\n\n"
        s += "Cab    Owner      Mode   Floor  Direction  Doors    Queue\n"
        s += "---    -----      ----   -----  ---------  -----    -----\n"
        for cab in cabs {
            let owner = (world?.canControl(cab) ?? false) ? "LOCAL" : "REMOTE"
            let mode  = cab.automatic ? "AUTO" : "MAN."
            let floor = String(format: "%5d", cab.displayFloor)
            let dir   = (cab.direction == .up ? "UP" :
                          cab.direction == .down ? "DOWN" : "---").padding(toLength: 9, withPad: " ", startingAt: 0)
            let doors = String(describing: cab.doors).uppercased().padding(toLength: 8, withPad: " ", startingAt: 0)
            let queue = cab.queue.isEmpty ? "(empty)" : cab.queue.map(String.init).joined(separator: " > ")
            s += "\(cab.label.padding(toLength: 6, withPad: " ", startingAt: 0)) \(owner.padding(toLength: 10, withPad: " ", startingAt: 0)) \(mode.padding(toLength: 6, withPad: " ", startingAt: 0)) \(floor)  \(dir)  \(doors) \(queue)\n"
        }
        if cabs.isEmpty { s += "  (no cabs registered)\n" }
        return s
    }

    private func showLogical(_ cmd: Parsed) -> String {
        // /PROCESS shows just the process table; default lists everything.
        let procOnly = cmd.hasQualifier("PROCESS", min: 4)
        var s = "\n"
        if !procOnly {
            s += "(LNM$SYSTEM_TABLE)\n"
            s += "  \"ELEVATOR$ROOT\"             = \"DISK$ELEV_SYS:[ELEVATOR]\"\n"
            s += "  \"CAB$DATA\"                  = \"DISK$ELEV_DATA:[CABS]\"\n"
            s += "  \"DOOR$STATE\"                = \"DISK$ELEV_DOORS:[STATE]\"\n"
            s += "  \"BONJOUR$REGISTRY\"          = \"_ELEVATORSYS._TCP.LOCAL.\"\n"
            s += "  \"SYS$NODE\"                  = \"\(nodeName)::\"\n"
            s += "  \"SYS$LOGIN\"                 = \"ELEVATOR$ROOT:[\(username)]\"\n"
            s += "  \"SYS$SYSDEVICE\"             = \"DISK$ELEV_SYS:\"\n"
            s += "  \"SYS$DISK\"                  = \"\(defaultDevice)\"\n"
        }
        s += "\n(LNM$PROCESS_TABLE)\n"
        s += "  \"SYS$COMMAND\"                = \"\(terminalName)\"\n"
        s += "  \"SYS$INPUT\"                  = \"\(terminalName)\"\n"
        s += "  \"SYS$OUTPUT\"                 = \"\(terminalName)\"\n"
        s += "  \"SYS$ERROR\"                  = \"\(terminalName)\"\n"
        for key in processLogicals.keys.sorted() {
            let padded = ("\"" + key + "\"").padding(toLength: 28, withPad: " ", startingAt: 0)
            s += "  \(padded) = \"\(processLogicals[key] ?? "")\"\n"
        }
        return s
    }

    private func showSymbol(_ cmd: Parsed) -> String {
        if let name = cmd.positional.dropFirst().first {
            let key = name.uppercased()
            // DCL built-in symbols: $STATUS, $SEVERITY, $RESTART
            if let builtin = builtinSymbol(key) {
                return "  \(key) = \"\(builtin)\"\n"
            }
            if let v = symbols[key] {
                return "  \(key) = \"\(v)\"\n"
            }
            fail("DCL-W-UNDSYM", "%X00038150")
            return "%DCL-W-UNDSYM, undefined symbol - check validity and spelling\n"
        }
        if symbols.isEmpty {
            return "  (no local or global symbols defined)\n"
        }
        var s = "\n"
        for k in symbols.keys.sorted() {
            s += "  \(k) = \"\(symbols[k] ?? "")\"\n"
        }
        return s
    }

    /// DCL exposes a few read-only built-in symbols every shell sees.
    private func builtinSymbol(_ name: String) -> String? {
        switch name {
        case "$STATUS":   return lastStatus
        case "$SEVERITY":
            // Severity is the low 3 bits of the status code (0=W, 1=S, 2=E, 3=I, 4=F).
            let parsed = UInt32(lastStatus.replacingOccurrences(of: "%X", with: ""), radix: 16) ?? 1
            return String(parsed & 0x7)
        case "$RESTART":  return "FALSE"
        case "$PID":      return pid
        case "$PROCESS":  return "DCL_\(username)"
        default:          return nil
        }
    }

    private func showError() -> String {
        let baseSeq = 4870 + Int.random(in: 0...12)
        var s = "\nERROR LOG SUMMARY -- last 5 entries\n"
        s += "   Sequence  Date / Time             Source           Code           Detail\n"
        s += "   ---------+------------------------+----------------+--------------+-----------------------------------\n"
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-2400)))  CAB_03_DOORS     %X0000002C     DOOR SVC TIMEOUT, retried (success)\n", baseSeq + 0)
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-1820)))  COMM_NETSRV      %X00000018     PEER UNREACHABLE: ASCEN3::ROOM3\n", baseSeq + 11)
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-1100)))  CAB_01_BRAKE     %X00000004     INFO: routine brake test PASS\n", baseSeq + 20)
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-220)))  DOOR_SVC_03      %X00000040     PAGE FAULT FLOOD, throttling\n", baseSeq + 31)
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-12)))  BONJOUR_PUBSRV   %X00000001     SS$_NORMAL, service re-announced\n", baseSeq + 40)
        return s
    }

    private func showStatus() -> String {
        // Real DCL SHOW STATUS prints a one-line accounting summary for the
        // current process. The "last command status" is exposed via the
        // built-in symbols $STATUS / $SEVERITY -- see SHOW SYMBOL $STATUS.
        let upS = Int(host.uptime())
        var s = "\n  Status on \(stamp(Date()))\n"
        s += String(format: "  Elapsed CPU: 0 00:%02d:%02d.%02d   Buf I/O: %-6d   Dir I/O: %-6d   Page faults: %-6d\n",
                    (upS / 60) % 60, upS % 60, (upS * 7) % 100,
                    upS / 4, upS / 8, upS / 2)
        s += "  Connect time: \(uptimeString(from: bootTime, to: Date()))\n"
        return s
    }

    private func showLicense() -> String {
        // VSI OpenVMS x86_64 license tags (verbatim names from the VSI PAK
        // catalogue: OPENVMS-X86, DECNET-PLUS, NMS-NM).
        var s = "\nActive licenses on \(nodeName) (\(osTitle) \(osVersion)):\n\n"
        s += "OPENVMS-X86          Active            (loaded)\n"
        s += "DECNET-PLUS          Active            (loaded)\n"
        s += "LPD-DIAG             Active            (loaded)\n"
        s += "BONJOUR-PROXY        Active            (loaded)\n"
        return s
    }

    private func showCPU() -> String {
        // VSI OpenVMS x86_64 reports the host CPU. We show real Mach
        // host_statistics CPU usage plus the actual processor model so the
        // display matches what `MONITOR MODES` would print on a real install.
        let now = Date()
        let usage = host.cpuUsage()
        let kernel = usage.system * 0.55
        let exec   = usage.system * 0.25
        let super_ = usage.system * 0.15
        let intr   = usage.system * 0.05

        let freqLabel: String
        if host.cpuFrequencyMHz > 0 {
            freqLabel = "\(host.cpuFrequencyMHz) MHz"
        } else {
            freqLabel = "host clock"
        }
        let cores = "\(host.activeProcessorCount) of \(host.processorCount) processors online"

        var s = "\n  CPU 0  (\(freqLabel))  -- \(stamp(now))\n"
        s += "    Model:     \(host.cpuModel)\n"
        s += "    Mode:      Multiprocessing primary\n"
        s += "    State:     Run   [\(cores)]\n"
        s += String(format: "    Idle:      %5.2f%%\n", usage.idle)
        s += String(format: "    Kernel:    %5.2f%%\n", kernel)
        s += String(format: "    Exec:      %5.2f%%\n", exec)
        s += String(format: "    Super:     %5.2f%%\n", super_)
        s += String(format: "    User:      %5.2f%%\n", usage.user + usage.nice)
        s += String(format: "    Interrupt: %5.2f%%\n", intr)
        return s
    }

    private func showDefault() -> String {
        return "  \(defaultDevice)\(defaultDirectory)\n"
    }

    private func showQuota() -> String {
        // Real DCL: "User [grp,member] has N blocks used, M available,
        //   of K authorized and permitted overdraft of P blocks on DEV:"
        let used = 15000, authorized = 65000
        let available = authorized - used
        let overdraft = 1000
        var s = "\nUser [ELEVATOR,\(username)] has \(used) blocks used, \(available) available,\n"
        s += "   of \(authorized) authorized and permitted overdraft of \(overdraft) blocks on \(defaultDevice)\n"
        return s
    }

    private func showProtection() -> String {
        // Real DCL prints just the protection mask line, no banner.
        return "  SYSTEM=RWED, OWNER=RWED, GROUP=RE, WORLD=NO ACCESS\n"
    }

    private func showTerminal() -> String {
        var s = "\nTerminal:  \(terminalName)        Device_Type: VT100         Owner: \(username)\n\n"
        s += "Input:    9600  LFfill: 0  Width: \(terminalWidth)  Parity: None\n"
        s += "Output:   9600  CRfill: 0  Page:  \(terminalPage)\n\n"
        s += "Terminal Characteristics:\n"
        s += "  Interactive    Echo            Type_ahead     No Escape\n"
        s += "  No Hostsync    TTsync          Lowercase      Tab\n"
        s += "  Wrap           Scope           No Remote      Eightbit\n"
        s += "  Broadcast      No Readsync     No Form        Fulldup\n"
        s += "  No Modem       No Local_echo   No Autobaud    Hangup\n"
        s += "  No Brdcstmbx   No DMA          No Altypeahd   Set_speed\n"
        s += "  No Commsync    Line Editing    Overstrike editing            Smooth Scroll\n"
        s += "  No Fallback    No Dialup       No Secure server\n"
        s += "  No Disconnect  No Pasthru      No Syspassword                No SIXEL Graphics\n"
        s += "  No Soft Characters             No Printer Port               Numeric Keypad\n"
        s += "  ANSI_CRT       Edit_mode       DEC_CRT        DEC_CRT2      DEC_CRT3\n"
        s += "  Advanced_video Block_mode      No Regis       No Printer\n"
        return s
    }

    private func showWorkingSet() -> String {
        var s = "\nWorking Set     /Limit=\(2048)  /Quota=\(8192)  /Extent=\(16384)\n"
        s += "Adjustment enabled    Authorized Quota=\(8192)   Authorized Extent=\(16384)\n"
        return s
    }

    private func showVersion() -> String {
        // Real DCL emits the bare title + version line.
        return "\n\(osTitle) \(osVersion)\n"
    }

    private func showRMS() -> String {
        var s = "\nRMS_DEFAULT process values:\n"
        s += "  Multiblock count:        16        Multibuffer counts:\n"
        s += "                                       Indexed:  0    Relative:  0\n"
        s += "                                       Sequential: 0  Network:   0\n"
        s += "  Prolog level:             0        Extend quantity:        0\n"
        s += "  Block count:             32        Buffer count:           4\n"
        return s
    }

    private func showIntrusion() -> String {
        // Real DCL header per Marc's VMS reference:
        //   Intrusion   Type      Count    Expiration    Source
        var s = "\nIntrusion   Type      Count    Expiration    Source\n"
        s += "   (no intrusion records found)\n"
        return s
    }

    private func showCluster() -> String {
        var s = "\n              View of Cluster from system ID 1025  node: \(nodeName)\n"
        s += "+-----------------------------+\n"
        s += "|        SYSTEMS              |\n"
        s += "|   NODE     SOFTWARE     STATUS\n"
        s += "+-----------------------------+\n"
        s += "|  \(nodeName.padding(toLength: 8, withPad: " ", startingAt: 0))  VMS V\(osVersion.dropFirst())   MEMBER\n"
        if let peers = network?.peers {
            for peer in peers {
                let nm = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
                s += "|  \(String(nm).padding(toLength: 8, withPad: " ", startingAt: 0))  VMS V\(osVersion.dropFirst())   MEMBER\n"
            }
        }
        s += "+-----------------------------+\n"
        return s
    }

    private func showConnections() -> String {
        var s = "\nLogical Link  Node      Process       Remote link  Remote user\n"
        s += "============  ====      =======       ===========  ===========\n"
        if let peers = network?.peers, !peers.isEmpty {
            for (i, peer) in peers.enumerated() {
                let nm = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
                let nodePad = ("\(nm)::").padding(toLength: 9, withPad: " ", startingAt: 0)
                let procPad = "BONJOUR_PROXY".padding(toLength: 13, withPad: " ", startingAt: 0)
                s += String(format: "%-13d %@ %@ %-12d %@\n",
                            32768 + i, nodePad, procPad,
                            32768 + i + 1, "_ELEVATORSYS")
            }
        } else {
            s += "       (no active links)\n"
        }
        return s
    }

    private func showAudit() -> String {
        return "\nSystem security audit characteristics:\n  Security alarm failure mode = NONE\n  Security audit failure mode = NONE\n  (no recent audit events)\n"
    }

    // MARK: -- SET family

    private func setCmd(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else { return missQual("SET") }
        switch true {
        case matches(what, "DEFAULT", min: 3):  return setDefault(cmd)
        case matches(what, "TERMINAL", min: 4): return setTerminal(cmd)
        case matches(what, "PROMPT", min: 3):   return setPrompt(cmd)
        case matches(what, "ON"):               return ""
        case matches(what, "NOON", min: 3):     return ""
        case matches(what, "VERIFY", min: 3):   return ""
        case matches(what, "NOVERIFY", min: 3): return ""
        case matches(what, "PASSWORD", min: 4): return setPassword()
        case matches(what, "PROCESS", min: 4):  return setProcess(cmd)
        case matches(what, "CAB"):              return setCab(cmd)
        default:
            return noPriv("SET \(what)")
        }
    }

    private func setDefault(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.dropFirst().first else { return missQual("SET DEFAULT") }
        // Accept: DEVICE:[DIR] | [DIR] | [-]   simple validation only
        var dev = defaultDevice
        var dir = defaultDirectory

        var spec = target
        if let colon = spec.firstIndex(of: ":") {
            dev = String(spec[...colon]).uppercased()
            spec = String(spec[spec.index(after: colon)...])
        }
        if !spec.isEmpty {
            if spec == "[-]" {
                // Pop the trailing component of [a.b.c]
                if dir.hasPrefix("[") && dir.hasSuffix("]") {
                    var inner = String(dir.dropFirst().dropLast())
                    if let dot = inner.lastIndex(of: ".") {
                        inner = String(inner[..<dot])
                        dir = "[\(inner)]"
                    } else {
                        dir = "[000000]"
                    }
                }
            } else if spec.hasPrefix("[.") {
                let extra = String(spec.dropFirst(2).dropLast())
                let inner = dir.dropFirst().dropLast()
                dir = "[\(inner).\(extra)]"
            } else if spec.hasPrefix("[") {
                dir = spec.uppercased()
            } else {
                fail("DCL-W-IVKEYW", "%X00038088")
                return "%DCL-W-IVKEYW, unrecognized keyword - check validity and spelling\n"
            }
        }
        defaultDevice = dev
        defaultDirectory = dir
        return ""
    }

    private func setTerminal(_ cmd: Parsed) -> String {
        if let w = cmd.qualifierValue("WIDTH"), let n = Int(w) { terminalWidth = n }
        if let p = cmd.qualifierValue("PAGE"),  let n = Int(p) { terminalPage = n }
        return ""
    }

    private func setPrompt(_ cmd: Parsed) -> String {
        if let v = cmd.qualifiers.first(where: { $0.value != nil })?.value {
            prompt = v.replacingOccurrences(of: "\"", with: "") + " "
            return ""
        }
        if let v = cmd.positional.dropFirst().first {
            prompt = v.replacingOccurrences(of: "\"", with: "") + " "
            return ""
        }
        prompt = "$ "
        return ""
    }

    private func setPassword() -> String {
        return "%SET-W-NOTSET, error modifying \(username)\n-SYSTEM-F-NOPRIV, insufficient privilege\n"
    }

    private func setProcess(_ cmd: Parsed) -> String {
        if cmd.hasQualifier("PRIORITY", min: 3) || cmd.hasQualifier("NAME", min: 3) {
            return noPriv("SET PROCESS")
        }
        return ""
    }

    private func setCab(_ cmd: Parsed) -> String {
        // SET CAB <label> /MANUAL  or  SET CAB <label> /AUTO[MATIC]
        guard let label = cmd.positional.dropFirst().first else {
            return "%SET-W-MISSCAB, missing cab identifier\n"
        }
        guard let world else {
            return "%SYSTEM-F-NOWORLD, elevator world not attached\n"
        }
        guard let cab = findCab(label: label, in: world) else {
            fail("SET-W-NOSUCHCAB", "%X000080A4")
            return "%SET-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        guard world.canControl(cab) else {
            return "%SET-W-REMOTE, cab \(cab.label) is owned by a remote node\n"
        }
        guard let auto = automation else {
            return "%SET-F-NOAUTO, automation subsystem not running\n"
        }
        if cmd.hasQualifier("MANUAL", min: 3) {
            let was = auto.isAutomatic(cabId: cab.id)
            auto.takeManualControl(cabId: cab.id)
            if was {
                return "%SET-I-CABMAN, cab \(cab.label) released from auto-dispatch -- MANUAL CONTROL\n"
            } else {
                return "%SET-I-NOCHG, cab \(cab.label) was already under manual control\n"
            }
        }
        if cmd.hasQualifier("AUTOMATIC", min: 4) || cmd.hasQualifier("AUTO", min: 4) {
            let was = auto.isAutomatic(cabId: cab.id)
            auto.returnToAutomatic(cabId: cab.id)
            if !was {
                return "%SET-I-CABAUTO, cab \(cab.label) returned to auto-dispatch\n"
            } else {
                return "%SET-I-NOCHG, cab \(cab.label) was already under auto-dispatch\n"
            }
        }
        return "%SET-W-MISSQUAL, /MANUAL or /AUTOMATIC required for SET CAB\n"
    }

    // MARK: -- Cab control verbs

    private func callCmd(_ cmd: Parsed) -> String {
        // CALL CAB <label> FLOOR <n>      (or CALL <label> <n>)
        var args = cmd.positional
        if args.first?.uppercased() == "CAB" { args.removeFirst() }
        guard args.count >= 2 else {
            return "%CALL-W-MISSPARM, usage: CALL CAB <label> FLOOR <n>\n"
        }
        let label = args[0]
        var floorTok = args[1]
        if args.count >= 3 && args[1].uppercased().hasPrefix("FLOOR") { floorTok = args[2] }
        guard let floor = Int(floorTok) else {
            return "%CALL-W-IVFLOOR, invalid floor \\\(floorTok)\\\n"
        }
        guard floor >= Sim.firstFloor && floor <= Sim.lastFloor else {
            return "%CALL-W-FLOORRNG, floor must be \(Sim.firstFloor)..\(Sim.lastFloor)\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, elevator world not attached\n" }
        guard let cab = findCab(label: label, in: world) else {
            return "%CALL-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        guard world.canControl(cab) else {
            return "%CALL-W-REMOTE, cab \(cab.label) is owned by a remote node\n"
        }
        _ = world.mutateLocal(cab.id) { e in e.enqueue(floor: floor) }
        return "%CALL-S-QUEUED, cab \(cab.label) queued for floor \(floor)\n"
    }

    private func openCmd(_ cmd: Parsed) -> String {
        // OPEN CAB <label>
        var args = cmd.positional
        if args.first?.uppercased() == "CAB" { args.removeFirst() }
        guard let label = args.first else {
            return "%OPEN-W-MISSPARM, usage: OPEN CAB <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, elevator world not attached\n" }
        guard let cab = findCab(label: label, in: world) else {
            return "%OPEN-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        guard world.canControl(cab) else { return "%OPEN-W-REMOTE, cab \(cab.label) is remote\n" }
        _ = world.mutateLocal(cab.id) { e in e.requestDoorsOpen() }
        return "%OPEN-S-DOOR, cab \(cab.label) doors opening\n"
    }

    private func closeCmd(_ cmd: Parsed) -> String {
        var args = cmd.positional
        if args.first?.uppercased() == "CAB" { args.removeFirst() }
        guard let label = args.first else {
            return "%CLOSE-W-MISSPARM, usage: CLOSE CAB <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, elevator world not attached\n" }
        guard let cab = findCab(label: label, in: world) else {
            return "%CLOSE-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        guard world.canControl(cab) else { return "%CLOSE-W-REMOTE, cab \(cab.label) is remote\n" }
        _ = world.mutateLocal(cab.id) { e in e.requestDoorsClose() }
        return "%CLOSE-S-DOOR, cab \(cab.label) doors closing\n"
    }

    private func stopCmd(_ cmd: Parsed) -> String {
        // STOP CAB <label>      -- clear pending queue (emergency stop)
        var args = cmd.positional
        if args.first?.uppercased() == "CAB" { args.removeFirst() }
        guard let label = args.first else {
            return "%STOP-W-MISSPARM, usage: STOP CAB <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, elevator world not attached\n" }
        guard let cab = findCab(label: label, in: world) else {
            return "%STOP-W-NOSUCHCAB, no such cab \\\(label)\\\n"
        }
        guard world.canControl(cab) else { return "%STOP-W-REMOTE, cab \(cab.label) is remote\n" }
        let n = cab.queue.count
        _ = world.mutateLocal(cab.id) { e in e.queue.removeAll() }
        return "%STOP-S-CLEARED, cab \(cab.label) queue cleared (\(n) call\(n == 1 ? "" : "s") aborted)\n"
    }

    // MARK: -- File-ish verbs

    private func directoryCmd(_ cmd: Parsed) -> String {
        // Real DCL DIRECTORY layout:
        //   Directory DEV:[DIR]
        //   FILENAME.EXT;ver  [used/allocated]  [DD-MMM-YYYY HH:MM:SS.cc]
        //   Total of N files, U/A blocks.
        // Default form is name-only; /SIZE adds blocks; /DATE adds timestamps.
        let withSize = cmd.hasQualifier("SIZE", min: 3) || cmd.hasQualifier("FULL",  min: 3)
        let withDate = cmd.hasQualifier("DATE", min: 3) || cmd.hasQualifier("FULL",  min: 3)

        struct Entry { let name: String; let used: Int; let alloc: Int; let when: Date }
        let files: [Entry] = [
            Entry(name: "CONTROL.EXE;42",  used: 128, alloc: 128, when: bootTime),
            Entry(name: "DOORS.EXE;19",    used:  42, alloc:  48, when: bootTime.addingTimeInterval(2)),
            Entry(name: "SCHED.EXE;7",     used:  18, alloc:  24, when: bootTime.addingTimeInterval(4)),
            Entry(name: "STARTUP.COM;3",   used:   4, alloc:   8, when: bootTime.addingTimeInterval(-2)),
            Entry(name: "EVENTLOG.LOG;91", used: 822, alloc: 824, when: Date().addingTimeInterval(-60)),
            Entry(name: "PEERS.DAT;14",    used:   6, alloc:   8, when: Date()),
        ]

        var s = "\nDirectory \(defaultDevice)\(defaultDirectory)\n\n"
        for f in files {
            var line = f.name.padding(toLength: 22, withPad: " ", startingAt: 0)
            if withSize {
                line += String(format: "%4d/%-4d  ", f.used, f.alloc)
            }
            if withDate {
                line += stamp(f.when)
            }
            s += line + "\n"
        }
        let totalU = files.reduce(0) { $0 + $1.used  }
        let totalA = files.reduce(0) { $0 + $1.alloc }
        if withSize {
            s += "\nTotal of \(files.count) files, \(totalU)/\(totalA) blocks.\n"
        } else {
            s += "\nTotal of \(files.count) files.\n"
        }
        return s
    }

    private func typeCmd(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.first else {
            return "%DCL-W-MISSPRM, missing required parameter on TYPE\n"
        }
        let key = target.uppercased()
        if key.contains("STARTUP") {
            var s = "\n$ ! ELEVATOR$ROOT:[CONTROL]STARTUP.COM\n"
            s += "$ ! Boot-time initialization for the elevator controller cluster\n"
            s += "$ SET NOON\n"
            s += "$ DEFINE/SYSTEM ELEVATOR$ROOT  DISK$ELEV_SYS:[ELEVATOR]\n"
            s += "$ DEFINE/SYSTEM CAB$DATA       DISK$ELEV_DATA:[CABS]\n"
            s += "$ DEFINE/SYSTEM DOOR$STATE     DISK$ELEV_DOORS:[STATE]\n"
            s += "$ RUN/DETACHED ELEVATOR$ROOT:[CONTROL]CONTROL.EXE -\n"
            s += "$       /PROCESS_NAME=ELEVATOR_CTL  /PRIORITY=8\n"
            s += "$ RUN/DETACHED ELEVATOR$ROOT:[CONTROL]DOORS.EXE -\n"
            s += "$       /PROCESS_NAME=DOOR_SVC      /PRIORITY=6\n"
            s += "$ INSTALL ADD ELEVATOR$ROOT:[CONTROL]CONTROL.EXE /OPEN/SHARED\n"
            s += "$ EXIT\n"
            return s
        }
        if key.contains("EVENTLOG") {
            var s = "\n"
            for off in stride(from: 600, to: 0, by: -90) {
                s += "\(stamp(Date().addingTimeInterval(-Double(off))))  CAB_01_TASK     INFO   floor reached, doors opening\n"
                s += "\(stamp(Date().addingTimeInterval(-Double(off - 30))))  DOOR_SVC_01     INFO   doors fully open, dwell timer armed\n"
            }
            return s
        }
        if key.contains("PEERS") {
            return "%TYPE-W-NOTASCII, file \(target) does not contain ASCII data\n"
        }
        fail("RMS-E-FNF", "%X00018292")
        return "%TYPE-W-OPENIN, error opening \(defaultDevice)\(defaultDirectory)\(target) as input\n-RMS-E-FNF, file not found\n"
    }

    private func writeCmd(_ cmd: Parsed) -> String {
        // WRITE SYS$OUTPUT "literal"
        guard cmd.positional.count >= 2 else {
            return "%DCL-W-MISSPRM, missing required parameter on WRITE\n"
        }
        let dest = cmd.positional[0].uppercased()
        let payload = cmd.positional.dropFirst().joined(separator: " ")
        let cleaned = payload.replacingOccurrences(of: "\"", with: "")
        if dest.hasSuffix("SYS$OUTPUT") || dest == "SYS$OUTPUT" || dest == "SYS$ERROR" {
            return cleaned + "\n"
        }
        return "%WRITE-F-WRITERR, file \(dest) is not opened for output\n"
    }

    // MARK: -- ASSIGN / DEASSIGN / DEFINE

    private func assignCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%DCL-W-MISSPRM, missing required parameter on ASSIGN\n"
        }
        // ASSIGN  equiv  logical-name           (DEC order)
        // DEFINE  logical-name  equiv           (also DEC order)
        // For DEFINE the order is name, equiv; for ASSIGN it is equiv, name.
        let isDefine = cmd.verb == "DEFINE" || matches(cmd.verb, "DEFINE")
        let name: String
        let equiv: String
        if isDefine {
            name = cmd.positional[0].uppercased()
            equiv = cmd.positional[1]
        } else {
            equiv = cmd.positional[0]
            name = cmd.positional[1].uppercased()
        }
        processLogicals[name] = equiv
        return ""
    }

    private func deassignCmd(_ cmd: Parsed) -> String {
        guard let name = cmd.positional.first?.uppercased() else {
            return "%DCL-W-MISSPRM, missing required parameter on DEASSIGN\n"
        }
        if processLogicals.removeValue(forKey: name) != nil {
            return ""
        }
        fail("SYSTEM-F-NOLOGNAM", "%X0000020A")
        return "%SYSTEM-F-NOLOGNAM, no logical name match\n"
    }

    // MARK: -- Communication-ish verbs

    private func mailCmd() -> String {
        var s = "\n        \(osTitle) Personal Mail Utility\n"
        s += "        \(stamp(Date()))\n\n"
        s += "You have no new messages.\n"
        s += "MAIL>EXIT\n"
        return s
    }

    private func phoneCmd() -> String {
        return "%PHONE-W-NOTAVAIL, phone facility is not enabled on this node\n"
    }

    private func fingerCmd(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.first else {
            // Default: list everyone
            var s = "\nUser            Personal Name                    Job Type\n"
            s += "\(username.padding(toLength: 16, withPad: " ", startingAt: 0))Console operator                Interactive\n"
            for peer in network?.peers ?? [] {
                let upper = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
                let nm = String(upper.prefix(12)).padding(toLength: 16, withPad: " ", startingAt: 0)
                s += "\(nm)Remote elevator peer            DECnet\n"
            }
            return s
        }
        return "\n  \(target.uppercased())          (no further information available)\n"
    }

    private func recallCmd(_ cmd: Parsed) -> String {
        if cmd.hasQualifier("ALL", min: 1) || cmd.hasQualifier("ERASE", min: 3) {
            if cmd.hasQualifier("ERASE", min: 3) {
                history.removeAll()
                return ""
            }
            var s = "\n"
            for (i, h) in history.enumerated() {
                s += String(format: "  %3d  %@\n", i + 1, h)
            }
            if history.isEmpty { s += "  (no commands in recall buffer)\n" }
            return s
        }
        if let n = cmd.positional.first, let idx = Int(n) {
            let one = idx - 1
            if one >= 0 && one < history.count {
                return "  \(history[one])\n"
            }
            return "%RECALL-W-NOMATCH, no command matches recall request\n"
        }
        if let last = history.dropLast().last {
            return "  \(last)\n"
        }
        return "%RECALL-W-NOMATCH, no command matches recall request\n"
    }

    private func spawnCmd() -> String {
        return "%DCL-E-OPENIN, error opening SYS$INPUT as input\n-DCL-E-NOSUBPROC, subprocess facility unavailable in this shell\n"
    }

    private func attachCmd() -> String {
        return "%DCL-W-ATTNOPAR, no parent process to attach to\n"
    }

    private func waitCmd(_ cmd: Parsed) -> String {
        // WAIT 00:00:nn -- no-op (we don't actually block)
        return ""
    }

    private func accountingCmd() -> String {
        let upS = Int(host.uptime())
        var s = "\nFrom: \(stamp(bootTime))    To: \(stamp(Date()))\n\n"
        s += "                          Image      CPU         Direct    Buffered\n"
        s += "Account     Username     Activations Time         I/O        I/O\n"
        s += "----------  ------------ ----------- -----------  --------   --------\n"
        let userPad = username.padding(toLength: 12, withPad: " ", startingAt: 0)
        s += String(format: "CONTROL_RM  %@     %5d     0 00:%02d:%02d   %7d   %7d\n",
                    userPad, max(1, upS / 600), (upS / 60) % 60, upS % 60, upS / 4, upS / 8)
        return s
    }

    private func installCmd() -> String {
        var s = "\nDISK$ELEV_SYS:<SYS0.SYSCOMMON.SYSEXE>.EXE\n"
        s += "  CONTROL.EXE;42                   Open Hdr Shar Lnkbl\n"
        s += "  DOORS.EXE;19                     Open Hdr Shar Lnkbl\n"
        s += "  SCHED.EXE;7                      Open Hdr Shar Lnkbl\n"
        return s
    }

    private func productCmd() -> String {
        var s = "\n----------------------------------- ----------- --------- --------\n"
        s += "PRODUCT                              KIT TYPE   STATE     RELEASE\n"
        s += "----------------------------------- ----------- --------- --------\n"
        s += "VSI OPENVMS                          Full LP    Installed \(osVersion)\n"
        s += "VSI OPENVMS DECNET-PLUS              Full LP    Installed \(osVersion)\n"
        s += "LPD LPD-DIAG                         Full LP    Installed V1.4\n"
        s += "----------------------------------- ----------- --------- --------\n"
        return s
    }

    private func searchCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%SEARCH-F-NOFILES, no files specified\n"
        }
        let file = cmd.positional[0]
        return "%SEARCH-I-NOMATCHES, no strings matched in \(defaultDevice)\(defaultDirectory)\(file)\n"
    }

    private func printCmd(_ cmd: Parsed) -> String {
        guard let file = cmd.positional.first else {
            return "%PRINT-F-NOPARM, missing parameter on PRINT\n"
        }
        let job = Int.random(in: 1000...9999)
        return "Job \(file) (queue SYS$PRINT, entry \(job)) holding\n"
    }

    private func submitCmd(_ cmd: Parsed) -> String {
        guard let file = cmd.positional.first else {
            return "%SUBMIT-F-NOPARM, missing parameter on SUBMIT\n"
        }
        let job = Int.random(in: 1000...9999)
        return "Job \(file) (queue SYS$BATCH, entry \(job)) pending\n"
    }

    private func createCmd(_ cmd: Parsed) -> String {
        guard let file = cmd.positional.first else {
            return "%CREATE-F-NOPARM, missing parameter on CREATE\n"
        }
        return "%CREATE-I-CREATED, \(defaultDevice)\(defaultDirectory)\(file);1 created (1 block allocated)\n"
    }

    // MARK: -- Operator-level verbs (formerly NOPRIV stubs)

    /// ALLOCATE -- claim a device for the current process. The operator can
    /// allocate user-class devices (tape, scratch disks, terminals); system
    /// devices stay protected.
    private func allocateCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%ALLOC-F-NODEV, no device specified\n"
        }
        let dev = normalizeDevice(raw)
        if isSystemDevice(dev) {
            return noPriv("ALLOCATE \(dev)")
        }
        if allocatedDevices.contains(dev) {
            return "%ALLOC-W-ALLOCATED, _\(nodeName)$\(dev) already allocated\n"
        }
        allocatedDevices.insert(dev)
        return "%ALLOC-S-ALLOC, _\(nodeName)$\(dev) allocated\n"
    }

    /// DEALLOCATE -- release a device the operator previously allocated.
    private func deallocateCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            // DEALLOCATE/ALL with no parameter releases everything.
            if cmd.hasQualifier("ALL", min: 1) {
                let n = allocatedDevices.count
                allocatedDevices.removeAll()
                return "%DEALLOC-S-DEALLOC, \(n) device\(n == 1 ? "" : "s") deallocated\n"
            }
            return "%DEALLOC-F-NODEV, no device specified\n"
        }
        let dev = normalizeDevice(raw)
        if allocatedDevices.remove(dev) != nil {
            return "%DEALLOC-S-DEALLOC, _\(nodeName)$\(dev) deallocated\n"
        }
        return "%DEALLOC-W-NOTALLOC, _\(nodeName)$\(dev) was not allocated to this process\n"
    }

    /// MOUNT -- attach a volume to a device. Operators routinely mount
    /// scratch and backup volumes during a maintenance window.
    private func mountCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%MOUNT-F-NODEV, no device specified\n"
        }
        let dev = normalizeDevice(raw)
        if isSystemDevice(dev) {
            return noPriv("MOUNT \(dev)")
        }
        let label = cmd.positional.count > 1 ? cmd.positional[1].uppercased()
                                              : (cmd.qualifierValue("VOLUME") ?? "SCRATCH")
        if mountedVolumes[dev] != nil {
            return "%MOUNT-W-MOUNTED, _\(nodeName)$\(dev) is already mounted\n"
        }
        mountedVolumes[dev] = label
        return "%MOUNT-I-MOUNTED, \(label) mounted on _\(nodeName)$\(dev)\n"
    }

    /// DISMOUNT -- detach a previously mounted volume.
    private func dismountCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%DISMNT-F-NODEV, no device specified\n"
        }
        let dev = normalizeDevice(raw)
        if mountedVolumes.removeValue(forKey: dev) != nil {
            return "%DISMNT-I-DISMOUNT, _\(nodeName)$\(dev) dismounted\n"
        }
        return "%DISMNT-W-NOTMNT, _\(nodeName)$\(dev) was not mounted\n"
    }

    /// BACKUP -- copy a save-set. Output mimics real OpenVMS BACKUP /VERIFY
    /// which prints an IDENT banner, per-file lines (we summarise), then the
    /// CREATED success message.
    private func backupCmd(_ cmd: Parsed) -> String {
        guard cmd.positional.count >= 2 else {
            return "%BACKUP-F-NOSPEC, missing input or output specification\n"
        }
        let src = cmd.positional[0]
        let dst = cmd.positional[1]
        let now = Date()
        var s = "%BACKUP-I-IDENT, OpenVMS BACKUP V9.2-3 \(stamp(now))\n"
        s += "%BACKUP-I-STARTVERIFY, starting verification pass\n"
        s += "%BACKUP-S-CREATED, save set \(dst) created\n"
        s += "%BACKUP-S-COPIED, copied \(Int.random(in: 6...14)) files in \(Int.random(in: 800...2400)) blocks from \(src)\n"
        s += "%BACKUP-I-PROCDONE, operation completed\n"
        return s
    }

    /// ANALYZE -- routes to ANALYZE/ERROR_LOG, ANALYZE/AUDIT, or NOPRIV for
    /// the privileged variants (ANALYZE/IMAGE, ANALYZE/CRASH_DUMP).
    private func analyzeCmd(_ cmd: Parsed) -> String {
        if cmd.hasQualifier("ERROR_LOG", min: 4) || cmd.hasQualifier("ERROR", min: 4) {
            return showError()
        }
        if cmd.hasQualifier("AUDIT", min: 3) {
            return showAudit()
        }
        if cmd.hasQualifier("IMAGE", min: 3) || cmd.hasQualifier("CRASH_DUMP", min: 5) {
            return noPriv("ANALYZE\(cmd.hasQualifier("IMAGE", min: 3) ? "/IMAGE" : "/CRASH_DUMP")")
        }
        return "%ANALYZE-W-NOQUAL, ANALYZE requires /ERROR_LOG, /AUDIT, /IMAGE, or /CRASH_DUMP\n"
    }

    /// RUN -- execute an image. The operator account can run a small set of
    /// installed diagnostic images; arbitrary images come back NOPRIV. The
    /// known diagnostics open a full-screen VT-style test utility window.
    private func runCmd(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.first?.uppercased() else {
            return "%RUN-F-NOIMG, no image specified\n"
        }
        let stripped = target.hasSuffix(".EXE") ? String(target.dropLast(4)) : target
        let knownDiagnostic: Bool
        switch stripped {
        case "BRAKE_TEST", "DOOR_TEST", "WEIGHT_CAL", "HALL_LAMP_TEST":
            knownDiagnostic = true
        default:
            knownDiagnostic = false
        }
        if !knownDiagnostic { return noPriv("RUN \(target)") }
        if dryRun {
            return "%RUN-S-PROC_ID, would launch \(stripped) test utility (dry-run)\n"
        }
        switch stripped {
        case "BRAKE_TEST":      startBrakeTest()
        case "DOOR_TEST":       startDoorTest()
        case "WEIGHT_CAL":      startWeightCal()
        case "HALL_LAMP_TEST":  startHallLampTest()
        default: break
        }
        return ""
    }

    // MARK: -- Test utility engine

    private func startTestUtility(name: String, header: String, steps: [TestStep]) {
        liveTimer?.invalidate()
        liveMode = .testUtility(name: name, header: header)
        testSteps = steps
        testCurrent = 0
        testResults = []
        testStartedAt = Date()
        refreshTestDisplay(complete: false)
        let t = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTestUtility() }
        }
        liveTimer = t
    }

    private func tickTestUtility() {
        guard testCurrent < testSteps.count else {
            // All steps done -- stop the timer but leave the screen up so
            // the operator can read the final report. Ctrl-Y dismisses.
            liveTimer?.invalidate()
            liveTimer = nil
            refreshTestDisplay(complete: true)
            return
        }
        let step = testSteps[testCurrent]
        let result = step.run()
        testResults.append((step.label, result.reading, result.status))
        testCurrent += 1
        refreshTestDisplay(complete: testCurrent >= testSteps.count)
    }

    private func refreshTestDisplay(complete: Bool) {
        guard case let .testUtility(name, header) = liveMode else { return }
        let width = 78
        let now = Date()

        func boxLine(_ inner: String) -> String {
            let pad = max(0, width - 2 - inner.count)
            return "│" + inner + String(repeating: " ", count: pad) + "│\n"
        }
        func sep(left: String, right: String) -> String {
            return left + String(repeating: "─", count: width - 2) + right + "\n"
        }
        func centered(_ s: String) -> String {
            let pad = max(0, (width - 2 - s.count) / 2)
            return String(repeating: " ", count: pad) + s
        }

        // Localised words (resolved fresh on every refresh so Lang changes
        // mid-test repaint immediately on the next tick).
        let suiteTitle  = tr("diag.suite") + "    VSI OpenVMS " + osVersion
        let operatorLbl = tr("diag.operator")
        let startedLbl  = tr("diag.started")
        let elapsedLbl  = tr("diag.elapsed")
        let runningWord = tr("diag.status.running")
        let queuedWord  = tr("diag.status.queued")
        let abortHint   = tr("diag.abort.hint")
        let exitHint    = tr("diag.exit.hint")

        let innerWidth = width - 2

        var s = ""
        s += sep(left: "┌", right: "┐")
        s += boxLine(centered(suiteTitle))
        s += boxLine(centered("\(name)    \(operatorLbl): \(username)"))
        s += boxLine(centered("\(startedLbl): \(stamp(testStartedAt))"))
        s += sep(left: "├", right: "┤")
        s += boxLine("")
        s += boxLine("  " + header)
        s += boxLine("")

        for (i, step) in testSteps.enumerated() {
            let label = step.label.padding(toLength: 42, withPad: " ", startingAt: 0)
            let reading: String
            let status: String
            if i < testResults.count {
                reading = testResults[i].reading.padding(toLength: 14, withPad: " ", startingAt: 0)
                status  = testResults[i].status
            } else if i == testCurrent && !complete {
                reading = "....".padding(toLength: 14, withPad: " ", startingAt: 0)
                status  = runningWord
            } else {
                reading = "".padding(toLength: 14, withPad: " ", startingAt: 0)
                status  = queuedWord
            }
            s += boxLine("  " + label + reading + " " + status)
        }

        s += boxLine("")
        s += sep(left: "├", right: "┤")

        let elapsed = uptimeString(from: testStartedAt, to: now)
        let passWord = tr("diag.status.pass")
        let okWord   = tr("diag.status.ok")
        if complete {
            let allGood = testResults.allSatisfy {
                $0.status == passWord || $0.status == okWord
            }
            let resultLbl = allGood ? tr("diag.allpass") : tr("diag.seeresults")
            let completeLbl = String(format: tr("diag.complete"), testResults.count, testSteps.count)
            s += boxLine("  \(completeLbl)  \(elapsedLbl) \(elapsed)  \(resultLbl)")
            let hintPad = max(0, innerWidth - exitHint.count)
            s += boxLine(String(repeating: " ", count: hintPad) + exitHint)
        } else {
            let stepLbl = String(format: tr("diag.step.of"), testCurrent + 1, testSteps.count)
            s += boxLine("  \(stepLbl)  \(elapsedLbl) \(elapsed)")
            let hintPad = max(0, innerWidth - abortHint.count)
            s += boxLine(String(repeating: " ", count: hintPad) + abortHint)
        }
        s += sep(left: "└", right: "┘")
        liveDisplay = s
    }

    // MARK: -- Diagnostic step lists

    private func startBrakeTest() {
        let pass = tr("diag.status.pass")
        let cabs = (world?.elevators.map(\.label).sorted()) ?? ["01","02","03"]
        var steps: [TestStep] = []
        for label in cabs {
            steps.append(TestStep(label: String(format: tr("diag.step.brake.cab"), label)) {
                let kn = 11.7 + Double((Int(label) ?? 1) % 4) * 0.18
                return (String(format: "%.1f kN", kn), pass)
            })
        }
        steps.append(TestStep(label: tr("diag.step.brake.fw")) {
            return ("v3.04 OK", pass)
        })
        startTestUtility(name: tr("diag.test.brake"),
                         header: tr("diag.col.cab"),
                         steps: steps)
    }

    private func startDoorTest() {
        let pass = tr("diag.status.pass")
        let cabs = (world?.elevators.map(\.label).sorted()) ?? ["01","02","03"]
        var steps: [TestStep] = []
        for label in cabs {
            steps.append(TestStep(label: String(format: tr("diag.step.door.cycle"), label)) {
                return (String(format: "%.2f s", 1.30 + Double((Int(label) ?? 1) % 5) * 0.05), pass)
            })
        }
        for label in cabs {
            steps.append(TestStep(label: String(format: tr("diag.step.door.obst"), label)) {
                return ("trip @ 12mm", pass)
            })
        }
        startTestUtility(name: tr("diag.test.door"),
                         header: tr("diag.col.cab"),
                         steps: steps)
    }

    private func startWeightCal() {
        let pass = tr("diag.status.pass")
        let ok   = tr("diag.status.ok")
        let cabs = (world?.elevators.map(\.label).sorted()) ?? ["01","02","03"]
        var steps: [TestStep] = []
        for label in cabs {
            steps.append(TestStep(label: String(format: tr("diag.step.weight.zero"), label)) {
                return (String(format: "%.2f kg", Double((Int(label) ?? 1) % 7) * 0.01), pass)
            })
            steps.append(TestStep(label: String(format: tr("diag.step.weight.span"), label)) {
                return ("1.00 ratio", pass)
            })
        }
        steps.append(TestStep(label: tr("diag.step.weight.write")) {
            return ("\(cabs.count * 2) records", ok)
        })
        startTestUtility(name: tr("diag.test.weight"),
                         header: tr("diag.col.cab"),
                         steps: steps)
    }

    private func startHallLampTest() {
        let pass = tr("diag.status.pass")
        var steps: [TestStep] = []
        for floor in Sim.firstFloor...Sim.lastFloor {
            let f = String(format: "%02d", floor)
            steps.append(TestStep(label: String(format: tr("diag.step.lamp.floor"), f)) {
                return ("cycled", pass)
            })
        }
        steps.append(TestStep(label: tr("diag.step.lamp.fw")) {
            return ("v1.18 OK", pass)
        })
        startTestUtility(name: tr("diag.test.lamp"),
                         header: tr("diag.col.floor"),
                         steps: steps)
    }

    /// EXAMINE -- read a memory location. Real OpenVMS lets unprivileged
    /// processes EXAMINE their own P0/P1 space; we always show a synthesised
    /// hex word so the output is well-formed.
    private func examineCmd(_ cmd: Parsed) -> String {
        guard let raw = cmd.positional.first else {
            return "%EXAMINE-F-NOLOC, no address specified\n"
        }
        let addr: UInt64
        let trimmed = raw.uppercased().replacingOccurrences(of: "^X", with: "")
        if let v = UInt64(trimmed, radix: 16) {
            addr = v
        } else if let v = UInt64(trimmed) {
            addr = v
        } else {
            return "%EXAMINE-W-IVADDR, invalid address \\\(raw)\\\n"
        }
        // Synthesised contents -- deterministic hash of the address so the
        // value stays the same across re-EXAMINEs of the same location.
        let v = (addr &* 0x9E3779B1) ^ 0xDEADBEEF
        return String(format: "  %08llX:  %08llX\n", addr, v & 0xFFFFFFFF)
    }

    /// REPLY -- send a one-line message back to a user / operator console.
    /// Operators can REPLY to user requests; the message is dropped into the
    /// OPER0 mailbox.
    private func replyCmd(_ cmd: Parsed) -> String {
        let msg = cmd.positional.joined(separator: " ").replacingOccurrences(of: "\"", with: "")
        if msg.isEmpty {
            return "%REPLY-F-NOMSG, no message text specified\n"
        }
        return "%REPLY-S-REPLIED, reply queued to OPER0:  \"\(msg)\"\n"
    }

    /// REQUEST -- ask the operator queue for assistance. Logged into
    /// OPCOM's operator log.
    private func requestCmd(_ cmd: Parsed) -> String {
        let msg = cmd.positional.joined(separator: " ").replacingOccurrences(of: "\"", with: "")
        if msg.isEmpty {
            return "%REQUEST-F-NOMSG, no message text specified\n"
        }
        return "%OPCOM-I-LOGGED, request from \(username) at \(stamp(Date())) -- \"\(msg)\"\n"
    }

    // MARK: -- helpers for operator verbs

    /// Strips a leading "_NODE$" prefix and trailing colon variants so user
    /// input like "MUA0", "MUA0:", "_ASCEN1$MUA0:" all map to the same key.
    private func normalizeDevice(_ raw: String) -> String {
        var s = raw.uppercased()
        if let dollar = s.firstIndex(of: "$") {
            s = String(s[s.index(after: dollar)...])
        }
        if !s.hasSuffix(":") { s += ":" }
        return s
    }

    /// System / production volumes the operator account cannot allocate.
    private func isSystemDevice(_ dev: String) -> Bool {
        return dev.hasPrefix("DK") || dev.hasPrefix("CAB$DK") || dev.hasPrefix("EVENTLOG$") ||
               dev.contains("SYS")
    }

    // MARK: -- COM file invocation

    private func execComFile(_ file: String) -> String {
        if file.contains("STARTUP") {
            return typeCmd(Parsed(verb: "TYPE", positional: ["STARTUP.COM"], qualifiers: []))
        }
        fail("RMS-E-FNF", "%X00018292")
        return "%DCL-E-OPENIN, error opening \(file) as input\n-RMS-E-FNF, file not found\n"
    }

    // MARK: -- MONITOR  (layout per OpenVMS Monitor Utility Reference Manual)

    private func monitorCmd(_ cmd: Parsed) -> String {
        let cls: String = cmd.positional.first.map { resolveMonitorClass($0) } ?? "SYSTEM"
        var interval: TimeInterval = 3.0   // OpenVMS default
        if let raw = cmd.qualifierValue("INTERVAL"), let n = Double(raw), n >= 1 {
            interval = n
        }
        if dryRun {
            return "%MONITOR-S-START, would start MONITOR \(cls) /INTERVAL=\(Int(interval)) (dry-run)\n"
        }
        startMonitor(class: cls, interval: interval)
        // No transcript output; the live overlay takes over the screen.
        return ""
    }

    private func resolveMonitorClass(_ what: String) -> String {
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

    private func renderMonitor(_ cls: String) -> String {
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

    /// Stops whichever live-screen mode is active (continuous MONITOR or a
    /// running test utility). Pressing Ctrl-Y in the DCL window calls this.
    /// Prints the OpenVMS-style interrupt message to the transcript when
    /// the user actually intervened.
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

    private func refreshLiveDisplay() {
        let now = Date()
        let elapsed = uptimeString(from: monitorStartedAt, to: now)
        let body = renderMonitor(monitorClass)
        var s = body
        // Status line at the bottom -- mimics the "From: ... To: ..." footer
        // shown by real MONITOR plus the interrupt hint.
        s += "\n" + String(repeating: "-", count: 76) + "\n"
        s += "  From: \(stamp(monitorStartedAt))   To: \(stamp(now))\n"
        s += "  Elapsed: \(elapsed)   Interval: \(Int(monitorIntervalSec))s\n"
        s += "  Press  Ctrl/Y  to interrupt the request and return to the DCL prompt.\n"
        liveDisplay = s
    }

    /// Deterministic jitter so AVE / MIN / MAX move with CUR but stay stable
    /// from one redraw to the next.
    private func mjitter(_ cur: Double) -> (ave: Double, min: Double, max: Double) {
        let ave = cur * 0.94
        let lo  = max(0.0, cur * 0.42)
        let hi  = cur * 1.62
        return (ave, lo, hi)
    }

    private func mjitteri(_ cur: Int) -> (ave: Int, min: Int, max: Int) {
        let ave = max(0, Int(Double(cur) * 0.94))
        let lo  = max(0, Int(Double(cur) * 0.65))
        let hi  = Int(Double(cur) * 1.32) + 1
        return (ave, lo, hi)
    }

    private func mheader(_ title: String) -> String {
        // Centered banner. Real MONITOR underlines the title with a single
        // line; we use the "+ + + TITLE + + +" form documented in the manual.
        var s = "\n"
        s += "                            \(osTitle) Monitor Utility\n"
        s += centered("+ + + + + + + + + + + + + + \(title) + + + + + + + + + + + + + +") + "\n"
        s += centered("on node \(nodeName)") + "\n"
        s += centered(stamp(Date())) + "\n\n"
        return s
    }

    private func mcolHeader() -> String {
        return mlabel("") +
               mvalHeader("CUR") + mvalHeader("AVE") +
               mvalHeader("MIN") + mvalHeader("MAX") + "\n\n"
    }

    private func mlabel(_ s: String) -> String {
        return s.padding(toLength: 32, withPad: " ", startingAt: 0)
    }

    private func mvalHeader(_ s: String) -> String {
        return rightPad(s, width: 11)
    }

    private func mrow(_ label: String, _ cur: Double) -> String {
        let j = mjitter(cur)
        return String(format: "%@%11.2f%11.2f%11.2f%11.2f\n",
                      mlabel(label), cur, j.ave, j.min, j.max)
    }

    private func mrowi(_ label: String, _ cur: Int) -> String {
        let j = mjitteri(cur)
        return String(format: "%@%11d%11d%11d%11d\n",
                      mlabel(label), cur, j.ave, j.min, j.max)
    }

    private func centered(_ s: String, width: Int = 80) -> String {
        let pad = max(0, (width - s.count) / 2)
        return String(repeating: " ", count: pad) + s
    }

    private func rightPad(_ s: String, width: Int) -> String {
        let need = max(0, width - s.count)
        return String(repeating: " ", count: need) + s
    }

    // MONITOR SYSTEM -- combines mode breakdown with rates and a process count.
    private func monitorSystem() -> String {
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

    // MONITOR MODES -- only the CPU mode breakdown.
    private func monitorModes() -> String {
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

    // MONITOR PROCESSES /TOPCPU -- horizontal bar chart 0..100%
    private func monitorProcesses() -> String {
        let usage = host.cpuUsage()
        var rows: [(pid: String, name: String, pct: Double, state: String)] = []
        rows.append(("00000403", "ELEVATOR_CTL",   max(2.0, usage.busy * 0.42), "LEF"))
        for (i, cab) in (world?.elevators ?? []).prefix(6).enumerated() {
            let pid = String(format: "%08X", 0x0404 + i)
            let pct = max(0.5, min(40.0, Double((i * 7 + Int(usage.busy)) % 35)))
            let st  = cab.direction == .idle ? "HIB" : "COM"
            rows.append((pid, "CAB_\(cab.label)_TASK", pct, st))
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

    // MONITOR I/O -- I/O subsystem rates.
    private func monitorIO() -> String {
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

    // MONITOR PAGE -- page management statistics.
    private func monitorPage() -> String {
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

    // MONITOR STATES -- process state counts.
    private func monitorStates() -> String {
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

    // MONITOR DISK -- per-disk operation rates.
    private func monitorDisk() -> String {
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

    // MONITOR LOCK -- distributed lock manager rates.
    private func monitorLock() -> String {
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

    // MONITOR CLUSTER -- per-node summary line.
    private func monitorCluster() -> String {
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

    // MONITOR FCP -- Files-11 XQP rates.
    private func monitorFCP() -> String {
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

    // MARK: -- error / status helpers

    private func ivverb(_ verb: String) -> String {
        fail("DCL-W-IVVERB", "%X00038090")
        return "%DCL-W-IVVERB, unrecognized command verb - check validity and spelling\n   \\\(verb)\\\n"
    }

    private func missQual(_ verb: String) -> String {
        fail("DCL-W-MISSQUAL", "%X00038108")
        return "%DCL-W-MISSQUAL, missing qualifier or keyword on \(verb)\n"
    }

    private func noPriv(_ verb: String) -> String {
        fail("SYSTEM-F-NOPRIV", "%X0000056C")
        return "%SYSTEM-F-NOPRIV, insufficient privilege to execute \(verb)\n"
    }

    private func rmsFNF(_ facility: String, _ cmd: Parsed, op: String) -> String {
        let target = cmd.positional.first ?? "FILE.LIS"
        fail("RMS-E-FNF", "%X00018292")
        return "%\(facility)-E-\(op), error opening \(defaultDevice)\(defaultDirectory)\(target) as input\n-RMS-E-FNF, file not found\n"
    }

    private func succeed() {
        lastStatus = "%X00000001"
        lastStatusLabel = "SS$_NORMAL"
    }

    private func fail(_ label: String, _ code: String) {
        lastStatus = code
        lastStatusLabel = label
    }

    // MARK: -- LOGOUT / HELP

    private func logoutText(full: Bool) -> String {
        var s = "\n  \(username)       logged out at \(stamp(Date()))\n"
        if full {
            let upS = Int(host.uptime())
            s += "\n  Accounting information:\n"
            s += String(format: "  Buffered I/O count:            %d        Peak working set size:    1648\n", upS / 4)
            s += String(format: "  Direct I/O count:              %d        Peak page file size:     20384\n", upS / 8)
            s += String(format: "  Page faults:                   %d        Mounted volumes:             0\n", upS / 2)
            s += "  Images activated:              3\n"
            s += String(format: "  Elapsed CPU time:              0 00:%02d:%02d.%02d\n",
                        (upS / 60) % 60, upS % 60, (upS * 7) % 100)
            s += String(format: "  Connect time:                  %@\n", uptimeString(from: bootTime, to: Date()))
        }
        return s
    }

    private func helpText(topic: String?) -> String {
        if let t = topic {
            return helpTopic(t)
        }
        var s = "\n  HELP topic\n  ---- -----\n"
        s += "Available topics:\n\n"
        s += "  ACCOUNTING    ALLOCATE      ANALYZE       APPEND        ASSIGN\n"
        s += "  ATTACH        BACKUP        CALL          CLEAR         CLOSE\n"
        s += "  CONTINUE      COPY          CREATE        DEALLOCATE    DEASSIGN\n"
        s += "  DEFINE        DELETE        DIFFERENCES   DIRECTORY     DISMOUNT\n"
        s += "  EDIT          ELEVATOR      EXAMINE       EXIT          FINGER\n"
        s += "  HELP          INSTALL       LOGOUT        MAIL          MONITOR\n"
        s += "  MOUNT         OPEN          PHONE         PRINT         PRODUCT\n"
        s += "  PURGE         RECALL        RENAME        REPLY         REQUEST\n"
        s += "  RUN           SEARCH        SET           SHOW          SPAWN\n"
        s += "  STOP          SUBMIT        TYPE          WAIT          WRITE\n\n"
        s += "Privileged verbs (refused for the operator account):  DEPOSIT, INITIALIZE, PATCH\n\n"
        s += "Type HELP <topic> for details. Commands may be abbreviated\n"
        s += "(e.g. SH PROC == SHOW PROCESS, DEAL == DEALLOCATE).\n"
        return s
    }

    private func helpTopic(_ raw: String) -> String {
        let t = raw.uppercased()
        switch true {
        case matches(t, "SHOW"):
            var s = "\n  SHOW <subcommand>\n"
            s += "      PROCESS [/ALL]   SYSTEM         USERS          DEVICES\n"
            s += "      MEMORY           TIME           NETWORK        QUEUE\n"
            s += "      LOGICAL [/PROC]  SYMBOL [name]  ERROR          STATUS\n"
            s += "      LICENSE          CPU            DEFAULT        QUOTA\n"
            s += "      PROTECTION       TERMINAL       WORKING_SET    VERSION\n"
            s += "      RMS_DEFAULT      INTRUSION      CLUSTER        CONNECTIONS\n"
            s += "      AUDIT\n"
            return s
        case matches(t, "SET"):
            var s = "\n  SET <subcommand>\n"
            s += "      DEFAULT [device:][directory]\n"
            s += "      TERMINAL/WIDTH=n /PAGE=n\n"
            s += "      PROMPT=\"text\"\n"
            s += "      PROCESS/PRIORITY=n /NAME=name\n"
            s += "      PASSWORD\n"
            s += "      CAB <label> /MANUAL | /AUTOMATIC      <-- demo manual control\n"
            s += "      ON, NOON, VERIFY, NOVERIFY\n"
            return s
        case matches(t, "CALL"):
            return "\n  CALL CAB <label> FLOOR <n>     Queue a floor call on the named cab.\n"
        case matches(t, "OPEN"):
            return "\n  OPEN CAB <label>               Request the cab's doors to open.\n"
        case matches(t, "CLOSE"):
            return "\n  CLOSE CAB <label>              Request the cab's doors to close.\n"
        case matches(t, "STOP"):
            return "\n  STOP CAB <label>               Clear the cab's queued floor calls.\n"
        case matches(t, "MONITOR"):
            var s = "\n  MONITOR <class> [/INTERVAL=seconds]\n"
            s += "      Continuous full-screen display, refreshed every INTERVAL\n"
            s += "      seconds (default 3).  Press Ctrl/Y to interrupt and return\n"
            s += "      to the DCL prompt.\n\n"
            s += "  Available classes:\n"
            s += "      SYSTEM         Mode breakdown + I/O + page rates\n"
            s += "      MODES          Time spent in each processor access mode\n"
            s += "      PROCESSES      Top CPU-time processes (bar chart)\n"
            s += "      IO             I/O subsystem rates\n"
            s += "      PAGE           Page management rates and free/modified list size\n"
            s += "      STATES         Process scheduling-state counts\n"
            s += "      DISK           Per-disk operation rates\n"
            s += "      LOCK           Distributed lock manager rates\n"
            s += "      CLUSTER        Per-node CPU/IO/memory summary\n"
            s += "      FCP            Files-11 XQP primitive rates\n"
            s += "      ALL_CLASSES    Concatenation of SYSTEM + IO + STATES\n"
            return s
        case matches(t, "ELEVATOR"):
            var s = "\n  Elevator demo flow:\n"
            s += "    SET CAB 02 /MANUAL          ! Disable auto-driver for cab 02\n"
            s += "    CALL CAB 02 FLOOR 7         ! Drive it to floor 7\n"
            s += "    OPEN CAB 02                 ! Open the doors\n"
            s += "    CLOSE CAB 02                ! Close the doors\n"
            s += "    STOP CAB 02                 ! Cancel any pending calls\n"
            s += "    SET CAB 02 /AUTOMATIC       ! Hand control back to the auto-driver\n"
            return s

        // Operator-level verbs.
        case matches(t, "ALLOCATE", min: 3):
            return "\n  ALLOCATE device:\n      Claim a user-class device (tape, scratch disk, terminal)\n      for the current process. System volumes are refused.\n"
        case matches(t, "DEALLOCATE", min: 5):
            return "\n  DEALLOCATE device:    or   DEALLOCATE/ALL\n      Release a previously allocated device, or release everything\n      this process has claimed.\n"
        case matches(t, "MOUNT"):
            return "\n  MOUNT device: [volume-label]\n      Attach a volume to a device. The volume label defaults to\n      SCRATCH if not given. System volumes are refused.\n"
        case matches(t, "DISMOUNT", min: 4):
            return "\n  DISMOUNT device:\n      Detach a previously mounted volume.\n"
        case matches(t, "BACKUP"):
            var s = "\n  BACKUP input-spec output-spec\n"
            s += "      Copy a save-set. Prints the OpenVMS BACKUP IDENT banner,\n"
            s += "      a verification line, and the standard CREATED / COPIED messages.\n"
            s += "      Example:  BACKUP CAB$DATA: MUA0:ELEV.BCK\n"
            return s
        case matches(t, "ANALYZE", min: 4):
            var s = "\n  ANALYZE/ERROR_LOG          Recent error log entries.\n"
            s +=   "  ANALYZE/AUDIT              Security audit characteristics.\n"
            s +=   "  ANALYZE/IMAGE              (Privileged) image structure analysis.\n"
            s +=   "  ANALYZE/CRASH_DUMP         (Privileged) read SYS$SYSTEM:SYSDUMP.DMP.\n"
            return s
        case matches(t, "RUN"):
            var s = "\n  RUN image-name\n"
            s += "      Execute an installed image.  Operator account can run the\n"
            s += "      diagnostic images:\n"
            s += "        BRAKE_TEST       Brake hold-force test on every cab.\n"
            s += "        DOOR_TEST        Door open/close + obstruction sensor test.\n"
            s += "        WEIGHT_CAL       Load-cell zero / span calibration.\n"
            s += "        HALL_LAMP_TEST   Cycle every hall-call lamp UP/DOWN.\n"
            s += "      Other images return %SYSTEM-F-NOPRIV.\n"
            return s
        case matches(t, "EXAMINE", min: 4):
            return "\n  EXAMINE address\n      Display the longword stored at the given virtual address.\n      Hex addresses may be entered as ^X1000 or 1000.\n"
        case matches(t, "REPLY"):
            return "\n  REPLY \"text\"\n      Queue a reply line to the operator console (OPER0:).\n"
        case matches(t, "REQUEST", min: 4):
            return "\n  REQUEST \"text\"\n      Log an operator-assistance request through OPCOM.\n"

        // File / terminal / batch verbs.
        case matches(t, "DIRECTORY", min: 3):
            return "\n  DIRECTORY [filespec] [/SIZE] [/DATE] [/FULL]\n      List files in the default directory. /SIZE adds the\n      used/allocated block columns; /DATE adds the timestamp.\n"
        case matches(t, "TYPE"):
            return "\n  TYPE filename\n      Print the contents of a sequential ASCII file. STARTUP.COM\n      and EVENTLOG.LOG are populated; binary files (PEERS.DAT)\n      return %TYPE-W-NOTASCII.\n"
        case matches(t, "WRITE"):
            return "\n  WRITE SYS$OUTPUT \"text\"\n      Echo a literal string. Other destinations return WRITERR.\n"
        case matches(t, "ASSIGN"):
            return "\n  ASSIGN equiv-name logical-name\n      Add an entry to the process logical-name table. (DEFINE\n      uses the reverse argument order: DEFINE name equiv.)\n"
        case matches(t, "DEFINE"):
            return "\n  DEFINE logical-name equiv-name\n      Define a process logical name. Same effect as ASSIGN with\n      arguments reversed.\n"
        case matches(t, "DEASSIGN"):
            return "\n  DEASSIGN logical-name\n      Remove a process logical name. Returns %SYSTEM-F-NOLOGNAM\n      if the name is not defined.\n"
        case matches(t, "RECALL", min: 3):
            return "\n  RECALL [n] | /ALL | /ERASE\n      RECALL with a number reprints history line n; /ALL lists\n      every command in the recall buffer; /ERASE clears it.\n"
        case matches(t, "MAIL"):
            return "\n  MAIL\n      Open the personal mail utility. Reports an empty inbox\n      (%MAIL-W-NOMORE) and exits.\n"
        case matches(t, "PHONE"):
            return "\n  PHONE\n      Real-time chat utility. Returns %PHONE-W-NOTAVAIL on this\n      installation.\n"
        case matches(t, "FINGER", min: 3):
            return "\n  FINGER [user]\n      Show interactive sessions on this node and any DECnet peers,\n      or details of a single user.\n"
        case matches(t, "ACCOUNTING", min: 4):
            return "\n  ACCOUNTING\n      Show the per-user accounting summary since system boot.\n"
        case matches(t, "INSTALL", min: 3):
            return "\n  INSTALL\n      List the known image table (Open / Header-resident /\n      Shared / Linkable images installed by SYSTARTUP).\n"
        case matches(t, "PRODUCT", min: 4):
            return "\n  PRODUCT\n      List installed VSI PCSI products and their kit / state /\n      release.\n"
        case matches(t, "SEARCH", min: 4):
            return "\n  SEARCH file string\n      Search the named file for a literal string.\n"
        case matches(t, "PRINT"):
            return "\n  PRINT file\n      Queue a file to SYS$PRINT.\n"
        case matches(t, "SUBMIT", min: 3):
            return "\n  SUBMIT file.COM\n      Submit a command file as a batch job to SYS$BATCH.\n"
        case matches(t, "CREATE", min: 3):
            return "\n  CREATE filename\n      Create a new sequential file in the default directory.\n"
        case matches(t, "CONTINUE", min: 3):
            return "\n  CONTINUE\n      Continue execution of the most recently interrupted command.\n"
        case matches(t, "COPY"):
            return "\n  COPY input-spec output-spec\n      Copy a file. (Files in this shell return %COPY-E-OPENIN -\n      -RMS-E-FNF since the namespace is read-only.)\n"
        case matches(t, "DELETE", min: 3):
            return "\n  DELETE file;version\n      Delete a file. Returns RMS file-not-found in this shell.\n"
        case matches(t, "PURGE", min: 3):
            return "\n  PURGE [filespec]\n      Delete previous versions of a file.\n"
        case matches(t, "RENAME", min: 3):
            return "\n  RENAME old-spec new-spec\n      Rename or move a file.\n"
        case matches(t, "APPEND", min: 3):
            return "\n  APPEND input-spec output-spec\n      Concatenate input onto the output file.\n"
        case matches(t, "EDIT"):
            return "\n  EDIT file\n      Invoke the EDT line editor (read-only in this shell).\n"
        case matches(t, "DIFFERENCES", min: 4):
            return "\n  DIFFERENCES file1 file2\n      Compare two files line-by-line.\n"
        case matches(t, "SPAWN"):
            return "\n  SPAWN [command]\n      Start a subprocess. Returns -DCL-E-NOSUBPROC since the\n      diagnostic shell does not have the subprocess facility.\n"
        case matches(t, "ATTACH"):
            return "\n  ATTACH process-name\n      Re-attach to a parent process. Returns -DCL-W-ATTNOPAR\n      because no parent exists.\n"
        case matches(t, "WAIT"):
            return "\n  WAIT hh:mm:ss[.cc]\n      Suspend the shell for the specified delta time.\n"
        case matches(t, "CLEAR"):
            return "\n  CLEAR\n      Clear the terminal scrollback.\n"
        case matches(t, "LOGOUT") || matches(t, "EXIT"):
            return "\n  LOGOUT [/FULL]    or    EXIT\n      End the DCL session and close the terminal window.\n      /FULL appends an accounting summary.\n"
        case matches(t, "SELFTEST", min: 4):
            return "\n  SELFTEST\n      Drive every documented verb once and print a per-verb\n      pass/fail line. If the shell stays up afterwards, every\n      verb dispatches without panicking.\n"

        default:
            return "\n  Sorry, no further help is available for \(t).\n"
        }
    }

    // MARK: -- helpers

    /// Hidden SELFTEST verb: drives every documented DCL verb once and prints
    /// a one-line pass / fail summary per command. If any command crashes the
    /// shell will go down with it, so a clean run means every verb dispatches
    /// and returns without panicking.
    private func selfTest() -> String {
        let verbs: [String] = [
            "SHOW PROCESS", "SHOW PROCESS/ALL",
            "SHOW SYSTEM", "SHOW USERS", "SHOW DEVICES", "SHOW MEMORY",
            "SHOW TIME", "SHOW NETWORK", "SHOW QUEUE",
            "SHOW LOGICAL", "SHOW LOGICAL/PROCESS",
            "SHOW SYMBOL", "SHOW SYMBOL $STATUS", "SHOW SYMBOL $SEVERITY",
            "SHOW ERROR", "SHOW STATUS", "SHOW LICENSE",
            "SHOW CPU", "SHOW DEFAULT", "SHOW QUOTA",
            "SHOW PROTECTION", "SHOW TERMINAL", "SHOW WORKING_SET",
            "SHOW VERSION", "SHOW RMS_DEFAULT", "SHOW INTRUSION",
            "SHOW CLUSTER", "SHOW CONNECTIONS", "SHOW AUDIT",
            "SET DEFAULT [-]", "SET TERMINAL/WIDTH=80",
            "SET PROMPT=\"DCL$ \"", "SET ON", "SET NOON",
            "SET PROCESS",
            "DIRECTORY", "DIRECTORY/SIZE/DATE",
            "TYPE STARTUP.COM", "TYPE EVENTLOG.LOG", "TYPE PEERS.DAT",
            "TYPE NOSUCHFILE.TXT",
            "WRITE SYS$OUTPUT \"selftest\"",
            "ASSIGN DKA0: TEST_DISK", "DEASSIGN TEST_DISK",
            "DEFINE TEST_LOG \"value\"", "DEASSIGN TEST_LOG",
            "MAIL", "PHONE", "FINGER", "FINGER OPERATOR",
            "RECALL", "RECALL/ALL", "RECALL 1",
            "SPAWN", "ATTACH", "WAIT 00:00:01",
            "ACCOUNTING", "INSTALL", "PRODUCT",
            "SEARCH FILE.TXT \"foo\"", "PRINT REPORT.LIS",
            "SUBMIT JOB.COM",
            "CREATE NEWFILE.TXT", "CONTINUE",
            "COPY A.TXT B.TXT", "DELETE OLD.TXT", "PURGE TMP.TMP",
            "RENAME A.TXT B.TXT", "APPEND A.TXT B.TXT",
            "EDIT FILE.TXT", "DIFFERENCES A.TXT B.TXT",
            "RUN PROG.EXE", "RUN BRAKE_TEST", "RUN DOOR_TEST",
            "RUN WEIGHT_CAL", "RUN HALL_LAMP_TEST",
            "ANALYZE/ERROR_LOG", "ANALYZE/AUDIT", "ANALYZE/IMAGE",
            "INITIALIZE DKA0:",
            "MOUNT DKA0:", "MOUNT MUA0: ELEV_BACKUP",
            "DISMOUNT MUA0:",
            "BACKUP CAB$DATA: MUA0:ELEV.BCK",
            "PATCH FILE", "DEPOSIT 100",
            "EXAMINE 1000", "EXAMINE ^X100",
            "ALLOCATE MUA0:", "ALLOCATE TT0:",
            "DEALLOCATE MUA0:", "DEALLOCATE/ALL",
            "REPLY \"go ahead\"", "REQUEST \"need maintenance\"",
            "@STARTUP",
            "HELP", "HELP SHOW", "HELP SET", "HELP MONITOR",
            "HELP CALL", "HELP ELEVATOR",
        ]

        var passed = 0
        var lines: [String] = []
        lines.append("\nSELFTEST -- driving every documented verb (LOGOUT/EXIT/CLEAR excluded)\n")
        dryRun = true
        defer { dryRun = false }
        for v in verbs {
            let body = execute(v)
            let chars = body.count
            let badFmt = body.contains("(null)") || body.contains("0x") && body.contains("Optional")
            let status: String
            if chars == 0 {
                status = "ok (no output)"
            } else if badFmt {
                status = "BAD-FMT"
            } else {
                status = "ok"
            }
            if status.hasPrefix("ok") { passed += 1 }
            let label = v.padding(toLength: 38, withPad: " ", startingAt: 0)
            lines.append(String(format: "  %@  %@  (%d chars)", label, status.padding(toLength: 14, withPad: " ", startingAt: 0), chars))
        }
        lines.append("")
        lines.append("  \(passed)/\(verbs.count) verbs returned cleanly.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Find a cab by user-supplied label, tolerating zero-padding ("2" finds "02")
    /// and case ("CAB-A" matches "cab-a").
    private func findCab(label raw: String, in world: ElevatorWorld) -> Elevator? {
        let needle = raw.uppercased()
        if let exact = world.elevators.first(where: { $0.label.uppercased() == needle }) {
            return exact
        }
        if let n = Int(needle) {
            if let byNumber = world.elevators.first(where: { Int($0.label) == n }) {
                return byNumber
            }
        }
        return nil
    }

    private func matches(_ token: String, _ canonical: String, min: Int = 2) -> Bool {
        let t = token.uppercased()
        let c = canonical.uppercased()
        guard t.count >= min, c.hasPrefix(t) else { return false }
        return true
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss.SS"
        return f
    }()

    private func stamp(_ d: Date) -> String {
        DCLEngine.formatter.string(from: d).uppercased()
    }

    private func uptimeString(from start: Date, to end: Date) -> String {
        let secs = Int(end.timeIntervalSince(start))
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        return String(format: "%d %02d:%02d:%02d", d, h, m, s)
    }
}
