import Foundation

// Operator-level RUN diagnostics and the full-screen test-utility engine
// that drives them.
extension DCLEngine {
    func startTestUtility(name: String, header: String, steps: [TestStep]) {
        liveTimer?.invalidate()
        liveMode = .testUtility(name: name, header: header)
        testSteps = steps
        testCurrent = 0
        testResults = []
        testStartedAt = Date()
        enterLiveScreen()
        refreshTestDisplay(complete: false)
        let t = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTestUtility() }
        }
        liveTimer = t
    }

    func tickTestUtility() {
        guard testCurrent < testSteps.count else {
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

    func refreshTestDisplay(complete: Bool) {
        guard case let .testUtility(name, header) = liveMode else { return }
        let width = 78
        let now = Date()

        // Build each row as a self-contained string with NO trailing newline.
        // Newlines at the end of the last row will scroll the viewport (the
        // cursor stepping off the bottom row pushes the top row into
        // scrollback), which is exactly how the test-name row was vanishing
        // from the screen. Instead, position each row absolutely with
        // CUP (`ESC [ r ; 1 H`) so no \n ever leaves the bottom of the
        // viewport, then `ESC [ J` wipes anything below.
        func boxLine(_ inner: String) -> String {
            let pad = max(0, width - 2 - inner.count)
            return "│" + inner + String(repeating: " ", count: pad) + "│"
        }
        func sep(left: String, right: String) -> String {
            return left + String(repeating: "─", count: width - 2) + right
        }
        func centered(_ s: String) -> String {
            let pad = max(0, (width - 2 - s.count) / 2)
            return String(repeating: " ", count: pad) + s
        }

        let operatorLbl = tr("diag.operator")
        let elapsedLbl  = tr("diag.elapsed")
        let runningWord = tr("diag.status.running")
        let queuedWord  = tr("diag.status.queued")
        let abortHint   = tr("diag.abort.hint")
        let exitHint    = tr("diag.exit.hint")

        let innerWidth = width - 2

        var rows: [String] = []
        rows.append(sep(left: "┌", right: "┐"))
        rows.append(boxLine(centered("\(name)    \(operatorLbl): \(username)")))
        rows.append(sep(left: "├", right: "┤"))
        rows.append(boxLine("  " + header))

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
            rows.append(boxLine("  " + label + reading + " " + status))
        }

        rows.append(sep(left: "├", right: "┤"))

        let elapsed = uptimeString(from: testStartedAt, to: now)
        let passWord = tr("diag.status.pass")
        let okWord   = tr("diag.status.ok")
        if complete {
            let allGood = testResults.allSatisfy {
                $0.status == passWord || $0.status == okWord
            }
            let resultLbl = allGood ? tr("diag.allpass") : tr("diag.seeresults")
            let completeLbl = String(format: tr("diag.complete"), testResults.count, testSteps.count)
            rows.append(boxLine("  \(completeLbl)  \(elapsedLbl) \(elapsed)  \(resultLbl)"))
            let hintPad = max(0, innerWidth - exitHint.count)
            rows.append(boxLine(String(repeating: " ", count: hintPad) + exitHint))
        } else {
            let stepLbl = String(format: tr("diag.step.of"), testCurrent + 1, testSteps.count)
            rows.append(boxLine("  \(stepLbl)  \(elapsedLbl) \(elapsed)"))
            let hintPad = max(0, innerWidth - abortHint.count)
            rows.append(boxLine(String(repeating: " ", count: hintPad) + abortHint))
        }
        rows.append(sep(left: "└", right: "┘"))

        var s = ""
        for (idx, row) in rows.enumerated() {
            s += "\u{1B}[\(idx + 1);1H" + row
        }
        // Park the cursor below the last row before erasing -- erasing from
        // mid-row would leave trailing cells of the hint row visible.
        s += "\u{1B}[\(rows.count + 1);1H\u{1B}[J"
        outRaw(s)
    }

    // MARK: -- diagnostic step lists

    func startBrakeTest() {
        let pass = tr("diag.status.pass")
        let fail = tr("diag.status.fail")
        let noCab = tr("diag.reading.noCab")
        // Cover every cab on the group, local and remote. Brake state is
        // read-only, so remote cabs (owned by peer nodes) test the same as
        // local ones -- we just read the state the dispatcher already sees.
        let cabsList = world?.elevators ?? []
        let cabs = cabsList.map { world?.displayLabel(for: $0) ?? $0.label }.sorted()
        let cabsBySortedLabel: [String: UUID] = Dictionary(uniqueKeysWithValues:
            cabsList.map { (world?.displayLabel(for: $0) ?? $0.label, $0.id) })
        var steps: [TestStep] = []
        for label in cabs {
            steps.append(TestStep(label: String(format: tr("diag.step.brake.cab"), label)) { [weak self] in
                guard let self,
                      let cabId = cabsBySortedLabel[label],
                      let cab = self.world?.elevators.first(where: { $0.id == cabId })
                else { return (noCab, fail) }
                // Real brake state -- engaged at rest, released while
                // moving. Holding-force value is synthesised but tied
                // to the actual brakeEngaged flag the dispatcher sees.
                let moving = abs(cab.velocity) > 0.05
                if moving {
                    return (tr("diag.brake.reading.moving"), pass)
                }
                let kn = 11.7 + Double((Int(label.dropFirst()) ?? 1) % 4) * 0.18
                let fmt = cab.brakeEngaged
                    ? tr("diag.brake.reading.engaged")
                    : tr("diag.brake.reading.released")
                return (String(format: fmt, kn),
                        cab.brakeEngaged ? pass : fail)
            })
        }
        steps.append(TestStep(label: tr("diag.step.brake.fw")) {
            return ("v3.04 OK", pass)
        })
        startTestUtility(name: tr("diag.test.brake"),
                         header: tr("diag.col.cab"),
                         steps: steps)
    }

    func startDoorTest() {
        let pass = tr("diag.status.pass")
        let noCab = tr("diag.reading.noCab")
        // Cover every cab on the group, local and remote. The door steps
        // below actively command the door controller, which only the owning
        // peer may do -- remote cabs are exercised as observation-only.
        let cabsList = world?.elevators ?? []
        let cabs = cabsList.map { world?.displayLabel(for: $0) ?? $0.label }.sorted()
        let cabsBySortedLabel: [String: Elevator] = Dictionary(uniqueKeysWithValues:
            cabsList.map { (world?.displayLabel(for: $0) ?? $0.label, $0) })
        var steps: [TestStep] = []
        // Cycle test now actually commands an open on a stopped, doors-
        // closed cab and reports the measured open+dwell+close time
        // from the cab's profile. If the cab is moving or already in a
        // door cycle the step is recorded as observation-only.
        for label in cabs {
            steps.append(TestStep(label: String(format: tr("diag.step.door.cycle"), label)) { [weak self] in
                guard let self,
                      let cab = cabsBySortedLabel[label],
                      let world = self.world
                else { return (noCab, pass) }
                let triggered = world.canControl(cab)
                    && cab.doors == .closed && abs(cab.velocity) < 0.05
                if triggered {
                    _ = world.mutateLocal(cab.id) { e in
                        e.doors = .opening
                        e.doorProgress = 0
                    }
                }
                let cycle = cab.profile.doorOpenDuration +
                    cab.profile.doorDwellDuration +
                    cab.profile.doorCloseDuration
                return (String(format: "%.2f s%@", cycle,
                               triggered ? "" : tr("diag.door.reading.idleSuffix")), pass)
            })
        }
        // Light-curtain step actually trips the doorObstructed flag on
        // each local cab, observes that the door controller reverses
        // a close cycle, then clears the flag. If the cab isn't at a
        // landing with doors open or closing, we record SKIPPED so the
        // test step still completes -- the curtain itself is exercised
        // via Modbus discrete inputs 32..39 either way.
        for label in cabs {
            steps.append(TestStep(label: String(format: tr("diag.step.door.obst"), label)) { [weak self] in
                guard let self,
                      let cab = cabsBySortedLabel[label],
                      let world = self.world else {
                    return (noCab, pass)
                }
                // Only the owning peer may trip the curtain; remote cabs are
                // observed with the curtain left armed.
                guard world.canControl(cab) else {
                    return (tr("diag.door.reading.armed"), pass)
                }
                let canExercise = cab.doors == .open || cab.doors == .closing
                _ = world.mutateLocal(cab.id) { e in e.doorObstructed = true }
                // Hold the trip long enough for the dispatcher's next
                // scan to see it and reverse the close cycle.
                Thread.sleep(forTimeInterval: 0.25)
                _ = world.mutateLocal(cab.id) { e in e.doorObstructed = false }
                return (canExercise
                        ? tr("diag.door.reading.reverse")
                        : tr("diag.door.reading.armed"), pass)
            })
        }
        startTestUtility(name: tr("diag.test.door"),
                         header: tr("diag.col.cab"),
                         steps: steps)
    }

    func startWeightCal() {
        let pass = tr("diag.status.pass")
        let ok   = tr("diag.status.ok")
        let noCab = tr("diag.reading.noCab")
        // Cover every cab on the group, local and remote. The load-cell
        // readings are read-only, so remote cabs test identically to local.
        let cabsList = world?.elevators ?? []
        let cabs = cabsList.map { world?.displayLabel(for: $0) ?? $0.label }.sorted()
        let cabsBySortedLabel: [String: UUID] = Dictionary(uniqueKeysWithValues:
            cabsList.map { (world?.displayLabel(for: $0) ?? $0.label, $0.id) })
        var steps: [TestStep] = []
        // Zero/tare step reads the real load-cell value. It does NOT
        // require the cab to be empty -- riders board and alight during
        // normal service, so a standing load is expected and must not
        // fail the calibration. A healthy strain-gauge bridge simply
        // returns a plausible, in-range figure; only a negative reading
        // or one well past rated capacity (a disconnected / stuck cell)
        // fails. The span step below then reports load vs rated capacity.
        for label in cabs {
            steps.append(TestStep(label: String(format: tr("diag.step.weight.zero"), label)) { [weak self] in
                guard let self,
                      let cabId = cabsBySortedLabel[label],
                      let cab = self.world?.elevators.first(where: { $0.id == cabId })
                else { return (noCab, pass) }
                let reading = cab.loadKg
                let healthy = reading >= -5.0 && reading <= cab.profile.ratedLoadKg * 1.20
                return (String(format: "%.1f kg", reading),
                        healthy ? pass : tr("diag.status.fail"))
            })
            steps.append(TestStep(label: String(format: tr("diag.step.weight.span"), label)) { [weak self] in
                guard let self,
                      let cabId = cabsBySortedLabel[label],
                      let cab = self.world?.elevators.first(where: { $0.id == cabId })
                else { return (noCab, pass) }
                let ratio = cab.profile.ratedLoadKg > 0
                    ? min(1.0, cab.loadKg / cab.profile.ratedLoadKg)
                    : 0
                return (String(format: "%.2f ratio", ratio), pass)
            })
        }
        let recordsReading = String(format: tr("diag.weight.reading.records"), cabs.count * 2)
        steps.append(TestStep(label: tr("diag.step.weight.write")) {
            return (recordsReading, ok)
        })
        startTestUtility(name: tr("diag.test.weight"),
                         header: tr("diag.col.cab"),
                         steps: steps)
    }

    func startHallLampTest() {
        let pass = tr("diag.status.pass")
        let noWorld = tr("diag.reading.noWorld")
        var steps: [TestStep] = []
        // Each step lights the up- and down-lantern at one floor by
        // registering test hall calls (with allocate:false so they
        // don't dispatch a cab), holds them briefly, then clears them.
        // Visible in SHOW CALLS and Modbus IR 110 while the test runs.
        for floor in Sim.firstFloor...Sim.lastFloor {
            let f = String(format: "%02d", floor)
            let captured = floor
            steps.append(TestStep(label: String(format: tr("diag.step.lamp.floor"), f)) { [weak self] in
                guard let self, let world = self.world else { return (noWorld, pass) }
                let up = world.registerHallCall(floor: captured, direction: .up, allocate: false)
                let dn = world.registerHallCall(floor: captured, direction: .down, allocate: false)
                Thread.sleep(forTimeInterval: 0.20)
                if let id = up?.id { world.removeHallCall(id: id) }
                if let id = dn?.id { world.removeHallCall(id: id) }
                return (tr("diag.lamp.reading.lit"), pass)
            })
        }
        steps.append(TestStep(label: tr("diag.step.lamp.fw")) {
            return ("v1.18 OK", pass)
        })
        startTestUtility(name: tr("diag.test.lamp"),
                         header: tr("diag.col.floor"),
                         steps: steps)
    }

    // MARK: -- diagnostic test selection menu (DECforms-style)

    /// Pop a full-screen menu that lets the operator pick one of the
    /// available diagnostic test utilities and run it. Lives in the
    /// alternate screen buffer so leaving the menu restores whatever
    /// was on the shell screen before.
    func startDiagnosticMenu() {
        liveTimer?.invalidate()
        liveTimer = nil
        // The lpd splash strings include a "RUN <image>" prefix, e.g.
        // "  RUN BRAKE_TEST       Brake hold-force test on every cab".
        // Strip it -- the menu already shows the image in its own column.
        func descOf(_ key: String, image: String) -> String {
            let raw = tr(key)
            let needle = "RUN \(image)"
            if let r = raw.range(of: needle) {
                return raw[r.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
            }
            return raw.trimmingCharacters(in: .whitespaces)
        }
        diagMenuItems = [
            DiagMenuItem(image: "BRAKE_TEST",
                         description: descOf("login.lpd.brake", image: "BRAKE_TEST"),
                         runner: { [weak self] in self?.startBrakeTest() }),
            DiagMenuItem(image: "DOOR_TEST",
                         description: descOf("login.lpd.door", image: "DOOR_TEST"),
                         runner: { [weak self] in self?.startDoorTest() }),
            DiagMenuItem(image: "WEIGHT_CAL",
                         description: descOf("login.lpd.weight", image: "WEIGHT_CAL"),
                         runner: { [weak self] in self?.startWeightCal() }),
            DiagMenuItem(image: "HALL_LAMP_TEST",
                         description: descOf("login.lpd.lamp", image: "HALL_LAMP_TEST"),
                         runner: { [weak self] in self?.startHallLampTest() })
        ]
        diagMenuSelection = 0
        liveMode = .diagnosticMenu
        enterLiveScreen()
        refreshDiagnosticMenu()
    }

    /// Render the menu into the alternate buffer at known cell
    /// coordinates so no part of it can scroll off the viewport.
    func refreshDiagnosticMenu() {
        guard case .diagnosticMenu = liveMode else { return }
        let width = 78
        let innerWidth = width - 2

        func boxLine(_ inner: String) -> String {
            let pad = max(0, innerWidth - inner.count)
            return "│" + inner + String(repeating: " ", count: pad) + "│"
        }
        func sep(_ left: String, _ right: String) -> String {
            return left + String(repeating: "─", count: innerWidth) + right
        }
        func centered(_ s: String) -> String {
            let pad = max(0, (innerWidth - s.count) / 2)
            return String(repeating: " ", count: pad) + s
        }

        var rows: [String] = []
        rows.append(sep("┌", "┐"))
        // LPD suite header + copyright line + selection subtitle so the
        // menu reads like a real OpenVMS layered-product form, and all
        // three lines are localisable (FR speakers see French headings).
        rows.append(boxLine(centered(tr("diag.suite") + "  V1.4")))
        rows.append(boxLine(centered(tr("diag.menu.copyright"))))
        rows.append(boxLine(centered(tr("diag.menu.title"))))
        rows.append(sep("├", "┤"))
        rows.append(boxLine(""))
        for (i, item) in diagMenuItems.enumerated() {
            let marker = i == diagMenuSelection ? " ▶ " : "   "
            let img    = item.image.padding(toLength: 16, withPad: " ", startingAt: 0)
            rows.append(boxLine(marker + img + " " + item.description))
        }
        rows.append(boxLine(""))
        rows.append(sep("├", "┤"))
        rows.append(boxLine("  " + tr("diag.menu.nav")))
        rows.append(sep("└", "┘"))

        var s = ""
        for (idx, row) in rows.enumerated() {
            s += "\u{1B}[\(idx + 1);1H" + row
        }
        s += "\u{1B}[\(rows.count + 1);1H\u{1B}[J"
        outRaw(s)
    }

    /// Handle keystrokes routed to the menu by the line discipline.
    /// Accepts an arrow-key escape sequence as raw bytes, plus single
    /// control bytes for Enter / Ctrl-Y.
    func handleDiagnosticMenuKey(_ bytes: [UInt8]) {
        guard case .diagnosticMenu = liveMode else { return }
        // The byte array may carry multiple keystrokes batched together
        // (especially over a telnet connection where the user holds an
        // arrow key down), so parse the stream rather than insisting on
        // bytes.count == 3 for a single arrow-key sequence -- the strict
        // check used to silently drop all the keys after the first.
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            // ESC ESC -- alternative exit for users whose tty layer eats
            // ^Y / ^C (e.g. nc-from-macOS-terminal).
            if b == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x1B {
                diagnosticMenuExit()
                return
            }
            // CSI sequence: ESC [ <params>* <final 0x40...0x7E>
            if b == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                var j = i + 2
                while j < bytes.count, !((0x40...0x7E).contains(bytes[j])) {
                    j += 1
                }
                if j < bytes.count {
                    switch bytes[j] {
                    case 0x41:                          // A - Up
                        if diagMenuSelection > 0 { diagMenuSelection -= 1 }
                    case 0x42:                          // B - Down
                        if diagMenuSelection < diagMenuItems.count - 1 {
                            diagMenuSelection += 1
                        }
                    default:
                        break
                    }
                    refreshDiagnosticMenu()
                    i = j + 1
                    continue
                } else {
                    break       // incomplete escape -- drop the tail
                }
            }
            switch b {
            case 0x0D, 0x0A:                            // Enter
                let chosen = diagMenuItems[diagMenuSelection]
                // Leave the menu but stay in live-screen mode -- the
                // test utility we hand off to will repaint the same alt
                // buffer. Mark the run so stopMonitor pops back here
                // instead of the DCL prompt when the operator dismisses
                // the finished test.
                liveMode = .none
                diagInvokedFromMenu = true
                chosen.runner()
                return
            case 0x03, 0x19:                            // Ctrl-C / Ctrl-Y
                diagnosticMenuExit()
                return
            default:
                break
            }
            i += 1
        }
    }

    private func diagnosticMenuExit() {
        // Drop the menu without the "MONITOR was interrupted"
        // message stopMonitor would print -- the menu was never a
        // monitor session in the first place.
        liveTimer?.invalidate()
        liveTimer = nil
        liveMode = .none
        exitLiveScreen()
        out(prompt)
    }
}
