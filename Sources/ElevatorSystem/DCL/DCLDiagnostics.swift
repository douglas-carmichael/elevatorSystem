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

    // MARK: -- diagnostic step lists

    func startBrakeTest() {
        let pass = tr("diag.status.pass")
        let cabs = (world?.elevators.map { world?.displayLabel(for: $0) ?? $0.label }.sorted()) ?? ["L01","L02","L03"]
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

    func startDoorTest() {
        let pass = tr("diag.status.pass")
        let cabs = (world?.elevators.map { world?.displayLabel(for: $0) ?? $0.label }.sorted()) ?? ["L01","L02","L03"]
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

    func startWeightCal() {
        let pass = tr("diag.status.pass")
        let ok   = tr("diag.status.ok")
        let cabs = (world?.elevators.map { world?.displayLabel(for: $0) ?? $0.label }.sorted()) ?? ["L01","L02","L03"]
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

    func startHallLampTest() {
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
}
