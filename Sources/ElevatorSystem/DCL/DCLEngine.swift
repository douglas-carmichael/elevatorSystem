import Foundation

/// Core of the DCL shell: owns the published transcript, holds the
/// process / terminal / symbol / volume state that every command family
/// in DCL{Show,Set,Files,Cab,Operator,Monitor,...}.swift mutates, and
/// dispatches a parsed command line to the matching verb implementation.
@MainActor
final class DCLEngine: ObservableObject {
    @Published var transcript: String = ""
    @Published var prompt: String = "$ "
    @Published var loggedOut: Bool = false

    /// When non-nil, the DCL window paints this as a full-screen "terminal"
    /// view, replacing the transcript and prompt. Used by continuous
    /// MONITOR and by the RUN <diagnostic> test utilities.
    @Published var liveDisplay: String? = nil

    enum LiveMode {
        case none
        case monitor
        case testUtility(name: String, header: String)
    }
    var liveMode: LiveMode = .none
    var liveTimer: Timer?

    var monitorClass: String = "SYSTEM"
    var monitorIntervalSec: TimeInterval = 3.0
    var monitorStartedAt: Date = Date()

    // Test-utility state shared with DCLDiagnostics.
    struct TestStep {
        let label: String
        let run: () -> (reading: String, status: String)
    }
    var testSteps: [TestStep] = []
    var testCurrent: Int = 0
    var testResults: [(label: String, reading: String, status: String)] = []
    var testStartedAt: Date = Date()

    weak var world: ElevatorWorld?
    weak var network: PeerNetwork?
    weak var automation: AutoDriver?
    weak var language: AppLanguage?

    let host = HostStats.shared
    let osVersion: String = "V9.2-3"
    let osTitle: String = "VSI OpenVMS"
    let username: String
    let nodeName: String = "ASCEN1"
    let terminalName: String = "TT$VTA0418:"
    let pid: String
    var lastStatus: String = "%X00000001"
    var lastStatusLabel: String = "SS$_NORMAL"

    // SET DEFAULT state
    var defaultDevice: String = "ELEVATOR$ROOT:"
    var defaultDirectory: String       // e.g. "[OPERATOR]"

    // SET TERMINAL state
    var terminalWidth: Int = 132
    var terminalPage: Int = 24

    // ASSIGN / DEASSIGN / DEFINE / scripting symbol table.
    var processLogicals: [String: String] = [:]
    var symbols: [String: String] = [:]

    // RECALL history.
    var history: [String] = []
    let maxHistory: Int = 254     // VMS default

    // ALLOCATE / DEALLOCATE state.
    var allocatedDevices: Set<String> = []
    // MOUNT / DISMOUNT state -- volume label per mounted device.
    var mountedVolumes: [String: String] = [:]

    /// Set during SELFTEST so verbs that would normally take over the
    /// screen (RUN <diagnostic>, MONITOR ...) just report what they'd do
    /// instead.
    var dryRun: Bool = false

    /// Persistent on-disk .COM file store, used by EDIT, TYPE, DIRECTORY,
    /// CREATE, DELETE and @file.
    let scriptStore = DCLScriptStore()
    /// Depth counter so the script interpreter can refuse infinite @file
    /// recursion.
    var scriptDepth: Int = 0

    // EDT editor state -- see DCLEdt.swift.
    var editorActive: Bool = false
    var editorBuffer: [String] = []
    var editorFilename: String = ""
    var editorCurrentLine: Int = 1
    var editorModified: Bool = false
    var editorInsertMode: Bool = false
    var editorPreviousPrompt: String = "$ "

