import SwiftUI
import AppKit

struct ControlPanelWindow: View {
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var automation: AutoDriver
    @Environment(\.openWindow) private var openWindow

    @State private var focusedCabId: UUID?
    @State private var showHelp: Bool = false
    @State private var showCredits: Bool = false
    @State private var showModbusLegend: Bool = false

    var body: some View {
        ZStack {
            RetroTheme.bg.ignoresSafeArea()
            KeyboardHost(onKey: handleKey)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
            VStack(spacing: 14) {
                BannerHeader()
                StatusStrip()
                SCADAAlarmPanel()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(world.sortedElevators) { elev in
                            ElevatorPanel(elevator: elev,
                                          focused: focusedCabId == elev.id)
                        }
                    }
                    .padding(.top, 8)
                }
                FooterBar(showCredits: $showCredits)
            }
            .padding(20)
            if showHelp {
                HelpOverlay(onDismiss: { showHelp = false })
                    .transition(.opacity)
            }
            if showCredits {
                CreditsOverlay(onDismiss: { showCredits = false })
                    .transition(.opacity)
            }
            if showModbusLegend {
                ModbusLegendOverlay(onDismiss: { showModbusLegend = false })
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .environment(\.colorScheme, .dark)
        .onAppear { ensureFocus() }
        .onChange(of: world.elevators.map(\.id)) { ensureFocus() }
    }

    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdShift: NSEvent.ModifierFlags = [.command, .option, .control]
        guard mods.intersection(cmdShift).isEmpty else { return ev }

        if ev.keyCode == KeyCode.escape {
            if showHelp { showHelp = false; return nil }
            if showCredits { showCredits = false; return nil }
            if showModbusLegend { showModbusLegend = false; return nil }
            return ev
        }
        if ev.keyCode == KeyCode.f1 {
            showHelp.toggle()
            return nil
        }
        if ev.keyCode == KeyCode.tab {
            cycleFocus()
            return nil
        }

        let chars = (ev.charactersIgnoringModifiers ?? "").lowercased()
        switch chars {
        case "?":
            showHelp.toggle()
            return nil
        case "l":
            language.cycle()
            return nil
        case "q":
            NSApp.terminate(nil)
            return nil
        case "d":
            openWindow(id: "dcl", value: DCLSessionID())
            return nil
        case "s":
            openWindow(id: "scene")
            return nil
        case "y":
            openWindow(id: "dynamics")
            return nil
        case "a":
            toggleFocusedAutomation()
            return nil
        case "m":
            showModbusLegend.toggle()
            return nil
        case "o":
            controlFocused(.open)
            return nil
        case "c":
            controlFocused(.close)
            return nil
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let n = Int(chars) {
                controlFocused(.call, floor: n)
                return nil
            }
        case "0":
            controlFocused(.call, floor: 10)
            return nil
        default:
            break
        }
        return ev
    }

    private func controllableCabs() -> [Elevator] {
        // Any cab we can drive -- locally owned, or remote with a live
        // link to its owner. The keyboard focus ring walks this set so
        // the number / O / C keys can dispatch remote cabs too. Use the
        // SAME order the panels are rendered in (sortedElevators), so TAB
        // advances "FOCUSED CAB" to the cab visually below the current one
        // rather than to the next cab in raw insertion order.
        world.sortedElevators.filter { network.canControl($0) }
    }

    private func ensureFocus() {
        let cabs = controllableCabs()
        if let id = focusedCabId, cabs.contains(where: { $0.id == id }) { return }
        focusedCabId = cabs.first?.id
    }

    private func cycleFocus() {
        let cabs = controllableCabs()
        guard !cabs.isEmpty else { focusedCabId = nil; return }
        if let id = focusedCabId, let idx = cabs.firstIndex(where: { $0.id == id }) {
            focusedCabId = cabs[(idx + 1) % cabs.count].id
        } else {
            focusedCabId = cabs.first?.id
        }
    }

    private func controlFocused(_ kind: CabCommandKind, floor: Int? = nil) {
        guard let id = focusedCabId,
              let cab = world.elevators.first(where: { $0.id == id }) else { return }
        _ = network.control(cab, kind, floor: floor)
    }

    private func toggleFocusedAutomation() {
        guard let id = focusedCabId,
              let cab = world.elevators.first(where: { $0.id == id }),
              world.canControl(cab) else { return }
        if automation.isAutomatic(cabId: id) {
            automation.takeManualControl(cabId: id)
        } else {
            automation.returnToAutomatic(cabId: id)
        }
    }
}

