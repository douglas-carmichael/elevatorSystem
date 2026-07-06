import Foundation
import Combine

/// Core of the DCL shell: owns the published transcript, holds the
/// process / terminal / symbol / volume state that every command family
/// in DCL{Show,Set,Files,Cab,Operator,Monitor,...}.swift mutates, and
/// dispatches a parsed command line to the matching verb implementation.
@MainActor
final class DCLEngine: ObservableObject {
    @Published var transcript: String = ""
    @Published var prompt: String = "$ "
    @Published var loggedOut: Bool = false

    /// True while a continuous MONITOR or full-screen test utility owns
    /// the terminal (alternate-screen buffer). Used by the keyboard
    /// handler to decide whether Ctrl-Y should stop monitor or fall
    /// through to ordinary line editing.
    @Published var liveActive: Bool = false

    /// Sink for output destined for the VT220/320 terminal view. Set by
    /// the SwiftTerm bridge in VTShellView. Receives both plain text and
    /// raw escape sequences. Bytes still land in `transcript` (without
    /// escapes) so SELFTEST and unit tests can introspect output.
    var outputHandler: ((String) -> Void)? {
        didSet { flushPendingOutput() }
    }

    /// Output produced before a terminal is attached (e.g. the banner)
    /// gets buffered here and flushed once `outputHandler` is wired.
    private var pendingOutput: String = ""

    enum LiveMode {
        case none
        case monitor
        case testUtility(name: String, header: String)
        case diagnosticMenu
        case screenEditor
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

    // Diagnostic menu state -- see DCLDiagnostics.swift for the
    // DECforms-style selector launched by `DIAGNOSE`.
    struct DiagMenuItem {
        let image: String           // e.g. "BRAKE_TEST"
        let description: String
        let runner: () -> Void
    }
    var diagMenuItems: [DiagMenuItem] = []
    var diagMenuSelection: Int = 0
    /// True while a diagnostic test is running that was launched from the
    /// DIAGNOSE menu (versus a bare `RUN BRAKE_TEST`). `stopMonitor` reads
    /// this to decide whether to drop to the DCL prompt or re-show the menu
    /// when the operator hits Ctrl/Y after a test completes or aborts.
    var diagInvokedFromMenu: Bool = false

    weak var world: ElevatorWorld?
    weak var network: PeerNetwork?
    weak var automation: AutoDriver?
    weak var language: AppLanguage?

    let host = HostStats.shared
    let osVersion: String = "V9.2-3"
    let osTitle: String = "VSI OpenVMS"
    let username: String
    let nodeName: String
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

    // MAIL state -- persisted to MAILBOX.JSON in the script-store
    // directory so the inbox (including SUBMIT-job completion notices)
    // survives a relaunch. Real VMS stores its MAIL inbox in
    // SYS$LOGIN:MAIL.MAI; we use a JSON sidecar for the same purpose.
    struct MailMessage: Codable {
        let id: Int
        let from: String
        let subject: String
        let body: String
        let received: Date
        var read: Bool
    }
    var mailbox: [MailMessage] = []
    var nextMailId: Int = 1
    static let mailboxFileName = "MAILBOX.JSON"

    // Interactive MAIL subshell state (see DCLMail.swift). Mirrors the EDT
    // line-editor pattern: `mailActive` reroutes submit() into runMailLine()
    // until the operator types EXIT / QUIT. `mailCurrentId` is the "current
    // message" pointer real MAIL keeps; the compose state machine drives the
    // SEND / REPLY / FORWARD  To: / Subj: / body  prompt sequence.
    var mailActive: Bool = false
    var mailPreviousPrompt: String = "$ "
    var mailCurrentId: Int? = nil

    enum MailCompose {
        case none
        case awaitingTo
        case awaitingSubject
        case body
    }
    var mailCompose: MailCompose = .none
    var mailComposeTo: String = ""
    var mailComposeSubject: String = ""
    var mailComposeBody: [String] = []
    /// True while capturing free-form message body lines (between the Subj:
    /// prompt and the terminating CTRL/Z). The line discipline reads this to
    /// route CTRL/Z into `endMailMessage`, and submit() reads it to suppress
    /// the prompt while the body is being typed (just like EDT insert mode).
    var mailComposingBody: Bool { if case .body = mailCompose { return true } else { return false } }
    /// True whenever a SEND / REPLY / FORWARD compose is in progress (any of
    /// the To: / Subj: / body sub-states). CTRL/C aborts the message.
    var mailComposing: Bool { if case .none = mailCompose { return false } else { return true } }

