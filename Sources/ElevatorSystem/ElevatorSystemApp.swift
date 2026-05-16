import SwiftUI
import AppKit

@main
struct ElevatorSystemApp: App {
    @StateObject private var language: AppLanguage
    @StateObject private var world: ElevatorWorld
    @StateObject private var network: PeerNetwork
    @StateObject private var automation: AutoDriver
    @StateObject private var dcl: DCLEngine

    init() {
        let peerId = UUID().uuidString
        let label = Host.current().localizedName ?? "LOCAL"
        let world = ElevatorWorld(localPeerId: peerId, localPeerLabel: label)
        let network = PeerNetwork(peerId: peerId, label: label)
        let automation = AutoDriver()
        let dcl = DCLEngine()
        _language = StateObject(wrappedValue: AppLanguage())
        _world = StateObject(wrappedValue: world)
        _network = StateObject(wrappedValue: network)
        _automation = StateObject(wrappedValue: automation)
        _dcl = StateObject(wrappedValue: dcl)
    }

    var body: some Scene {
        WindowGroup("Group Dispatcher", id: "control") {
            ControlPanelWindow()
                .environmentObject(language)
                .environmentObject(world)
                .environmentObject(network)
                .environmentObject(automation)
                .onAppear { bootstrap() }
        }
        .windowResizability(.contentMinSize)
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

        WindowGroup("DCL Terminal", id: "dcl") {
            DCLShellWindow()
                .environmentObject(language)
                .environmentObject(dcl)
        }
        .windowResizability(.contentMinSize)
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
    }

    /// Looks for another running ElevatorSystem process on this Mac.
    /// Catches the Xcode-launched-while-Finder-copy-runs case that
    /// LSMultipleInstancesProhibited misses, and prevents MONITOR CLUSTER
    /// from showing the same Mac as two phantom nodes.
    private func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first { $0.processIdentifier != mine }
    }

    private func refuseDuplicateLaunch(other: NSRunningApplication) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Another ElevatorSystem instance is already running"
        let pid = other.processIdentifier
        alert.informativeText = """
            Only one DCL node may run on this Mac at a time. The existing \
            instance (pid \(pid)) will keep running; this launch will quit.
            """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Activate Existing")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            other.activate(options: [.activateIgnoringOtherApps])
        }
        NSApp.terminate(nil)
    }
}