private struct BannerHeader: View {
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        VStack(spacing: 2) {
            Text("*** \(language.t("banner.title")) ***")
                .font(RetroTheme.monoXl)
                .foregroundColor(RetroTheme.amber)
                .retroGlow()
            Text(language.t("banner.subtitle"))
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amberDim)
            Text(language.t("banner.copyright"))
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .overlay(Rectangle().stroke(RetroTheme.amber, lineWidth: 1))
    }
}

private struct StatusStrip: View {
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var telnet: DCLTelnetServer
    @EnvironmentObject var modbus: ModbusTCPServer

    var body: some View {
        // A wrapping FlowLayout keeps the strip on one line when there's room
        // but wraps onto additional lines when the window is narrow — so every
        // field stays visible even at the minimum window size, instead of the
        // trailing fields scrolling off-screen (which wider FR labels caused).
        FlowLayout(horizontalSpacing: 18, verticalSpacing: 4) {
                StatusLine(label: language.t("status.you"),
                           value: world.localPeerLabel,
                           valueColor: RetroTheme.cyan)
                StatusLine(label: language.t("status.peers"),
                           value: peersValue,
                           valueColor: network.peers.isEmpty ? RetroTheme.amberDim : RetroTheme.green)
                StatusLine(label: language.t("status.elevators"),
                           value: "\(world.elevators.count)",
                           valueColor: RetroTheme.amberBright)
                StatusLine(label: language.t("status.telnet"),
                           value: telnetValue,
                           valueColor: telnet.sessionCount == 0 ? RetroTheme.amberDim : RetroTheme.green)
                StatusLine(label: language.t("status.modbus"),
                           value: modbusValue,
                           valueColor: modbus.displayedClientCount == 0 ? RetroTheme.amberDim : RetroTheme.green)
                StatusLine(label: language.t("status.mode"),
                           value: modeValue,
                           valueColor: world.buildingMode == .normal ? RetroTheme.green : RetroTheme.amberBright)
                StatusLine(label: language.t("status.dispatch"),
                           value: dispatchValue,
                           valueColor: world.dispatchMode == .collective ? RetroTheme.green : RetroTheme.cyan)
                StatusLine(label: language.t("status.alarms"),
                           value: alarmValue,
                           valueColor: alarmColor)
                StatusLine(label: "STAT",
                           value: language.t("status.ready"),
                           valueColor: RetroTheme.green)
                BlinkingCursor()
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var peersValue: String {
        let count = network.peers.count
        switch count {
        case 0:  return language.t("status.peers.none")
        case 1:  return "1 \(language.t("status.peers.node"))"
        default: return "\(count) \(language.t("status.peers.nodes"))"
        }
    }

    private var telnetValue: String {
        let count = telnet.sessionCount
        switch count {
        case 0:  return language.t("status.telnet.none")
        case 1:  return language.t("status.telnet.one")
        default: return String(format: language.t("status.telnet.many"), count)
        }
    }

    private var modbusValue: String {
        let count = modbus.displayedClientCount
        switch count {
        case 0:  return language.t("status.modbus.none")
        case 1:  return language.t("status.modbus.one")
        default: return String(format: language.t("status.modbus.many"), count)
        }
    }

    private var modeValue: String {
        switch world.buildingMode {
        case .normal:         return language.t("status.mode.normal")
        case .fireRecall:     return language.t("status.mode.fire")
        case .emergencyPower: return language.t("status.mode.epo")
        }
    }

    private var dispatchValue: String {
        switch world.dispatchMode {
        case .collective:  return language.t("status.dispatch.coll")
        case .destination: return language.t("status.dispatch.dest")
        }
    }

    private var alarmValue: String {
        let active = world.activeAlarms.count
        let unack = world.unacknowledgedAlarmCount
        return active == 0
            ? language.t("status.alarms.normal")
            : String(format: language.t("status.alarms.summary"), active, unack)
    }

    private var alarmColor: Color {
        guard let severity = world.highestActiveSeverity else { return RetroTheme.green }
        switch severity {
        case .advisory: return RetroTheme.cyan
        case .minor: return RetroTheme.amber
        case .major: return RetroTheme.amberBright
        case .critical: return .red
        }
    }
}

private struct SCADAAlarmPanel: View {
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage
    @State private var injectorTask: Task<Void, Never>? = nil

    var body: some View {
        BoxPanel(title: language.t("alarm.panel.title"), accent: panelAccent) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    StatusLine(label: language.t("alarm.active"),
                               value: "\(world.activeAlarms.count)",
                               valueColor: panelAccent)
                    StatusLine(label: language.t("alarm.unack"),
                               value: "\(world.unacknowledgedAlarmCount)",
                               valueColor: world.unacknowledgedAlarmCount == 0 ? RetroTheme.green : RetroTheme.amberBright)
                    Spacer()
                    RetroButton(language.t("alarm.inject"), highlighted: isInjecting) {
                        toggleInjector()
                    }
                    RetroButton(language.t("alarm.ack.all"), enabled: world.unacknowledgedAlarmCount > 0) {
                        _ = world.acknowledgeAllAlarms()
                    }
                    RetroButton(language.t("alarm.clear.all"), enabled: world.hasClearableAlarms) {
                        _ = world.clearAllActiveAlarms()
                    }
                }
                HStack(spacing: 8) {
                    failureButton("CTRL", source: "SYS", point: "CONTROLLER", severity: .major, messageKey: "alarm.msg.controller")
                    failureButton("DOOR", source: "CAB", point: "DOOR_ZONE", severity: .minor, messageKey: "alarm.msg.doorzone")
                    failureButton("BRAKE", source: "CAB", point: "BRAKE", severity: .critical, messageKey: "alarm.msg.brake")
                    failureButton("NET", source: "NET", point: "PEER_LINK", severity: .major, messageKey: "alarm.msg.peerlink")
                    failureButton("PWR", source: "PWR", point: "MAINS", severity: .critical, messageKey: "alarm.msg.mains")
                    RetroButton(language.t("alarm.clear.ack"), enabled: world.hasClearableAcknowledgedAlarms) {
                        _ = world.clearAcknowledgedActiveAlarms()
                    }
                }
                alarmTable
            }
        }
        .onDisappear {
            injectorTask?.cancel()
            injectorTask = nil
        }
    }

    private var isInjecting: Bool { injectorTask != nil }

    private func toggleInjector() {
        if let t = injectorTask {
            t.cancel()
            injectorTask = nil
            return
        }
        injectorTask = Task { @MainActor in
            // Brief grace period so a quick toggle doesn't fire instantly.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while !Task.isCancelled {
                injectRandomAlarm()
                let delaySec = Double.random(in: 4.0...10.0)
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
        }
    }

    private struct InjectorPick {
        let source: String
        let point: String
        let severity: AlarmSeverity
        let messageKey: String
        let weight: Int
    }

    // Weighted pool: advisory + minor entries dominate so the SCADA log
    // reads like a routine day; major/critical picks are rare so the
    // student spends most of their time working ack/clear muscle memory
    // and only occasionally has to think about a service-affecting page.
    // Nothing auto-resolves -- the operator (the student) drives every
    // raise -> ACK -> CLEAR cycle, which is the whole point of the panel.
    private static let injectorPool: [InjectorPick] = [
        .init(source: "SYS", point: "CONTROLLER",    severity: .major,    messageKey: "alarm.msg.controller",    weight: 1),
        .init(source: "CAB", point: "DOOR_ZONE",     severity: .minor,    messageKey: "alarm.msg.doorzone",      weight: 4),
        .init(source: "CAB", point: "BRAKE",         severity: .critical, messageKey: "alarm.msg.brake",         weight: 1),
        .init(source: "NET", point: "PEER_LINK",     severity: .major,    messageKey: "alarm.msg.peerlink",      weight: 2),
        .init(source: "PWR", point: "MAINS",         severity: .critical, messageKey: "alarm.msg.mains",         weight: 1),
        .init(source: "CAB", point: "DOOR_HELD",     severity: .minor,    messageKey: "alarm.msg.doorheld",      weight: 5),
        .init(source: "CAB", point: "OVERSPEED",     severity: .major,    messageKey: "alarm.msg.overspeed",     weight: 1),
        .init(source: "CAB", point: "LANDING_ZONE",  severity: .minor,    messageKey: "alarm.msg.landingzone",   weight: 4),
        .init(source: "SYS", point: "DISPATCH",      severity: .advisory, messageKey: "alarm.msg.dispatchstall", weight: 6),
    ]

    private static let weightedPool: [InjectorPick] = injectorPool.flatMap {
        Array(repeating: $0, count: max(1, $0.weight))
    }

    private func injectRandomAlarm() {
        guard let pick = Self.weightedPool.randomElement() else { return }
        let resolvedSource: String
        if pick.source == "CAB" {
            let local = world.elevators.filter { $0.ownerPeerId == world.localPeerId }
            if let cab = local.randomElement() {
                resolvedSource = "CAB \(world.displayLabel(for: cab))"
            } else {
                resolvedSource = "CAB GROUP"
            }
        } else {
            resolvedSource = pick.source
        }
        // Skip if an identical alarm is already active so the injector
        // creates new rows instead of stacking duplicates on one point.
        let dup = world.activeAlarms.contains {
            $0.source == resolvedSource && $0.point == pick.point
        }
        if dup { return }
        _ = world.raiseAlarm(source: resolvedSource,
                             point: pick.point,
                             severity: pick.severity,
                             message: Strings.lookup(pick.messageKey, lang: .en))
    }

    private var alarmTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                header(language.t("alarm.col.id"), width: 42)
                header(language.t("alarm.col.sev"), width: 84)
                header(language.t("alarm.col.state"), width: 88)
                header(language.t("alarm.col.source"), width: 86)
                header(language.t("alarm.col.point"), width: 120)
                header(language.t("alarm.col.message"), width: nil)
            }
            HRule(RetroTheme.amberDim)
            if world.activeAlarms.isEmpty {
                Text(language.t("alarm.none.active"))
                    .font(RetroTheme.mono)
                    .foregroundColor(RetroTheme.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(world.activeAlarms.prefix(5))) { alarm in
                    AlarmRow(alarm: alarm)
                }
            }
        }
    }

    private func failureButton(_ label: String, source: String, point: String, severity: AlarmSeverity, messageKey: String) -> some View {
        // The bare source "CAB" is a sentinel meaning "bind this manual
        // fault to a real cab" so the row in the alarm table reads
        // identically to the auto-detected cab faults (CAB L01 / CAB
        // A02 / ...) instead of a generic "CAB" group entry. Resolved
        // at render time -- if the local set of cabs changes, the
        // button just retargets the next one.
        let resolvedSource: String
        if source == "CAB" {
            if let cab = world.elevators.first(where: { $0.ownerPeerId == world.localPeerId }) {
                resolvedSource = "CAB \(world.displayLabel(for: cab))"
            } else {
                resolvedSource = "CAB GROUP"
            }
        } else {
            resolvedSource = source
        }
        let active = world.activeAlarms.contains { $0.source == resolvedSource && $0.point == point }
        return RetroButton(label, highlighted: active) {
            if active {
                _ = world.clearAlarm(source: resolvedSource, point: point)
            } else {
                _ = world.raiseAlarm(source: resolvedSource, point: point, severity: severity, message: Strings.lookup(messageKey, lang: .en))
            }
        }
    }

    private func header(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .font(RetroTheme.monoSm)
            .foregroundColor(RetroTheme.amberDim)
            .frame(width: width, alignment: .leading)
    }

    private var panelAccent: Color {
        guard let severity = world.highestActiveSeverity else { return RetroTheme.green }
        switch severity {
        case .advisory: return RetroTheme.cyan
        case .minor: return RetroTheme.amber
        case .major: return RetroTheme.amberBright
        case .critical: return .red
        }
    }

}