    // In-universe status-mail generator (see DCLMail.swift). The simulated
    // building writes OPCOM / SCADA status updates into the inbox as the
    // world changes; these watermarks stop pre-existing alarms and modes at
    // login time from backfilling the mailbox.
    var mailWorldCancellables: Set<AnyCancellable> = []
    var lastMailedAlarmSequence: Int = 0
    /// Last time an in-universe alarm mail went out for a given
    /// "SOURCE|POINT" key. The sampled safety conditions raise / clear /
    /// re-raise as cabs move, so without this a single flapping point would
    /// bury the inbox -- we only re-notify a point after a cooldown.
    var lastMailedAlarmKeyAt: [String: Date] = [:]
    var lastMailedBuildingMode: BuildingMode? = nil
    var lastMailedDispatchMode: DispatchMode? = nil

    // INSTALL state -- images that STARTUP.COM's INSTALL ADD has made
    // known to the system. Seeded with the canonical elevator-control
    // image set so INSTALL LIST has something to show before STARTUP
    // runs; subsequent ADDs append to it.
    struct InstalledImage {
        let name: String
        let flags: String       // e.g. "Open Hdr Shar Lnkbl"
    }
    var installedImages: [InstalledImage] = [
        InstalledImage(name: "CONTROL.EXE;42", flags: "Open Hdr Shar Lnkbl"),
        InstalledImage(name: "DOORS.EXE;19",   flags: "Open Hdr Shar Lnkbl"),
        InstalledImage(name: "SCHED.EXE;7",    flags: "Open Hdr Shar Lnkbl"),
    ]

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

    // Screen-mode EDT (EDIT, or EDIT/SCREEN) state. Cursor and view-top
    // are 0-indexed offsets into editorBuffer. See DCLEdt.swift.
    var editorScreenMode: Bool = false
    var editorCursorRow: Int = 0
    var editorCursorCol: Int = 0
    var editorViewTop: Int = 0

    /// Captured at engine init. SHOW SYSTEM uses this as the anchor for
    /// the synthetic per-process counters so the displayed I/O, CPU time
    /// and page faults grow monotonically across refreshes and the table
    /// looks like a live system instead of a static snapshot.
    let sessionStart: Date = Date()

    /// MONITOR DYNAMICS tracks the previous tick's velocity for each cab
    /// so it can derive an acceleration figure from the delta against
    /// the current frame -- avoids putting another piece of state on
    /// every Elevator just for the LPD monitor utility.
    var lastDynamicsVelocity: [UUID: Double] = [:]
    var lastDynamicsSampleAt: Date = Date()

    var bootTime: Date { host.bootDate }

    init() {
        let raw = NSUserName()
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        self.username = cleaned.isEmpty ? "OPERATOR" : String(cleaned.prefix(12))
        self.pid = String(format: "%08X", Int.random(in: 0x0000_0400...0x0000_04FF))
        self.defaultDirectory = "[\(self.username)]"
        self.nodeName = Self.makeNodeName()
        if !loadMailbox() {
            seedInitialMail()
            persistMailbox()
        }
    }

    private func seedInitialMail() {
        let now = Date()
        mailbox.append(MailMessage(
            id: nextMailId,
            from: "SYSTEM",
            subject: "Welcome to the elevator-control cluster",
            body: "Logged in to node \(nodeName) as \(username).\nUse HELP MAIL for the inbox subverbs.\n",
            received: now.addingTimeInterval(-300),
            read: false))
        nextMailId += 1
        mailbox.append(MailMessage(
            id: nextMailId,
            from: "OPCOM",
            subject: "STARTUP.COM completed",
            body: "INSTALL ADD ELEVATOR$ROOT:[CONTROL]CONTROL.EXE /OPEN/SHARED -- ok\nDispatch table loaded; control image is resident.\n",
            received: now.addingTimeInterval(-180),
            read: false))
        nextMailId += 1
    }

