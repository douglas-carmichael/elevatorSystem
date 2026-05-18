import SwiftUI
import AppKit

@main
struct ElevatorSystemApp: App {
    @StateObject private var language: AppLanguage
    @StateObject private var world: ElevatorWorld
    @StateObject private var network: PeerNetwork
    @StateObject private var automation: AutoDriver
    @StateObject private var dcl: DCLEngine
    @StateObject private var telnet: DCLTelnetServer
    @StateObject private var modbus: ModbusTCPServer

    init() {
        let peerId = UUID().uuidString
        let label = Host.current().localizedName ?? "LOCAL"
        let world = ElevatorWorld(localPeerId: peerId, localPeerLabel: label)
        let network = PeerNetwork(peerId: peerId, label: label)
        let automation = AutoDriver()
        let dcl = DCLEngine()
        let telnet = DCLTelnetServer()
        let modbus = ModbusTCPServer()
        _language = StateObject(wrappedValue: AppLanguage())
        _world = StateObject(wrappedValue: world)
        _network = StateObject(wrappedValue: network)
        _automation = StateObject(wrappedValue: automation)
        _dcl = StateObject(wrappedValue: dcl)
        _telnet = StateObject(wrappedValue: telnet)
        _modbus = StateObject(wrappedValue: modbus)
    }

    var body: some Scene {
        WindowGroup("Group Dispatcher", id: "control") {
            ControlPanelWindow()
                .environmentObject(language)
                .environmentObject(world)
                .environmentObject(network)
                .environmentObject(automation)
                .environmentObject(telnet)
                .environmentObject(modbus)
                .onAppear { bootstrap() }
        }
        .windowResizability(.contentMinSize)
        .restorationDisabled()
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        WindowGroup("Hoistway Synoptic", id: "scene") {
            ElevatorSceneWindow()
                .environmentObject(language)
                .environmentObject(world)
                .environmentObject(network)
        }
        .windowResizability(.contentMinSize)
        .restorationDisabled()

        WindowGroup("DCL Terminal", id: "dcl") {
            DCLShellWindow()
                .environmentObject(language)
                .environmentObject(dcl)
        }
        .windowResizability(.contentMinSize)
        .restorationDisabled()

        WindowGroup("Cab Dynamics", id: "dynamics") {
            DynamicsMonitorWindow()
                .environmentObject(language)
                .environmentObject(world)
        }
        .windowResizability(.contentMinSize)
        .restorationDisabled()
    }

    private func bootstrap() {
        guard world.elevators.isEmpty else { return }
        if let other = otherRunningInstance() {
            refuseDuplicateLaunch(other: other)
            return
        }
        let mine = Elevator.newAt(floor: Sim.firstFloor,
                                   label: "01",
                                   ownerPeerId: world.localPeerId,
                                   automatic: false)
        world.elevators.append(mine)
        world.start()
        network.attach(world: world)
        network.start()
        automation.attach(world: world, network: network)
        automation.start()
        dcl.attach(world: world, network: network, automation: automation, language: language)
        telnet.attach(world: world, network: network, automation: automation, language: language)
        telnet.start()
        modbus.attach(world: world, network: network, automation: automation, telnet: telnet)
        modbus.start()
    }

    /// Looks for another running ElevatorSystem process on this Mac.
    /// Catches the Xcode-launched-while-Finder-copy-runs case that
    /// LSMultipleInstancesProhibited misses, and prevents MONITOR CLUSTER
    /// from showing the same Mac as two phantom nodes.
    ///
    /// `isFinishedLaunching` filters out app entries that NSWorkspace
    /// reports transiently during macOS session restore -- if we don't
    /// require the other instance to be fully launched, a system-restored
    /// ghost can cause every fresh launch to false-positive on itself.
    private func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first { $0.processIdentifier != mine && $0.isFinishedLaunching }
    }

    private func refuseDuplicateLaunch(other: NSRunningApplication) {
        // Defer the modal + terminate so we're running OUTSIDE the AppKit
        // / Core Animation transaction that the .onAppear that called us
        // is nested inside. NSAlert.runModal() is suppressed inside a CA
        // transaction (AppKit logs "cannot run inside a transaction begin
        // /commit pair"), which silently dropped the alert and left the
        // launch terminating without ever telling the user why.
        let pid = other.processIdentifier
        let info = """
            Only one DCL node may run on this Mac at a time. The existing \
            instance (pid \(pid)) will keep running; this launch will quit.
            """
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Another ElevatorSystem instance is already running"
            alert.informativeText = info
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Activate Existing")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                other.activate(options: [.activateIgnoringOtherApps])
            }
            NSApp.terminate(nil)
        }
    }
}

private extension Scene {
    // Opts each WindowGroup out of macOS session restore so the app
    // launches in its declared layout rather than reopening whatever the
    // user last had on screen.
    func restorationDisabled() -> some Scene {
        self.restorationBehavior(.disabled)
    }
}