private struct AlarmRow: View {
    let alarm: SCADAAlarm
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 0) {
            cell(String(format: "%04d", alarm.sequence), width: 42, color: RetroTheme.amberBright)
            cell(localizedSeverity, width: 84, color: severityColor)
            cell(localizedStatus, width: 88, color: alarm.isAcknowledged ? RetroTheme.green : RetroTheme.amberBright)
            cell(alarm.source, width: 86, color: RetroTheme.cyan)
            cell(alarm.point, width: 120, color: RetroTheme.amber)
            Text(localizedMessage)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amber)
                .lineLimit(1)
            Spacer(minLength: 8)
            RetroButton(language.t("alarm.ack"), enabled: !alarm.isAcknowledged) {
                _ = world.acknowledgeAlarm(sequence: alarm.sequence)
            }
        }
    }

    private func cell(_ text: String, width: CGFloat, color: Color) -> some View {
        Text(text)
            .font(RetroTheme.monoSm)
            .foregroundColor(color)
            .frame(width: width, alignment: .leading)
    }

    private var severityColor: Color {
        switch alarm.severity {
        case .advisory: return RetroTheme.cyan
        case .minor: return RetroTheme.amber
        case .major: return RetroTheme.amberBright
        case .critical: return .red
        }
    }

    private var localizedSeverity: String {
        switch alarm.severity {
        case .advisory: return language.t("alarm.sev.advisory")
        case .minor: return language.t("alarm.sev.minor")
        case .major: return language.t("alarm.sev.major")
        case .critical: return language.t("alarm.sev.critical")
        }
    }

    private var localizedStatus: String {
        if alarm.clearedAt != nil { return language.t("alarm.status.cleared") }
        return alarm.isAcknowledged ? language.t("alarm.status.ack") : language.t("alarm.status.unack")
    }

    private var localizedMessage: String {
        switch alarm.message {
        case Strings.lookup("alarm.msg.controller", lang: .en): return language.t("alarm.msg.controller")
        case Strings.lookup("alarm.msg.doorzone", lang: .en): return language.t("alarm.msg.doorzone")
        case Strings.lookup("alarm.msg.brake", lang: .en): return language.t("alarm.msg.brake")
        case Strings.lookup("alarm.msg.peerlink", lang: .en): return language.t("alarm.msg.peerlink")
        case Strings.lookup("alarm.msg.mains", lang: .en): return language.t("alarm.msg.mains")
        case Strings.lookup("alarm.msg.fire", lang: .en): return language.t("alarm.msg.fire")
        case Strings.lookup("alarm.msg.epo", lang: .en): return language.t("alarm.msg.epo")
        case Strings.lookup("alarm.msg.overspeed", lang: .en): return language.t("alarm.msg.overspeed")
        case Strings.lookup("alarm.msg.landingzone", lang: .en): return language.t("alarm.msg.landingzone")
        case Strings.lookup("alarm.msg.doorheld", lang: .en): return language.t("alarm.msg.doorheld")
        case Strings.lookup("alarm.msg.doorclose", lang: .en): return language.t("alarm.msg.doorclose")
        case Strings.lookup("alarm.msg.dispatchstall", lang: .en): return language.t("alarm.msg.dispatchstall")
        case Strings.lookup("alarm.msg.terminallimit", lang: .en): return language.t("alarm.msg.terminallimit")
        case Strings.lookup("alarm.msg.brakehold", lang: .en): return language.t("alarm.msg.brakehold")
        case Strings.lookup("alarm.msg.overload", lang: .en): return language.t("alarm.msg.overload")
        case Strings.lookup("alarm.msg.fullload", lang: .en): return language.t("alarm.msg.fullload")
        default: return alarm.message
        }
    }
}