    @discardableResult
    private func loadMailbox() -> Bool {
        guard let raw = scriptStore.read(name: Self.mailboxFileName),
              let data = raw.data(using: .utf8) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let messages = try? decoder.decode([MailMessage].self, from: data) else { return false }
        mailbox = messages
        nextMailId = (messages.map(\.id).max() ?? 0) + 1
        return true
    }

    func persistMailbox() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(mailbox),
              let str = String(data: data, encoding: .utf8) else { return }
        scriptStore.write(name: Self.mailboxFileName, body: str)
    }

    /// Build an OpenVMS-plausible 6-character DECnet-style node name
    /// from the local Mac's system name. Real VMS clusters use 1-6
    /// upper-case alphanumerics, first char must be a letter, and most
    /// shops follow a "stem + node-number" pattern (ASCEN1, BOSTON, etc.)
    private static func makeNodeName() -> String {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let upper = raw.uppercased()
        let alnum = upper.filter { $0.isLetter || $0.isNumber }
        if alnum.isEmpty { return "VMSND1" }
        var name = String(alnum.prefix(6))
        // VMS requires the first character to be a letter.
        if let first = name.first, !first.isLetter {
            name = "N" + name.dropFirst()
        }
        // Pad short names with "1" so they look like a node-numbered
        // cluster member: "IMAC" -> "IMAC11", "MBP" -> "MBP111".
        if name.count < 6 {
            name += String(repeating: "1", count: 6 - name.count)
        }
        return name
    }

