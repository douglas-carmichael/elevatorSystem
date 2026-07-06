import Foundation
import Combine

// Interactive OpenVMS MAIL utility.
//
//   $ MAIL
//   MAIL> DIRECTORY / READ / NEXT / BACK / SEND / REPLY / FORWARD / DELETE ...
//   MAIL> EXIT
//
// Typed bare at an interactive prompt, `MAIL` opens a MAIL> subshell that
// behaves like the real thing: it keeps a "current message" pointer, lets
// you page through the folder, and drives a To: / Subj: / body compose
// sequence for SEND / REPLY / FORWARD (the body is terminated with CTRL/Z,
// or ESC ESC for telnet users whose tty eats CTRL/Z -- the same fallback
// the EDT screen editor uses).
//
// The subshell reuses the line-mode routing already built for EDT: while
// `mailActive` is set, DCLEngine.submit() hands each line to runMailLine()
// instead of the DCL dispatcher, and the compose body is captured line by
// line until the line discipline calls endMailMessage() on CTRL/Z.
//
// The inbox itself is the same MAILBOX.JSON the rest of the engine already
// persists; the building writes in-universe status mail into it (see the
// in-universe generator at the bottom of this file).
extension DCLEngine {

    // MARK: -- entry / exit

    /// Open the MAIL> subshell. Returns the banner + inbox summary; the
    /// caller (submit) emits the MAIL> prompt afterwards.
    func enterMailSubshell() -> String {
        mailActive = true
        mailPreviousPrompt = prompt
        mailCompose = .none
        mailComposeTo = ""
        mailComposeSubject = ""
        mailComposeBody = []
        // Current message = first unread, else the last message, else none.
        mailCurrentId = mailbox.first(where: { !$0.read })?.id ?? mailbox.last?.id
        prompt = "MAIL> "

        var s = "\n        \(osTitle) Personal Mail Utility\n"
        s += "        \(stamp(Date()))\n\n"
        let unread = mailbox.filter { !$0.read }.count
        if mailbox.isEmpty {
            s += "You have no messages.\n"
        } else if unread == 0 {
            s += "You have \(mailbox.count) message\(mailbox.count == 1 ? "" : "s") (0 new).\n"
        } else {
            s += "You have \(unread) new message\(unread == 1 ? "" : "s") of \(mailbox.count) total.\n"
        }
        s += "Type ? or HELP for the command list, EXIT to leave.\n"
        return s
    }

    /// Leave the subshell and restore the DCL prompt.
    func mailExit() -> String {
        mailActive = false
        mailCompose = .none
        mailComposeTo = ""
        mailComposeSubject = ""
        mailComposeBody = []
        prompt = mailPreviousPrompt.isEmpty ? "$ " : mailPreviousPrompt
        return ""
    }

    // MARK: -- line routing