private struct ElevatorPanel: View {
    let elevator: Elevator
    let focused: Bool
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var automation: AutoDriver

    var body: some View {
        BoxPanel(title: titleLine, accent: titleAccent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                    StatusLine(label: language.t("elev.floor"),
                               value: floorBracket,
                               valueColor: RetroTheme.amberBright)
                    StatusLine(label: language.t("elev.direction"),
                               value: directionString,
                               valueColor: directionColor)
                    StatusLine(label: language.t("elev.doors"),
                               value: doorString,
                               valueColor: doorColor)
                    StatusLine(label: language.t("elev.profile"),
                               value: profileString,
                               valueColor: profileColor)
                    Spacer()
                    if focused {
                        Text("◀ \(language.t("help.focus.hint"))")
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.green)
                            .retroGlow()
                    }
                }
                StatusLine(label: language.t("elev.queue"),
                           value: queueString,
                           valueColor: RetroTheme.greenDim)
                FloorPad(elevator: elevator)
                HStack(spacing: 10) {
                    DoorControls(elevator: elevator)
                    Spacer()
                    ProfileControls(elevator: elevator)
                    ModeControls(elevator: elevator)
                }
            }
        }
        // Dim only a cab we genuinely can't drive (remote with no live
        // link to its owner). A locally-owned cab OR a remote cab we hold
        // a link to renders at full brightness so it reads as controllable.
        .opacity(network.canControl(elevator) ? 1.0 : 0.78)
    }

    private var titleLine: String {
        let isLocal = world.canControl(elevator)
        let tag: String
        if isLocal {
            tag = elevator.automatic ? language.t("elev.aitag") : language.t("elev.localtag")
        } else {
            tag = elevator.automatic ? language.t("elev.remoteautotag") : language.t("elev.remotetag")
        }
        return "\(language.t("elev.cab")) \(world.displayLabel(for: elevator)) [\(tag)]"
    }

    private var titleAccent: Color {
        if world.canControl(elevator) {
            return elevator.automatic ? RetroTheme.cyan : RetroTheme.amber
        }
        // Remote cab: full-strength green when we hold a link and can
        // drive it, dim green only when its owner is unreachable.
        return network.canControl(elevator) ? RetroTheme.green : RetroTheme.greenDim
    }

    private var floorBracket: String {
        String(format: "[ %2d ]", elevator.displayFloor)
    }

    private var directionString: String {
        switch elevator.direction {
        case .up:   return language.t("dir.up")
        case .down: return language.t("dir.down")
        case .idle: return language.t("dir.idle")
        }
    }

    private var directionColor: Color {
        switch elevator.direction {
        case .up:   return RetroTheme.green
        case .down: return RetroTheme.cyan
        case .idle: return RetroTheme.amberDim
        }
    }

    private var doorString: String {
        switch elevator.doors {
        case .closed:  return language.t("door.closed")
        case .opening: return language.t("door.opening")
        case .open:    return language.t("door.open")
        case .closing: return language.t("door.closing")
        }
    }

    private var doorColor: Color {
        switch elevator.doors {
        case .open:    return RetroTheme.green
        case .closed:  return RetroTheme.amberDim
        default:       return RetroTheme.amber
        }
    }

    private var profileString: String {
        switch elevator.profile {
        case .pax:     return language.t("elev.profile.pax")
        case .freight: return language.t("elev.profile.freight")
        }
    }

    private var profileColor: Color {
        switch elevator.profile {
        case .pax:     return RetroTheme.green
        case .freight: return RetroTheme.cyan
        }
    }

    private var queueString: String {
        elevator.queue.isEmpty
            ? language.t("misc.empty")
            : elevator.queue.map { String($0) }.joined(separator: " > ")
    }
}