    func attach(world: ElevatorWorld, network: PeerNetwork,
                automation: AutoDriver? = nil, language: AppLanguage? = nil) {
        self.world = world
        self.network = network
        self.automation = automation
        self.language = language
        // Subscribe to world events so the simulated building writes
        // in-universe status mail (OPCOM / SCADA notices) into the inbox.
        subscribeInUniverseMail()
        // Render the banner now that the language reference is available.
        transcript = ""
        pendingOutput = ""
        out(banner())
        out(lpdSplash())
        // Auto-run SYS$LOGIN:LOGIN.COM to populate the LPD-CP foreign-
        // command aliases (CAB, BLDG, DPATCH, ...) before the first
        // prompt. Done in a Task because execComFile() is async; the
        // prompt is emitted by the continuation so it doesn't race
        // ahead of the LOGIN.COM "aliases loaded" line.
        Task { @MainActor in
            let body = await execComFile("LOGIN.COM")
            if !body.isEmpty {
                out(body)
                if !body.hasSuffix("\n") { out("\n") }
            }
            out(prompt)
        }
        // Subscribe to language changes so the banner and splash repaint
        // in the new language when the operator hits `L` in the control
        // panel. Without this the login block stays in whichever language
        // was active at attach() time even after the rest of the UI
        // switches.
        languageCancellable?.cancel()
        languageCancellable = language?.$current
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.reloginForLanguageChange() }
            }
    }

    private var languageCancellable: AnyCancellable?

    /// Wipe the terminal and re-emit the banner / splash / prompt so the
    /// login block reflects the currently-selected language. Triggered by
    /// the @Published subscription on AppLanguage.current.
    private func reloginForLanguageChange() {
        transcript = ""
        outRaw("\u{1B}[2J\u{1B}[H")
        out(banner())
        out(lpdSplash())
        out(prompt)
    }

    // MARK: -- output sink

    /// Emit human-readable output. Goes both to the transcript (so
    /// SELFTEST / tests can introspect) and out to the attached
    /// VT terminal view.
    func out(_ text: String) {
        transcript += text
        if let h = outputHandler { h(text) }
        else { pendingOutput += text }
    }

    /// Emit raw bytes (typically VT escape sequences) directly to the
    /// terminal. They do NOT land in the transcript.
    func outRaw(_ bytes: String) {
        if let h = outputHandler { h(bytes) }
        else { pendingOutput += bytes }
    }

    /// Drain anything buffered before the terminal attached. Always
    /// replays the full transcript -- on first attach this delivers
    /// the banner / splash / prompt that landed in `pendingOutput`,
    /// and on subsequent attaches (the user closing the DCL window
    /// then reopening it) it restores everything the previous session
    /// had on screen instead of leaving the new terminal blank.
    private func flushPendingOutput() {
        guard let h = outputHandler else { return }
        if !transcript.isEmpty {
            h(transcript)
        }
        pendingOutput = ""
    }

    /// LPD ELEVATOR-CTRL layered-product splash printed after the OpenVMS
    /// login banner. Real OpenVMS sites typically print these from
    /// SYS$MANAGER:SYLOGIN.COM after the system banner. Kept tight on
    /// blank lines so the entire boot sequence (banner + splash + prompt)
    /// fits in a typical 20-row terminal viewport.
    func lpdSplash() -> String {
        var s = ""
        s += "    " + tr("login.lpd.line1") + "\n"
        s += "    " + tr("login.lpd.ctrl")  + "\n"
        s += "    " + tr("login.lpd.line2") + "\n"
        s += "    " + tr("login.lpd.brake")  + "\n"
        s += "    " + tr("login.lpd.door")   + "\n"
        s += "    " + tr("login.lpd.weight") + "\n"
        s += "    " + tr("login.lpd.lamp")   + "\n"
        s += "    " + tr("login.lpd.help") + "\n"
        return s
    }

    /// Translate via the attached AppLanguage, falling back to the raw key
    /// if no language is wired so SELFTEST still works in unit-style
    /// scenarios.
    func tr(_ key: String) -> String {
        guard let lang = language else { return Strings.lookup(key, lang: .en) }
        return lang.t(key)
    }

    /// Single entry point for input from the terminal line discipline.
    /// The terminal has already echoed the keystrokes and emitted a CRLF;
    /// we just execute the line and emit the next prompt. Async because
    /// `WAIT` and command procedures that run `WAIT` actually pause via
    /// `Task.sleep`, matching real VMS semantics.
    func submit(_ raw: String) async {
        // EDT input mode swallows blank lines and the terminator ".".
        if editorActive {
            // Record the typed line in the transcript so SELFTEST and
            // headless tests can introspect it even though the terminal
            // already echoed it on screen.
            transcript += "\(prompt)\(raw)\n"
            let body = runEditorLine(raw)
            if !body.isEmpty {
                out(body)
                if !body.hasSuffix("\n") { out("\n") }
            }
            // INSERT mode runs without a "*" prompt before each line; the
            // editor returns the prompt itself when input mode ends.
            if !loggedOut && !editorInsertMode {
                out(prompt)
            }
            return
        }

        // Interactive MAIL subshell routes every line to runMailLine until
        // the operator types EXIT / QUIT (mirrors the editorActive branch).
        if mailActive {
            transcript += "\(prompt)\(raw)\n"
            let body = runMailLine(raw)
            if !body.isEmpty {
                out(body)
                if !body.hasSuffix("\n") { out("\n") }
            }
            // Suppress the prompt while capturing free-form message body
            // (real MAIL prints nothing until CTRL/Z), exactly like EDT
            // insert mode.
            if !loggedOut && !mailComposingBody { out(prompt) }
            return
        }

        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript += "\(prompt)\(line)\n"
        if line.isEmpty {
            if !loggedOut && !liveActive { out(prompt) }
            return
        }
        if history.last != line {
            history.append(line)
            if history.count > maxHistory { history.removeFirst() }
        }
        let body = await execute(line)
        if !body.isEmpty {
            out(body)
            if !body.hasSuffix("\n") { out("\n") }
        }
        if !loggedOut && !liveActive {
            out(prompt)
        }
    }

    // MARK: -- output framing

    func banner() -> String {
        let lang = language?.current ?? .en
        func t(_ key: String, _ args: CVarArg...) -> String {
            String(format: Strings.lookup(key, lang: lang), arguments: args)
        }
        var s = ""
        // Welcome + node folded onto one line, and the generic
        // "Type HELP for a list" hint dropped (the LPD splash already
        // ends with a more specific HELP RUN hint), so banner + splash
        // + prompt fits in 12 viewport rows.
        let welcome = t("dcl.banner.welcome", osTitle, osVersion)
        let onnode  = t("dcl.banner.onnode", nodeName)
        s += "    " + welcome + "   " + onnode + "\n"
        s += "    " + t("dcl.banner.lastinter", stamp(bootTime)) + "\n"
        s += "    " + t("dcl.banner.lastnon", stamp(bootTime.addingTimeInterval(-43200))) + "\n"
        s += "    *** " + t("dcl.banner.shelltag", "ELEVATOR$ROOT:[\(username)]") + " ***\n"
        return s
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
                // Non-first tokens may also carry attached qualifiers, e.g.
                // SET BUILDING/NORMAL -- the keyword is BUILDING and /NORMAL
                // is its qualifier.
                let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                if !parts[0].isEmpty { positional.append(parts[0]) }
                for p in parts.dropFirst() where !p.isEmpty {
                    let (n, v) = splitQual(p)
                    qualifiers.append((n, v))
                }
            }
        }
        return Parsed(verb: verb, positional: positional, qualifiers: qualifiers)
    }

    /// Expand a leading foreign-command symbol. Returns nil if the verb
    /// isn't a defined symbol, or if the symbol's value starts with `$`
    /// (a real-VMS foreign-command image pointer -- our canonical verbs
    /// are intercepted by execute() before this hook fires, so the `$`
    /// form is purely cosmetic).
    private func expandSymbolAlias(head: String, cmd: Parsed) -> Parsed? {
        guard let raw = symbols[head] else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if cleaned.isEmpty || cleaned.hasPrefix("$") { return nil }
        let expansion = parse(cleaned)
        // Verb + positionals of the expansion come first; the original
        // command's positionals are appended (so `CAB L01` -> verb=LPDCP,
        // positional=[SHOW, CAB, L01]).
        return Parsed(
            verb: expansion.verb,
            positional: expansion.positional + cmd.positional,
            qualifiers: expansion.qualifiers + cmd.qualifiers
        )
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

    func execute(_ line: String) async -> String {
        var cmd = parse(line)
        var head = cmd.verb
        guard !head.isEmpty else { return "" }

        // Logical-name and symbol indirection: '@file' executes a COM file.
        if head.hasPrefix("@") {
            let file = String(head.dropFirst())
            return await execComFile(file)
        }

        // Foreign-command / symbol expansion. Lets LOGIN.COM define short
        // aliases like CAB :== "LPDCP SHOW CAB"; typing `$ CAB L01` then
        // dispatches as `$ LPDCP SHOW CAB L01`. Single-shot so cyclic
        // aliases can't loop the dispatcher.
        if let expanded = expandSymbolAlias(head: head, cmd: cmd) {
            cmd = expanded
            head = cmd.verb
        }

        succeed()

        switch true {
        case matches(head, "HELP") || head == "?":           return helpText(topic: cmd.positional.first)
        case matches(head, "LPDCP", min: 5):                  return lpdcpCmd(cmd)
        case matches(head, "SHOW"):                           return showCmd(cmd)
        case matches(head, "SET"):                            return setCmd(cmd)
        case matches(head, "DIRECTORY", min: 3):              return directoryCmd(cmd)
        case matches(head, "MONITOR", min: 3):                return monitorCmd(cmd)
        case matches(head, "TYPE"):                           return typeCmd(cmd)
        case matches(head, "WRITE"):                          return writeCmd(cmd)
        case matches(head, "ASSIGN"):                         return assignCmd(cmd)
        case matches(head, "DEFINE"):                         return assignCmd(cmd)   // alias of ASSIGN/PROCESS
        case matches(head, "DEASSIGN"):                       return deassignCmd(cmd)
        case matches(head, "MAIL"):                           return mailCmd(cmd)
        case matches(head, "PHONE"):                          return phoneCmd()
        case matches(head, "FINGER", min: 3):                 return fingerCmd(cmd)
        case matches(head, "RECALL", min: 3):                 return recallCmd(cmd)
        case matches(head, "SPAWN"):                          return spawnCmd()
        case matches(head, "ATTACH"):                         return attachCmd()
        case matches(head, "WAIT"):                           return await waitCmd(cmd)
        case matches(head, "ACCOUNTING", min: 4):             return accountingCmd()
        case matches(head, "INSTALL", min: 3):                return installCmd(cmd)
        case matches(head, "PRODUCT", min: 4):                return productCmd()
        case matches(head, "SEARCH", min: 4):                 return searchCmd(cmd)
        case matches(head, "PRINT"):                          return printCmd(cmd)
        case matches(head, "SUBMIT", min: 3):                 return await submitCmd(cmd)
        case matches(head, "CALL"):                           return callCmd(cmd)
        case matches(head, "OPEN"):                           return openCmd(cmd)
        case matches(head, "CLOSE"):                          return closeCmd(cmd)
        case matches(head, "STOP"):                           return stopCmd(cmd)
        case matches(head, "CLEAR"):
            transcript = ""
            outRaw("\u{1B}[2J\u{1B}[H")
            return ""
        case matches(head, "SELFTEST", min: 4):               return await selfTest()
        case matches(head, "LOGOUT") || matches(head, "EXIT"):
            loggedOut = true
            return logoutText(full: cmd.hasQualifier("FULL", min: 1))

        // Operator-level verbs.
        case matches(head, "RUN"):                            return runCmd(cmd)
        case matches(head, "DIAGNOSE", min: 4):
            if dryRun {
                return "%DIAG-I-DRYRUN, would open diagnostic test menu\n"
            }
            startDiagnosticMenu()
            return ""
        case matches(head, "ANALYZE", min: 4):                return analyzeCmd(cmd)
        case matches(head, "MOUNT"):                          return mountCmd(cmd)
        case matches(head, "DISMOUNT", min: 4):               return dismountCmd(cmd)
        case matches(head, "BACKUP"):                         return backupCmd(cmd)
        case matches(head, "EXAMINE", min: 4):                return examineCmd(cmd)
        case matches(head, "ALLOCATE", min: 3):               return allocateCmd(cmd)
        case matches(head, "DEALLOCATE", min: 5):             return deallocateCmd(cmd)
        case matches(head, "REPLY"):                          return replyCmd(cmd)
        case matches(head, "REQUEST", min: 4):                return requestCmd(cmd)
        case matches(head, "ACKNOWLEDGE", min: 3):            return acknowledgeCmd(cmd)

        // Genuinely privileged verbs.
        case matches(head, "INITIALIZE", min: 4):             return noPriv("INITIALIZE")
        case matches(head, "PATCH"):                          return noPriv("PATCH")
        case matches(head, "DEPOSIT", min: 4):                return noPriv("DEPOSIT")

        // File-touching verbs. EDIT launches the in-shell EDT editor;
        // COPY / DELETE / PURGE / RENAME / APPEND / DIFFERENCES all
        // round-trip through scriptStore for .COM files; targets outside
        // the writable namespace fall through to RMS-E-FNF.
        case matches(head, "COPY"):                           return copyCmd(cmd)
        case matches(head, "DELETE", min: 3):                 return deleteCmd(cmd)
        case matches(head, "PURGE", min: 3):                  return purgeCmd(cmd)
        case matches(head, "RENAME", min: 3):                 return renameCmd(cmd)
        case matches(head, "APPEND", min: 3):                 return appendCmd(cmd)
        case matches(head, "EDIT"):
            // In SELFTEST mode return a dry-run line so the test pass
            // doesn't leave the editor active. EDIT defaults to the
            // full-screen change-mode editor; EDIT/LINE keeps the
            // line-mode (asterisk-prompt) editor for those who prefer
            // it (and for compatibility with existing scripts).
            if dryRun { return "%EDT-I-DRYRUN, would open EDT on \(cmd.positional.first ?? "(no file)")\n" }
            if cmd.hasQualifier("LINE", min: 1) {
                return startEdt(cmd)
            }
            return startEdtScreen(cmd)
        case matches(head, "DIFFERENCES", min: 4):            return differencesCmd(cmd)
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