    /// Route one input line while the MAIL> subshell is active. Returns
    /// transcript text to append; the engine has already echoed the prompt.
    func runMailLine(_ raw: String) -> String {
        // Compose sub-mode: gather To / Subj, then body lines. The body is
        // finished out-of-band by the line discipline calling
        // endMailMessage() on CTRL/Z (or ESC ESC).
        switch mailCompose {
        case .awaitingTo:
            let to = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if to.isEmpty { return cancelMailCompose() }
            mailComposeTo = to
            // If the subject was pre-filled (REPLY / FORWARD), skip straight
            // to the message body; otherwise prompt for it.
            if mailComposeSubject.isEmpty {
                mailCompose = .awaitingSubject
                prompt = "Subj:\t"
                return ""
            }
            mailCompose = .body
            prompt = ""
            return mailBodyPrompt()

        case .awaitingSubject:
            mailComposeSubject = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            mailCompose = .body
            prompt = ""
            return mailBodyPrompt()

        case .body:
            mailComposeBody.append(raw)
            return ""

        case .none:
            break
        }

        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare Return at MAIL> reads the next message, matching real MAIL.
        if line.isEmpty { return mailReadNext() }

        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let verb = parts[0].uppercased()
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch true {
        case verb == "?", mailMatch(verb, "HELP", min: 1):        return mailHelp()
        case mailMatch(verb, "DIRECTORY", min: 3):                return mailDirectory()
        case mailMatch(verb, "READ", min: 1):                     return mailRead(rest)
        case mailMatch(verb, "REPLY", min: 3):                    return mailBeginReply()
        case mailMatch(verb, "NEXT", min: 1):                     return mailReadNext()
        case mailMatch(verb, "BACK", min: 1):                     return mailReadBack()
        case mailMatch(verb, "FIRST", min: 2):                    return mailReadFirst()
        case mailMatch(verb, "LAST", min: 1):                     return mailReadLast()
        case mailMatch(verb, "CURRENT", min: 1):                  return mailReadCurrent()
        case mailMatch(verb, "SEND", min: 1):                     return mailBeginSend(rest)
        case mailMatch(verb, "FORWARD", min: 2):                  return mailBeginForward(rest)
        case mailMatch(verb, "DELETE", min: 3):                   return mailDelete(rest)
        case mailMatch(verb, "EXTRACT", min: 3):                  return mailExtract(rest)
        case mailMatch(verb, "PRINT", min: 1):                    return mailPrint(rest)
        case mailMatch(verb, "EXIT", min: 2):                     return mailExit()
        case mailMatch(verb, "QUIT", min: 1):                     return mailExit()
        default:
            // A bare number reads that message (real MAIL behaviour).
            if let n = Int(verb) { return mailRead(String(n)) }
            fail("MAIL-W-ILLSUBCMD", "%X0003C08C")
            return "%MAIL-W-ILLSUBCMD, unrecognized or ambiguous MAIL command \"\(verb)\"\n"
        }
    }

    // MARK: -- reading / navigation

    private func mailIndex(ofId id: Int) -> Int? {
        mailbox.firstIndex { $0.id == id }
    }

    private func mailCurrentIndex() -> Int? {
        mailCurrentId.flatMap(mailIndex(ofId:))
    }

    /// Mark the message at `idx` read, make it current, and format it.
    private func displayMessage(at idx: Int) -> String {
        if !mailbox[idx].read {
            mailbox[idx].read = true
            persistMailbox()
        }
        mailCurrentId = mailbox[idx].id
        let m = mailbox[idx]
        var s = "\n"
        s += "#\(m.id)  \(stamp(m.received))  \(m.read ? "" : "NEWMAIL")\n"
        s += "From:\t\(m.from)\n"
        s += "To:\t\(username)\n"
        s += "Subj:\t\(m.subject)\n\n"
        s += m.body
        if !m.body.hasSuffix("\n") { s += "\n" }
        return s
    }

    func mailRead(_ rest: String) -> String {
        guard !mailbox.isEmpty else { return "%MAIL-E-NOMSGS, no messages\n" }
        if let n = Int(rest.trimmingCharacters(in: .whitespaces)) {
            guard let idx = mailIndex(ofId: n) else {
                return "%MAIL-E-NOTEXIST, no such message: \(n)\n"
            }
            return displayMessage(at: idx)
        }
        // No number: current message, else first unread, else the first.
        let idx = mailCurrentIndex()
            ?? mailbox.firstIndex(where: { !$0.read })
            ?? 0
        return displayMessage(at: idx)
    }

    func mailReadNext() -> String {
        guard !mailbox.isEmpty else { return "%MAIL-E-NOMSGS, no messages\n" }
        let nextIdx = (mailCurrentIndex().map { $0 + 1 }) ?? 0
        guard nextIdx < mailbox.count else { return "%MAIL-E-NOMOREMSG, no more messages\n" }
        return displayMessage(at: nextIdx)
    }