private struct FloorPad: View {
    let elevator: Elevator
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var network: PeerNetwork

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach((Sim.firstFloor...Sim.lastFloor).reversed(), id: \.self) { floor in
                let lit = elevator.queue.contains(floor)
                RetroButton(String(format: "%2d", floor),
                            enabled: network.canControl(elevator),
                            highlighted: lit) {
                    _ = network.control(elevator, .call, floor: floor)
                }
            }
        }
    }
}

private struct DoorControls: View {
    let elevator: Elevator
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 10) {
            RetroButton(language.t("btn.door.open"),
                        enabled: network.canControl(elevator)) {
                _ = network.control(elevator, .open)
            }
            RetroButton(language.t("btn.door.close"),
                        enabled: network.canControl(elevator)) {
                _ = network.control(elevator, .close)
            }
        }
    }
}

private struct ProfileControls: View {
    let elevator: Elevator
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        let canControl = world.canControl(elevator)
        HStack(spacing: 6) {
            Text("\(language.t("btn.profile.label")):")
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            RetroButton(language.t("btn.profile.pax"),
                        enabled: canControl,
                        highlighted: elevator.profile == .pax) {
                guard canControl, elevator.profile != .pax else { return }
                _ = world.mutateLocal(elevator.id) { $0.profile = .pax }
            }
            RetroButton(language.t("btn.profile.freight"),
                        enabled: canControl,
                        highlighted: elevator.profile == .freight) {
                guard canControl, elevator.profile != .freight else { return }
                _ = world.mutateLocal(elevator.id) { $0.profile = .freight }
            }
        }
    }
}

