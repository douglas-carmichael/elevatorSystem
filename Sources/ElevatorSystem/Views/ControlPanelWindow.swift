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

    var body: some View {
        ZStack {
            RetroTheme.bg.ignoresSafeArea()
            KeyboardHost(onKey: handleKey)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
            VStack(spacing: 14) {
                BannerHeader()
                StatusStrip()
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
        }
        .frame(minWidth: 760, minHeight: 620)
        .environment(\.colorScheme, .dark)
        .onAppear { ensureFocus() }
        .onChange(of: world.elevators.map(\.id)) { _ in ensureFocus() }
    }

    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdShift: NSEvent.ModifierFlags = [.command, .option, .control]
        guard mods.intersection(cmdShift).isEmpty else { return ev }

        if ev.keyCode == KeyCode.escape {
            if showHelp { showHelp = false; return nil }
            if showCredits { showCredits = false; return nil }
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
            openWindow(id: "dcl")
            return nil
        case "s":
            openWindow(id: "scene")
            return nil
        case "a":
            toggleFocusedAutomation()
            return nil
        case "o":
            mutateFocused { $0.requestDoorsOpen() }
            return nil
        case "c":
            mutateFocused { $0.requestDoorsClose() }
            return nil
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let n = Int(chars) {
                mutateFocused { $0.enqueue(floor: n) }
                return nil
            }
        case "0":
            mutateFocused { $0.enqueue(floor: 10) }
            return nil
        default:
            break
        }
        return ev
    }

    private func controllableCabs() -> [Elevator] {
        world.elevators.filter { world.canControl($0) }
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

    private func mutateFocused(_ block: (inout Elevator) -> Void) {
        guard let id = focusedCabId else { return }
        _ = world.mutateLocal(id, block)
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

    var body: some View {
        HStack(spacing: 28) {
            StatusLine(label: language.t("status.you"),
                       value: world.localPeerLabel,
                       valueColor: RetroTheme.cyan)
            StatusLine(label: language.t("status.peers"),
                       value: peersValue,
                       valueColor: network.peers.isEmpty ? RetroTheme.amberDim : RetroTheme.green)
            StatusLine(label: language.t("status.elevators"),
                       value: "\(world.elevators.count)",
                       valueColor: RetroTheme.amberBright)
            Spacer()
            StatusLine(label: "STAT",
                       value: language.t("status.ready"),
                       valueColor: RetroTheme.green)
            BlinkingCursor()
        }
        .padding(.horizontal, 6)
    }

    private var peersValue: String {
        let count = network.peers.count
        switch count {
        case 0:  return language.t("status.peers.none")
        case 1:  return "1 \(language.t("status.peers.node"))"
        default: return "\(count) \(language.t("status.peers.nodes"))"
        }
    }
}

private struct ElevatorPanel: View {
    let elevator: Elevator
    let focused: Bool
    @EnvironmentObject var world: ElevatorWorld
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
        .opacity(world.canControl(elevator) ? 1.0 : 0.78)
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
        return RetroTheme.greenDim
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach((Sim.firstFloor...Sim.lastFloor).reversed(), id: \.self) { floor in
                let lit = elevator.queue.contains(floor)
                RetroButton(String(format: "%2d", floor),
                            enabled: world.canControl(elevator),
                            highlighted: lit) {
                    _ = world.mutateLocal(elevator.id) { e in
                        e.enqueue(floor: floor)
                    }
                }
            }
        }
    }
}

private struct DoorControls: View {
    let elevator: Elevator
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 10) {
            RetroButton(language.t("btn.door.open"),
                        enabled: world.canControl(elevator)) {
                _ = world.mutateLocal(elevator.id) { $0.requestDoorsOpen() }
            }
            RetroButton(language.t("btn.door.close"),
                        enabled: world.canControl(elevator)) {
                _ = world.mutateLocal(elevator.id) { $0.requestDoorsClose() }
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
        let isAuto = automation.isAutomatic(cabId: elevator.id)
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
                openWindow(id: "dcl")
            }
            RetroButton(language.t("window.scene")) {
                openWindow(id: "scene")
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