    func mailReadBack() -> String {
        guard !mailbox.isEmpty else { return "%MAIL-E-NOMSGS, no messages\n" }
        let idx = mailCurrentIndex() ?? 0
        guard idx - 1 >= 0 else { return "%MAIL-E-NOMOREMSG, no previous message\n" }
        return displayMessage(at: idx - 1)
    }

    func mailReadFirst() -> String {
        guard !mailbox.isEmpty else { return "%MAIL-E-NOMSGS, no messages\n" }
        return displayMessage(at: 0)
    }

    func mailReadLast() -> String {
        guard !mailbox.isEmpty else { return "%MAIL-E-NOMSGS, no messages\n" }
        return displayMessage(at: mailbox.count - 1)
    }

    func mailReadCurrent() -> String {
        guard !mailbox.isEmpty else { return "%MAIL-E-NOMSGS, no messages\n" }
        return displayMessage(at: mailCurrentIndex() ?? 0)
    }

    func mailDirectory() -> String {
        if mailbox.isEmpty { return "%MAIL-E-NOMSGS, no messages\n" }
        var s = "\n     #  From            Date              Subject\n"
        s +=   "     --  --------------  ----------------  --------------------------------\n"
        for m in mailbox {
            let cur  = (m.id == mailCurrentId) ? ">" : " "
            let mark = m.read ? " " : "N"
            let from = m.from.padding(toLength: 14, withPad: " ", startingAt: 0)
            let when = stamp(m.received).padding(toLength: 16, withPad: " ", startingAt: 0)
            let subj = m.subject.count > 32 ? String(m.subject.prefix(29)) + "..." : m.subject
            s += String(format: " %@%@ %3d  %@  %@  %@\n", cur, mark, m.id, from, when, subj)
        }
        return s
    }

    // MARK: -- delete / extract / print

    func mailDelete(_ rest: String) -> String {
        guard !mailbox.isEmpty else { return "%MAIL-E-NOMSGS, no messages\n" }
        let idx: Int
        if let n = Int(rest.trimmingCharacters(in: .whitespaces)) {
            guard let i = mailIndex(ofId: n) else {
                return "%MAIL-E-NOTEXIST, no such message: \(n)\n"
            }
            idx = i
        } else if let cur = mailCurrentIndex() {
            idx = cur
        } else {
            return "%MAIL-E-NOCURMSG, no current message; specify a number\n"
        }
        let delId = mailbox[idx].id
        mailbox.remove(at: idx)
        // Advance the current pointer to the message that slid into this
        // slot, or the new last message if we deleted the tail.
        if mailCurrentId == delId {
            mailCurrentId = idx < mailbox.count ? mailbox[idx].id : mailbox.last?.id
        }
        persistMailbox()
        return "%MAIL-I-DELETED, message \(delId) deleted\n"
    }

    func mailExtract(_ rest: String) -> String {
        guard let idx = mailCurrentIndex() else {
            return "%MAIL-E-NOCURMSG, no current message\n"
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return "%MAIL-E-NOFILE, usage: EXTRACT filename\n"
        }
        let m = mailbox[idx]
        let dest = scriptStore.normalize(name)
        var text = "From:\t\(m.from)\nDate:\t\(stamp(m.received))\nSubj:\t\(m.subject)\n\n"
        text += m.body
        if !text.hasSuffix("\n") { text += "\n" }
        scriptStore.write(name: dest, body: text)
        return "%MAIL-I-EXTRACTED, message \(m.id) written to \(dest)\n"
    }

    func mailPrint(_ rest: String) -> String {
        guard !mailbox.isEmpty else { return "%MAIL-E-NOMSGS, no messages\n" }
        let idx: Int
        if let n = Int(rest.trimmingCharacters(in: .whitespaces)) {
            guard let i = mailIndex(ofId: n) else {
                return "%MAIL-E-NOTEXIST, no such message: \(n)\n"
            }
            idx = i
        } else if let cur = mailCurrentIndex() {
            idx = cur
        } else {
            return "%MAIL-E-NOCURMSG, no current message; specify a number\n"
        }
        let m = mailbox[idx]
        let lisName = "MAIL_\(m.id).LIS"
        var text = "From:\t\(m.from)\nDate:\t\(stamp(m.received))\nSubj:\t\(m.subject)\n\n"
        text += m.body
        if !text.hasSuffix("\n") { text += "\n" }
        scriptStore.write(name: scriptStore.normalize(lisName), body: text)
        let entry = Int.random(in: 1000...9999)
        return "Job \(lisName) (queue SYS$PRINT, entry \(entry)) started on SYS$PRINT\n"
    }