private struct ModeControls: View {
    let elevator: Elevator
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var automation: AutoDriver

    var body: some View {
        let canControl = world.canControl(elevator)
        // Reflect the cab's own automatic flag (the value broadcast in its
        // state), not the local AutoDriver -- the AutoDriver only tracks
        // locally-owned cabs, so a remote cab would always read MANUAL
        // even while its owning node drives it in AUTO.
        let isAuto = elevator.automatic
        HStack(spacing: 6) {
            Text("\(language.t("btn.mode.label")):")
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            RetroButton(language.t("btn.mode.auto"),
                        enabled: canControl,
                        highlighted: isAuto) {
                guard canControl, !isAuto else { return }
                automation.returnToAutomatic(cabId: elevator.id)
            }
            RetroButton(language.t("btn.mode.manual"),
                        enabled: canControl,
                        highlighted: !isAuto) {
                guard canControl, isAuto else { return }
                automation.takeManualControl(cabId: elevator.id)
            }
        }
    }
}

private struct FooterBar: View {
    @Binding var showCredits: Bool
    @EnvironmentObject var language: AppLanguage
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Text(language.t("hint.line"))
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            Spacer()
            RetroButton(language.t("credits.title")) {
                showCredits = true
            }
            RetroButton(language.t("window.dcl")) {
                openWindow(id: "dcl", value: DCLSessionID())
            }
            RetroButton(language.t("window.scene")) {
                openWindow(id: "scene")
            }
            RetroButton(language.t("window.dynamics")) {
                openWindow(id: "dynamics")
            }
            HStack(spacing: 6) {
                Text("\(language.t("hint.lang")):")
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                ForEach(Lang.allCases) { lang in
                    RetroButton(lang.code,
                                highlighted: language.current == lang) {
                        language.current = lang
                    }
                }
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) {
            HRule(RetroTheme.amber)
        }
    }
}