    var bootTime: Date { host.bootDate }

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
    /// SYS$MANAGER:SYLOGIN.COM after the system banner.
    func lpdSplash() -> String {
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

    /// Translate via the attached AppLanguage, falling back to the raw key
    /// if no language is wired so SELFTEST still works in unit-style
    /// scenarios.
    func tr(_ key: String) -> String {
        guard let lang = language else { return Strings.lookup(key, lang: .en) }
        return lang.t(key)
    }

    /// Single entry point for input from the DCL window. Echoes the line,
    /// records it in the recall buffer, then either routes it to the EDT
    /// editor (when active) or to the DCL command dispatcher.
    func submit(_ raw: String) {
        // EDT input mode swallows blank lines and the terminator ".".
        if editorActive {
            appendPromptEcho(raw)
            let body = runEditorLine(raw)
            if !body.isEmpty {
                transcript += body
                if !body.hasSuffix("\n") { transcript += "\n" }
            }
            return
        }

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

    func banner() -> String {
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

    func appendPromptEcho(_ s: String) {
        transcript += "\(prompt)\(s)\n"
    }

    // MARK: -- parsed line

    struct Parsed {
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

    func parse(_ line: String) -> Parsed {
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

    func execute(_ line: String) -> String {
        let cmd = parse(line)
        let head = cmd.verb
        guard !head.isEmpty else { return "" }

        // Logical-name and symbol indirection: '@file' executes a COM file.
        if head.hasPrefix("@") {
            let file = String(head.dropFirst())
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

        // Operator-level verbs.
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

        // Genuinely privileged verbs.
        case matches(head, "INITIALIZE", min: 4):             return noPriv("INITIALIZE")
        case matches(head, "PATCH"):                          return noPriv("PATCH")
        case matches(head, "DEPOSIT", min: 4):                return noPriv("DEPOSIT")

        // File-touching verbs. EDIT now launches the in-shell EDT editor;
        // DELETE removes user-stored .COM files; the rest still fail with
        // RMS-E-FNF because the rest of the namespace is read-only.
        case matches(head, "COPY"):                           return rmsFNF("COPY", cmd, op: "COPYIN")
        case matches(head, "DELETE", min: 3):                 return deleteCmd(cmd)
        case matches(head, "PURGE", min: 3):                  return rmsFNF("PURGE", cmd, op: "OPENIN")
        case matches(head, "RENAME", min: 3):                 return rmsFNF("RENAME", cmd, op: "OPENIN")
        case matches(head, "APPEND", min: 3):                 return rmsFNF("APPEND", cmd, op: "OPENIN")
        case matches(head, "EDIT"):
            // In SELFTEST mode return a dry-run line so the test pass
            // doesn't leave the editor active.
            if dryRun { return "%EDT-I-DRYRUN, would open EDT on \(cmd.positional.first ?? "(no file)")\n" }
            return startEdt(cmd)
        case matches(head, "DIFFERENCES", min: 4):            return rmsFNF("DIFFERENCES", cmd, op: "OPENIN")
        case matches(head, "CREATE", min: 3):                 return createCmd(cmd)
        case matches(head, "CONTINUE", min: 3):               return ""

        default:
            return ivverb(head)
        }
    }

    // MARK: -- error / status helpers

    func ivverb(_ verb: String) -> String {
        fail("DCL-W-IVVERB", "%X00038090")
        return "%DCL-W-IVVERB, unrecognized command verb - check validity and spelling\n   \\\(verb)\\\n"
    }

    func missQual(_ verb: String) -> String {
        fail("DCL-W-MISSQUAL", "%X00038108")
        return "%DCL-W-MISSQUAL, missing qualifier or keyword on \(verb)\n"
    }

    func noPriv(_ verb: String) -> String {
        fail("SYSTEM-F-NOPRIV", "%X0000056C")
        return "%SYSTEM-F-NOPRIV, insufficient privilege to execute \(verb)\n"
    }

    func rmsFNF(_ facility: String, _ cmd: Parsed, op: String) -> String {
        let target = cmd.positional.first ?? "FILE.LIS"
        fail("RMS-E-FNF", "%X00018292")
        return "%\(facility)-E-\(op), error opening \(defaultDevice)\(defaultDirectory)\(target) as input\n-RMS-E-FNF, file not found\n"
    }

    func succeed() {
        lastStatus = "%X00000001"
        lastStatusLabel = "SS$_NORMAL"
    }

    func fail(_ label: String, _ code: String) {
        lastStatus = code
        lastStatusLabel = label
    }

    // MARK: -- LOGOUT

    func logoutText(full: Bool) -> String {
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

    // MARK: -- general utilities used everywhere

    func matches(_ token: String, _ canonical: String, min: Int = 2) -> Bool {
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

    func stamp(_ d: Date) -> String {
        DCLEngine.formatter.string(from: d).uppercased()
    }

    func uptimeString(from start: Date, to end: Date) -> String {
        let secs = Int(end.timeIntervalSince(start))
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        return String(format: "%d %02d:%02d:%02d", d, h, m, s)
    }
}