    // MARK: -- compose (SEND / REPLY / FORWARD)

    private func mailBodyPrompt() -> String {
        "Enter your message below. Press CTRL/Z when complete, CTRL/C to quit:\n"
    }

    func mailBeginSend(_ rest: String) -> String {
        mailComposeSubject = ""
        mailComposeBody = []
        let addr = rest.trimmingCharacters(in: .whitespaces)
        if addr.isEmpty {
            mailComposeTo = ""
            mailCompose = .awaitingTo
            prompt = "To:\t"
            return ""
        }
        mailComposeTo = addr
        mailCompose = .awaitingSubject
        prompt = "Subj:\t"
        return ""
    }

    func mailBeginReply() -> String {
        guard let idx = mailCurrentIndex() else {
            return "%MAIL-E-NOCURMSG, no current message to reply to\n"
        }
        let m = mailbox[idx]
        mailComposeTo = m.from
        mailComposeSubject = m.subject.uppercased().hasPrefix("RE:") ? m.subject : "RE: \(m.subject)"
        mailComposeBody = []
        mailCompose = .body
        prompt = ""
        var s = "To:\t\(mailComposeTo)\n"
        s += "Subj:\t\(mailComposeSubject)\n"
        s += mailBodyPrompt()
        return s
    }

    func mailBeginForward(_ rest: String) -> String {
        guard let idx = mailCurrentIndex() else {
            return "%MAIL-E-NOCURMSG, no current message to forward\n"
        }
        let m = mailbox[idx]
        mailComposeSubject = m.subject.uppercased().hasPrefix("FWD:") ? m.subject : "FWD: \(m.subject)"
        // Pre-load the body with the forwarded message; the operator can add
        // a note before CTRL/Z.
        mailComposeBody = ["", "---------- Forwarded message ----------",
                           "From: \(m.from)   Date: \(stamp(m.received))",
                           "Subj: \(m.subject)", ""]
            + m.body.components(separatedBy: "\n")
        let addr = rest.trimmingCharacters(in: .whitespaces)
        if addr.isEmpty {
            mailComposeTo = ""
            mailCompose = .awaitingTo
            prompt = "To:\t"
            return ""
        }
        mailComposeTo = addr
        mailCompose = .body
        prompt = ""
        var s = "Subj:\t\(mailComposeSubject)\n"
        s += "Forwarded text loaded. Add a note, then press CTRL/Z to send:\n"
        return s
    }

    private func cancelMailCompose() -> String {
        mailCompose = .none
        mailComposeTo = ""
        mailComposeSubject = ""
        mailComposeBody = []
        prompt = "MAIL> "
        return "%MAIL-W-NOSENT, no recipient; message not sent\n"
    }

    /// Finalize and send the message being composed. Called by the line
    /// discipline when it sees CTRL/Z (or ESC ESC) during body capture; the
    /// current partial input line (typed but not yet Return-ed) is passed in
    /// as the last body line.
    func endMailMessage(partial: String) {
        guard mailComposingBody else { return }
        if !partial.isEmpty {
            mailComposeBody.append(partial)
            // The prompt is empty during body capture, so echo the last line
            // to the transcript on its own for SELFTEST / test introspection.
            transcript += "\(partial)\n"
        }
        let to = mailComposeTo
        let subject = mailComposeSubject.isEmpty ? "(no subject)" : mailComposeSubject
        var body = mailComposeBody.joined(separator: "\n")
        if !body.hasSuffix("\n") { body += "\n" }

        // Loopback delivery so SEND -> READ round-trips within the sim; the
        // inbox copy is stamped from this operator (the sender).
        appendMail(from: username, subject: subject, body: body)

        mailCompose = .none
        mailComposeTo = ""
        mailComposeSubject = ""
        mailComposeBody = []
        prompt = "MAIL> "
        out("%MAIL-S-SENT, message sent to \(to.uppercased())\n")
        if !loggedOut { out(prompt) }
    }