private struct HelpOverlay: View {
    let onDismiss: () -> Void
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        ZStack {
            RetroTheme.bg.opacity(0.85).ignoresSafeArea()
            BoxPanel(title: language.t("help.title"), accent: RetroTheme.green) {
                VStack(alignment: .leading, spacing: 8) {
                    row("F1  /  ?",  language.t("help.k.help"))
                    row("TAB",       language.t("help.k.tab"))
                    row("L",         language.t("help.k.lang"))
                    row("1 .. 9, 0", language.t("help.k.floors"))
                    row("O  /  C",   language.t("help.k.doors"))
                    row("D",         language.t("help.k.dcl"))
                    row("A",         language.t("help.k.mode"))
                    row("M",         language.t("help.k.modbus"))
                    row("Y",         language.t("help.k.dynamics"))
                    row("Q",         language.t("help.k.quit"))
                    row("ESC",       language.t("help.k.esc"))
                    Spacer().frame(height: 6)
                    Text(language.t("help.dismiss"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amberDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(width: 460)
            }
            .onTapGesture { onDismiss() }
        }
    }

    private func row(_ key: String, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amberBright)
                .frame(width: 110, alignment: .leading)
            Text(desc)
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amber)
        }
    }
}

private struct CreditsOverlay: View {
    let onDismiss: () -> Void
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        ZStack {
            RetroTheme.bg.opacity(0.85).ignoresSafeArea()
            BoxPanel(title: language.t("credits.title"), accent: RetroTheme.cyan) {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        HRule(RetroTheme.cyan)
                        Text("ElevatorSystem")
                            .font(RetroTheme.monoXl)
                            .foregroundColor(RetroTheme.amberBright)
                            .retroGlow()
                        HRule(RetroTheme.cyan)
                    }

                    HRule(RetroTheme.amberDim)

                    VStack(alignment: .leading, spacing: 14) {
                        creditBlock(
                            role: language.t("credits.role.original"),
                            name: "Amaury Crocquefer",
                            email: "amaury@crocque.fr",
                            url: "github.com/lapatatedouce59/elevatorSystem"
                        )
                        creditBlock(
                            role: language.t("credits.role.macos"),
                            name: "Douglas Carmichael",
                            email: "dcarmich@dcarmichael.net",
                            url: "github.com/douglas-carmichael/elevatorSystem"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HRule(RetroTheme.amberDim)

                    Text(language.t("credits.dismiss"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amberDim)
                }
                .frame(width: 460)
            }
            .onTapGesture { onDismiss() }
        }
    }

    private func creditBlock(role: String, name: String, email: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(role)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.cyan)
            Text(name)
                .font(RetroTheme.monoLg)
                .foregroundColor(RetroTheme.amberBright)
                .retroGlow()
            Text(email)
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amber)
            Text(url)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
        }
    }
}