    /// Abort the message being composed. Called by the line discipline on
    /// CTRL/C during any compose sub-state.
    func abortMailMessage() {
        guard mailComposing else { return }
        mailCompose = .none
        mailComposeTo = ""
        mailComposeSubject = ""
        mailComposeBody = []
        prompt = "MAIL> "
        out("\r\n%MAIL-W-NOSENT, message aborted\n")
        if !loggedOut { out(prompt) }
    }

    // MARK: -- HELP

    private func mailHelp() -> String {
        var s = "\n  MAIL subcommands\n"
        s += "  ----------------\n"
        s += "    DIRECTORY            List the messages in the folder.\n"
        s += "    READ [n]             Read message n (or the current / first-new message).\n"
        s += "    <Return>             Read the next message.\n"
        s += "    NEXT / BACK          Step to the next / previous message.\n"
        s += "    FIRST / LAST         Jump to the first / last message.\n"
        s += "    CURRENT              Redisplay the current message.\n"
        s += "    SEND [addr]          Compose a message (prompts To / Subj / text).\n"
        s += "    REPLY                Reply to the current message.\n"
        s += "    FORWARD [addr]       Forward the current message.\n"
        s += "    DELETE [n]           Delete message n (or the current message).\n"
        s += "    EXTRACT file         Write the current message to a file.\n"
        s += "    PRINT [n]            Queue a message to SYS$PRINT.\n"
        s += "    EXIT / QUIT          Leave MAIL and return to DCL.\n"
        s += "\n  While composing, end the message with CTRL/Z (or ESC ESC over\n"
        s += "  telnet); CTRL/C abandons it.\n"
        return s
    }

    // MARK: -- shared inbox helper

    /// Append a message to the inbox and persist. Returns the new id.
    @discardableResult
    func appendMail(from: String, subject: String, body: String, received: Date = Date()) -> Int {
        let id = nextMailId
        mailbox.append(MailMessage(id: id,
                                   from: from,
                                   subject: subject,
                                   body: body,
                                   received: received,
                                   read: false))
        nextMailId += 1
        persistMailbox()
        return id
    }

    // MARK: -- in-universe status-mail generator
    //
    // The simulated building "writes" mail to the operator as its state
    // changes -- SCADA raising a serious alarm, the building going into
    // fire-recall / emergency-power, or the group switching dispatch
    // strategy. These land in the same inbox the operator reads with MAIL,
    // so the utility has live in-universe traffic to work with.

    func subscribeInUniverseMail() {
        guard let world = world else { return }
        mailWorldCancellables.forEach { $0.cancel() }
        mailWorldCancellables.removeAll()

        // Watermark against the state that already exists at login so we
        // don't backfill the inbox with mail for pre-existing conditions.
        lastMailedAlarmSequence = world.alarmLog.map(\.sequence).max() ?? 0
        lastMailedBuildingMode = world.buildingMode
        lastMailedDispatchMode = world.dispatchMode

        world.$alarmLog
            .sink { [weak self] log in self?.mailNewAlarms(log) }
            .store(in: &mailWorldCancellables)
        world.$buildingMode
            .dropFirst()
            .sink { [weak self] mode in self?.mailBuildingModeChange(mode) }
            .store(in: &mailWorldCancellables)
        world.$dispatchMode
            .dropFirst()
            .sink { [weak self] mode in self?.mailDispatchModeChange(mode) }
            .store(in: &mailWorldCancellables)
    }