/// Reference card for the Modbus TCP register map. Toggled with M --
/// designed so a viewer following along with `mbpoll` or QModMaster
/// can read what each register / coil offset means without diving
/// into the source. ESC, M again, or tap-anywhere dismisses.
private struct ModbusLegendOverlay: View {
    let onDismiss: () -> Void
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RetroTheme.bg.opacity(0.9).ignoresSafeArea()
                BoxPanel(title: language.t("modbus.legend.title"), accent: RetroTheme.cyan) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(language.t("modbus.legend.endpoint"))
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.amberDim)
                        Spacer().frame(height: 4)

                        // Two columns so the (now taller) map fits without
                        // running off the bottom: telemetry/setpoints on the
                        // left, command + status/safety-chain bits on the
                        // right. Scrolls if the window is too short to show it
                        // all (the minimum 920x620 window can't fit it whole).
                        ScrollView {
                            HStack(alignment: .top, spacing: 28) {
                                inputAndHoldingColumn
                                coilAndDiscreteColumn
                            }
                        }

                        Spacer().frame(height: 8)
                        Text(language.t("help.dismiss"))
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.amberDim)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(width: min(828, geo.size.width - 80))
                }
                .frame(maxHeight: geo.size.height - 48)
                .onTapGesture { onDismiss() }
            }
        }
    }

    /// Left column: input registers (telemetry) + holding registers (setpoints).
    private var inputAndHoldingColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            section(language.t("modbus.legend.ir"))
            row("0..15",   language.t("modbus.reg.position"))
            row("16..31",  language.t("modbus.reg.direction"))
            row("32..47",  language.t("modbus.reg.doorstate"))
            row("48..63",  language.t("modbus.reg.queue"))
            row("64..79",  language.t("modbus.reg.doorprog"))
            row("80..95",  language.t("modbus.reg.velocity"))
            row("96..111", language.t("modbus.reg.load"))
            row("112..127",language.t("modbus.reg.accel"))
            row("1000",    language.t("modbus.reg.cabcount"))
            row("1002",    language.t("modbus.reg.bldgflrs"))
            row("1003",    language.t("modbus.reg.telnetmb"))
            row("1005",    language.t("modbus.reg.bldgmode"))
            row("1006",    language.t("modbus.reg.recallflr"))
            row("1007",    language.t("modbus.reg.alarms"))
            row("1009",    language.t("modbus.reg.dispatch"))
            row("1010",    language.t("modbus.reg.hallcalls"))
            row("1011",    language.t("modbus.show.unacked"))
            row("1012",    language.t("modbus.show.shelved"))
            row("1013",    language.t("modbus.show.rtn"))

            Spacer().frame(height: 4)
            section(language.t("modbus.legend.hr"))
            row("0..15",   language.t("modbus.reg.profile"))
            row("16..31",  language.t("modbus.reg.cabmode"))
            row("32..47",  language.t("modbus.reg.target"))
        }
        .frame(width: 400, alignment: .leading)
    }

    /// Right column: coils (commands) + discrete inputs (status + safety chain).
    private var coilAndDiscreteColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            section(language.t("modbus.legend.coil"))
            row("0..15",   language.t("modbus.reg.dooropen"))
            row("16..31",  language.t("modbus.reg.doorclose"))
            row("32..47",  language.t("modbus.reg.stop"))

            Spacer().frame(height: 4)
            section(language.t("modbus.legend.di"))
            row("0..15",   language.t("modbus.reg.cablocal"))
            row("16..31",  language.t("modbus.reg.cabmoving"))
            row("32..47",  language.t("modbus.reg.dooropened"))
            row("48..63",  language.t("modbus.reg.brake"))
            row("64..79",  language.t("modbus.reg.obstructed"))
            row("80..95",  language.t("modbus.reg.overload"))
            // Chaîne de sécurité (1 = contact closed / healthy). Names
            // follow the selected safety standard (ASME / EN 81).
            section(language.t("modbus.show.safetychain"))
            row("96..111",  language.safetyTerm("safety.contact.doorinterlock"))
            row("112..127", language.safetyTerm("safety.contact.finallimit"))
            row("128..143", language.safetyTerm("safety.contact.governor"))
            row("144..159", language.safetyTerm("safety.contact.gear"))
            row("160..175", language.safetyTerm("safety.contact.brake"))
            row("176..191", language.safetyTerm("safety.contact.chain"))
        }
        .frame(width: 400, alignment: .leading)
    }

    private func section(_ text: String) -> some View {
        Text(text)
            .font(RetroTheme.mono)
            .foregroundColor(RetroTheme.cyan)
            .retroGlow()
    }

    private func row(_ addr: String, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(addr)
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amberBright)
                .frame(width: 80, alignment: .leading)
            Text(desc)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amber)
        }
    }
}