    /// Deliver an in-universe message and, unless a full-screen or compose
    /// mode owns the terminal, print the OpenVMS "New mail" broadcast (the
    /// same unobtrusive pattern SUBMIT uses for its OPCOM completion line).
    private func deliverInUniverseMail(from: String, subject: String, body: String) {
        appendMail(from: from, subject: subject, body: body)
        guard outputHandler != nil,
              !liveActive, !editorActive, !mailActive else { return }
        out("\r\nNew mail on node \(nodeName) from \(from)\n")
    }

    /// How long the same alarm point stays quiet after a notice before it
    /// may generate another. Long enough that a point flapping as cabs run
    /// doesn't clutter the inbox, short enough that a genuinely new incident
    /// hours later still notifies.
    private static let alarmMailCooldown: TimeInterval = 600

    private func mailNewAlarms(_ log: [SCADAAlarm]) {
        let fresh = log.filter { $0.sequence > lastMailedAlarmSequence }
        if let maxSeq = log.map(\.sequence).max() {
            lastMailedAlarmSequence = max(lastMailedAlarmSequence, maxSeq)
        }
        let now = Date()
        // Only CRITICAL, still-active alarms are worth an inbox notice, and
        // then only once per point per cooldown window -- the major/minor
        // tiers and rapidly re-raised points would otherwise flood the box.
        for a in fresh where a.isActive && a.severity == .critical {
            let key = "\(a.source)|\(a.point)"
            if let last = lastMailedAlarmKeyAt[key],
               now.timeIntervalSince(last) < Self.alarmMailCooldown {
                continue
            }
            lastMailedAlarmKeyAt[key] = now
            var body = "SCADA event \(a.sequence) raised \(stamp(a.raisedAt)).\n\n"
            body += "  Source:   \(a.source)\n"
            body += "  Point:    \(a.point)\n"
            body += "  Severity: \(a.severity.label)\n"
            body += "  Message:  \(a.message)\n\n"
            body += "Acknowledge with  ACKNOWLEDGE ALARM ALL  or clear the fault at the panel.\n"
            deliverInUniverseMail(from: "SCADA$MGR",
                                  subject: "\(a.severity.label) alarm: \(a.source) \(a.point)",
                                  body: body)
        }
    }

    private func mailBuildingModeChange(_ mode: BuildingMode) {
        guard mode != lastMailedBuildingMode else { return }
        lastMailedBuildingMode = mode
        let recall = world?.recallFloor ?? Sim.firstFloor
        let subject: String
        let line: String
        switch mode {
        case .normal:
            subject = "Building returned to NORMAL"
            line = "All safety recalls cleared; normal group dispatch has resumed."
        case .fireRecall:
            subject = "FIRE RECALL initiated"
            line = "Phase I fire recall is active. All cars are recalled to floor \(recall)."
        case .emergencyPower:
            subject = "EMERGENCY POWER operation"
            line = "Building is on emergency power. Cars are sequenced to floor \(recall); one car is retained in service."
        }
        deliverInUniverseMail(from: "OPCOM",
                              subject: subject,
                              body: "\(stamp(Date()))\n\n\(line)\n")
    }

    private func mailDispatchModeChange(_ mode: DispatchMode) {
        guard mode != lastMailedDispatchMode else { return }
        lastMailedDispatchMode = mode
        let line: String
        switch mode {
        case .collective:
            line = "Group control switched to COLLECTIVE dispatch."
        case .destination:
            line = "Group control switched to DESTINATION dispatch; hall keypads now allocate cars."
        }
        deliverInUniverseMail(from: "ELEVATOR$CONTROL",
                              subject: "Dispatch strategy changed",
                              body: "\(stamp(Date()))\n\n\(line)\n")
    }

    // MARK: -- helpers

    private func mailMatch(_ token: String, _ canonical: String, min: Int) -> Bool {
        let t = token.uppercased()
        return t.count >= min && canonical.hasPrefix(t)
    }
}
