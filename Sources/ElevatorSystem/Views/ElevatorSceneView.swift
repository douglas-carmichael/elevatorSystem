import SwiftUI
import SceneKit
import AppKit
import Combine

struct ElevatorSceneWindow: View {
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage
    @State private var showingRemote = false
    @State private var selectedRemotePeerId: String? = nil
    @State private var recenterTrigger: Int = 0
    @State private var isolatedCabId: UUID? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            ElevatorSceneRepresentable(
                world: world,
                showingRemote: showingRemote,
                selectedRemotePeerId: selectedRemotePeerId,
                recenterTrigger: recenterTrigger,
                isolatedCabId: isolatedCabId
            )
            .ignoresSafeArea()
            KeyboardHost(onKey: handleKey)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
            HudOverlay(
                showingRemote: $showingRemote,
                selectedRemotePeerId: $selectedRemotePeerId,
                isolatedCabId: $isolatedCabId,
                onRecenter: {
                    isolatedCabId = nil
                    recenterTrigger &+= 1
                },
                onIsolate: { advanceIsolation() }
            )
            .padding(16)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color.black)
        .onChange(of: world.elevators.count) { _ in
            if showingRemote {
                let peers = world.remotePeerIds
                if peers.isEmpty {
                    showingRemote = false
                    selectedRemotePeerId = nil
                } else if let sel = selectedRemotePeerId, !peers.contains(sel) {
                    selectedRemotePeerId = peers.first
                }
            }
            if let id = isolatedCabId,
               !world.elevators.contains(where: { $0.id == id }) {
                isolatedCabId = nil
            }
        }
    }

    /// Picks the next cab to isolate. First press chooses an alarmed cab if
    /// any is active (so the operator drill-down lands on the cab that
    /// needs attention); subsequent presses cycle through the visible cabs.
    private func advanceIsolation() {
        let pool: [Elevator]
        if showingRemote {
            pool = world.sortedElevators.filter {
                $0.ownerPeerId != world.localPeerId
            }
        } else {
            pool = world.sortedElevators.filter {
                $0.ownerPeerId == world.localPeerId
            }
        }
        guard !pool.isEmpty else { isolatedCabId = nil; return }
        if isolatedCabId == nil {
            for cab in pool {
                let cabSource = "CAB \(world.displayLabel(for: cab))"
                if world.activeAlarms.contains(where: { $0.source == cabSource }) {
                    isolatedCabId = cab.id
                    return
                }
            }
            isolatedCabId = pool[0].id
            return
        }
        if let i = pool.firstIndex(where: { $0.id == isolatedCabId }) {
            isolatedCabId = pool[(i + 1) % pool.count].id
        } else {
            isolatedCabId = pool[0].id
        }
    }

    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.intersection([.command, .option, .control]).isEmpty else { return ev }
        let chars = (ev.charactersIgnoringModifiers ?? "").lowercased()
        switch chars {
        case "l":
            language.cycle()
            return nil
        case "v":
            isolatedCabId = nil
            if showingRemote {
                showingRemote = false
                selectedRemotePeerId = nil
            } else {
                let peers = world.remotePeerIds
                guard !peers.isEmpty else { return nil }
                showingRemote = true
                selectedRemotePeerId = peers.first
            }
            return nil
        case "r":
            isolatedCabId = nil
            recenterTrigger &+= 1
            return nil
        case "i":
            advanceIsolation()
            return nil
        case "q":
            NSApp.terminate(nil)
            return nil
        default:
            return ev
        }
    }
}

private struct HudOverlay: View {
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage
    @Binding var showingRemote: Bool
    @Binding var selectedRemotePeerId: String?
    @Binding var isolatedCabId: UUID?
    let onRecenter: () -> Void
    let onIsolate: () -> Void

    private var filteredCount: Int {
        if showingRemote {
            let remote = world.elevators.filter { $0.ownerPeerId != world.localPeerId }
            if let peerId = selectedRemotePeerId {
                return remote.filter { $0.ownerPeerId == peerId }.count
            }
            return remote.count
        } else {
            return world.elevators.filter { $0.ownerPeerId == world.localPeerId }.count
        }
    }

    private var hasRemoteCabs: Bool {
        world.elevators.contains { $0.ownerPeerId != world.localPeerId }
    }

    private var remotePeerIds: [String] {
        world.remotePeerIds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("─ \(language.t("window.scene")) ─")
                .font(RetroTheme.monoLg)
                .foregroundColor(RetroTheme.amber)
                .retroGlow()
            HStack(spacing: 18) {
                StatusLine(label: language.t("hud.cabs"),
                           value: "\(filteredCount)",
                           valueColor: RetroTheme.green)
                StatusLine(label: language.t("hud.floors"),
                           value: "\(Sim.firstFloor)–\(Sim.lastFloor)",
                           valueColor: RetroTheme.amberBright)
            }
            HStack(spacing: 12) {
                RetroButton(language.t("elev.localtag"),
                            highlighted: !showingRemote) {
                    isolatedCabId = nil
                    showingRemote = false
                    selectedRemotePeerId = nil
                }
                RetroButton(language.t("elev.remotetag"),
                            enabled: hasRemoteCabs,
                            highlighted: showingRemote) {
                    isolatedCabId = nil
                    showingRemote = true
                    if selectedRemotePeerId == nil ||
                       !remotePeerIds.contains(selectedRemotePeerId ?? "") {
                        selectedRemotePeerId = remotePeerIds.first
                    }
                }
            }
            .padding(.top, 4)

            if showingRemote && remotePeerIds.count > 1 {
                HStack(spacing: 8) {
                    Text("\(language.t("status.peers.node")):")
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amber)
                    ForEach(remotePeerIds, id: \.self) { peerId in
                        RetroButton(world.peerLetter(for: peerId),
                                    highlighted: selectedRemotePeerId == peerId) {
                            selectedRemotePeerId = peerId
                        }
                    }
                }
                .padding(.top, 2)
            }

            HStack(spacing: 12) {
                RetroButton(language.t("scene.recenter")) {
                    onRecenter()
                }
                RetroButton(language.t("scene.isolate")) {
                    onIsolate()
                }
            }
            .padding(.top, 4)

            if let id = isolatedCabId,
               let cab = world.elevators.first(where: { $0.id == id }) {
                Text("\(language.t("scene.isolated.prefix")) \(world.displayLabel(for: cab))")
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.cyan)
                    .padding(.top, 2)
            }

            HStack(spacing: 12) {
                ForEach(Lang.allCases) { lang in
                    RetroButton(lang.code, highlighted: language.current == lang) {
                        language.current = lang
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(10)
        .background(RetroTheme.bgPanel.opacity(0.85))
        .overlay(Rectangle().stroke(RetroTheme.amber.opacity(0.6), lineWidth: 1))
    }
}

struct ElevatorSceneRepresentable: NSViewRepresentable {
    let world: ElevatorWorld
    let showingRemote: Bool
    let selectedRemotePeerId: String?
    let recenterTrigger: Int
    let isolatedCabId: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(world: world, showingRemote: showingRemote,
                    selectedRemotePeerId: selectedRemotePeerId)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.showingRemote = showingRemote
        context.coordinator.selectedRemotePeerId = selectedRemotePeerId
        context.coordinator.isolatedCabId = isolatedCabId
        context.coordinator.sync()
        if recenterTrigger != context.coordinator.lastRecenterTrigger {
            context.coordinator.lastRecenterTrigger = recenterTrigger
            context.coordinator.recenterCamera()
        }
    }

    @MainActor
    final class Coordinator {
        let scene = SCNScene()
        let world: ElevatorWorld
        var showingRemote: Bool
        var selectedRemotePeerId: String?
        var lastRecenterTrigger: Int = 0
        var isolatedCabId: UUID? = nil
        private var lastAppliedIsolation: UUID? = nil
        private weak var sceneView: SCNView?
        private var cabNodes: [UUID: CabNodes] = [:]
        private var cameraNode: SCNNode?
        private var defaultCameraPosition: SCNVector3 = SCNVector3Zero
        private var defaultCameraEuler: SCNVector3 = SCNVector3Zero
        private var cancellable: AnyCancellable?
        private let shaftSpacing: Float = 3.2
        private let floorHeight: Float = 1.6
        private let cabWidth: Float = 1.7
        private let cabHeight: Float = 1.3
        private let cabDepth: Float = 1.3

        func attach(view: SCNView) {
            self.sceneView = view
            if let cam = cameraNode {
                view.pointOfView = cam
            }
        }

        func recenterCamera() {
            guard let cam = cameraNode else { return }
            cam.position = defaultCameraPosition
            cam.eulerAngles = defaultCameraEuler
            // Recompute z based on current cab count, the way sync() does.
            let visible = filteredElevators
            let count = max(1, visible.count)
            let totalSpan = Float(count - 1) * shaftSpacing + shaftSpacing
            let halfAngle = Float(22.5 * .pi / 180)
            let neededZ = max(14, Double(totalSpan / 2 / tan(halfAngle)))
            cam.position.z = neededZ
            // allowsCameraControl swaps in its own pointOfView once the user
            // orbits; reassigning forces the SCNView back to our camera.
            sceneView?.pointOfView = cam
            // Recenter implies leaving the isolate drill-down; restore
            // visibility on all shafts so the overview comes back.
            for (_, n) in cabNodes { n.shaftRoot.isHidden = false }
            lastAppliedIsolation = nil
        }

        // SCADA-style operator drill-down: hide every shaft but the
        // selected cab's, then frame the camera on that shaft so the
        // cab and door state can be inspected without the other lanes
        // crowding the view. Re-applied only when the isolated id
        // changes so the user can still orbit within an isolated view.
        private func applyIsolation() {
            if let id = isolatedCabId, let nodes = cabNodes[id] {
                for (cid, n) in cabNodes {
                    n.shaftRoot.isHidden = (cid != id)
                }
                if let cam = cameraNode {
                    let shaftX = nodes.shaftRoot.position.x
                    cam.eulerAngles = defaultCameraEuler
                    cam.position = SCNVector3(
                        Double(shaftX),
                        Double(floorHeight) * Double(Sim.floorCount) * 0.55,
                        11.0)
                    sceneView?.pointOfView = cam
                }
            } else {
                for (_, n) in cabNodes { n.shaftRoot.isHidden = false }
            }
        }

        struct CabNodes {
            let shaftRoot: SCNNode
            let cab: SCNNode
            let doorLeft: SCNNode
            let doorRight: SCNNode
            let label: SCNNode
            let floorReadout: SCNNode
        }

        init(world: ElevatorWorld, showingRemote: Bool, selectedRemotePeerId: String?) {
            self.world = world
            self.showingRemote = showingRemote
            self.selectedRemotePeerId = selectedRemotePeerId
            buildStaticScene()
            cancellable = world.$elevators
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.sync() }
        }

        private var filteredElevators: [Elevator] {
            if showingRemote {
                let remote = world.sortedElevators.filter {
                    $0.ownerPeerId != world.localPeerId
                }
                if let peerId = selectedRemotePeerId {
                    return remote.filter { $0.ownerPeerId == peerId }
                }
                return remote
            } else {
                return world.sortedElevators.filter {
                    $0.ownerPeerId == world.localPeerId
                }
            }
        }

        func sync() {
            let visible = filteredElevators
            let liveIds = Set(visible.map { $0.id })

            for (id, nodes) in cabNodes where !liveIds.contains(id) {
                nodes.shaftRoot.removeFromParentNode()
                cabNodes.removeValue(forKey: id)
            }

            for (index, elev) in visible.enumerated() {
                let nodes = cabNodes[elev.id] ?? makeCabNodes(forIndex: index,
                                                              elevator: elev)
                cabNodes[elev.id] = nodes
                positionShaft(nodes.shaftRoot, index: index, total: visible.count)
                updateCab(nodes: nodes, elevator: elev)
            }

            if isolatedCabId != lastAppliedIsolation {
                applyIsolation()
                lastAppliedIsolation = isolatedCabId
            }

            if isolatedCabId == nil {
                let count = max(1, visible.count)
                let totalSpan = Float(count - 1) * shaftSpacing + shaftSpacing
                let halfAngle = Float(22.5 * .pi / 180)
                let neededZ = max(14, Double(totalSpan / 2 / tan(halfAngle)))
                cameraNode?.position.z = neededZ
            }
        }

        private func buildStaticScene() {
            scene.background.contents = NSColor.black

            let camera = SCNCamera()
            camera.fieldOfView = 45
            camera.zNear = 0.1
            camera.zFar = 200
            let camNode = SCNNode()
            camNode.camera = camera
            camNode.position = SCNVector3(0,
                                          Double(floorHeight) * Double(Sim.floorCount) * 0.55,
                                          14)
            camNode.eulerAngles = SCNVector3(-0.18, 0, 0)
            scene.rootNode.addChildNode(camNode)
            self.cameraNode = camNode
            self.defaultCameraPosition = camNode.position
            self.defaultCameraEuler = camNode.eulerAngles

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.color = NSColor(white: 0.18, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .omni
            key.light?.color = NSColor(deviceRed: 1.0, green: 0.85,
                                       blue: 0.5, alpha: 1)
            key.light?.intensity = 1100
            key.position = SCNVector3(-3,
                                      Double(floorHeight) * Double(Sim.floorCount),
                                      8)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .omni
            fill.light?.color = NSColor(deviceRed: 0.35, green: 0.55,
                                        blue: 1.0, alpha: 1)
            fill.light?.intensity = 400
            fill.position = SCNVector3(6, Double(floorHeight) * 2, 6)
            scene.rootNode.addChildNode(fill)
        }

        private func positionShaft(_ shaft: SCNNode, index: Int, total: Int) {
            let count = max(1, total)
            let totalWidth = Float(count - 1) * shaftSpacing
            let x = -totalWidth / 2 + Float(index) * shaftSpacing
            shaft.position = SCNVector3(x, 0, 0)
        }

        private func makeCabNodes(forIndex index: Int,
                                  elevator: Elevator) -> CabNodes {
            let shaft = SCNNode()
            scene.rootNode.addChildNode(shaft)

            let shaftHeight = floorHeight * Float(Sim.floorCount)

            let backWall = SCNNode(geometry: SCNBox(
                width: CGFloat(cabWidth + 0.4),
                height: CGFloat(shaftHeight + 0.5),
                length: 0.05,
                chamferRadius: 0))
            backWall.geometry?.firstMaterial?.diffuse.contents =
                NSColor(white: 0.10, alpha: 1)
            backWall.geometry?.firstMaterial?.lightingModel = .lambert
            backWall.position = SCNVector3(0, Double(shaftHeight) / 2, -0.7)
            shaft.addChildNode(backWall)

            for floor in Sim.firstFloor...Sim.lastFloor {
                let y = Float(floor - 1) * floorHeight
                let ledge = SCNNode(geometry: SCNBox(
                    width: CGFloat(cabWidth + 0.4),
                    height: 0.04,
                    length: 0.15,
                    chamferRadius: 0))
                ledge.geometry?.firstMaterial?.diffuse.contents =
                    NSColor(deviceRed: 0.6, green: 0.45, blue: 0.18, alpha: 1)
                ledge.position = SCNVector3(0, Double(y), -0.55)
                shaft.addChildNode(ledge)

                let marker = SCNText(string: "\(floor)", extrusionDepth: 0.02)
                marker.font = NSFont(name: RetroTheme.retroFontName, size: 0.32)
                    ?? NSFont.monospacedSystemFont(ofSize: 0.32, weight: .bold)
                marker.firstMaterial?.diffuse.contents =
                    NSColor(deviceRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
                marker.firstMaterial?.emission.contents =
                    NSColor(deviceRed: 0.6, green: 0.35, blue: 0.05, alpha: 1)
                let markerNode = SCNNode(geometry: marker)
                markerNode.scale = SCNVector3(1, 1, 1)
                markerNode.position = SCNVector3(
                    Double(cabWidth) / 2 + 0.2,
                    Double(y) - 0.18,
                    -0.4)
                shaft.addChildNode(markerNode)
            }

            let cab = SCNNode(geometry: SCNBox(
                width: CGFloat(cabWidth),
                height: CGFloat(cabHeight),
                length: CGFloat(cabDepth),
                chamferRadius: 0.04))
            let isFreight = elevator.profile == .freight
            cab.geometry?.firstMaterial?.diffuse.contents = isFreight
                ? NSColor(deviceRed: 0.18, green: 0.22, blue: 0.30, alpha: 1)
                : NSColor(white: 0.22, alpha: 1)
            cab.geometry?.firstMaterial?.specular.contents =
                NSColor(white: 0.6, alpha: 1)
            shaft.addChildNode(cab)

            let doorLeft = SCNNode(geometry: SCNBox(
                width: CGFloat(cabWidth / 2 - 0.02),
                height: CGFloat(cabHeight - 0.1),
                length: 0.04,
                chamferRadius: 0))
            doorLeft.geometry?.firstMaterial?.diffuse.contents =
                NSColor(deviceRed: 0.32, green: 0.24, blue: 0.10, alpha: 1)
            doorLeft.geometry?.firstMaterial?.emission.contents =
                NSColor(deviceRed: 0.08, green: 0.06, blue: 0.02, alpha: 1)
            cab.addChildNode(doorLeft)

            let doorRight = SCNNode(geometry: SCNBox(
                width: CGFloat(cabWidth / 2 - 0.02),
                height: CGFloat(cabHeight - 0.1),
                length: 0.04,
                chamferRadius: 0))
            doorRight.geometry?.firstMaterial?.diffuse.contents =
                NSColor(deviceRed: 0.32, green: 0.24, blue: 0.10, alpha: 1)
            doorRight.geometry?.firstMaterial?.emission.contents =
                NSColor(deviceRed: 0.08, green: 0.06, blue: 0.02, alpha: 1)
            cab.addChildNode(doorRight)

            let labelString = world.displayLabel(for: elevator)
            let (labelPlane, _) = Self.makeLabelPlane(
                text: labelString, isFreight: isFreight)
            let labelNode = SCNNode(geometry: labelPlane)
            labelNode.name = "\(labelString):\(elevator.profile.rawValue)"
            labelNode.position = SCNVector3(0,
                                            Double(shaftHeight) + 0.35,
                                            0)
            shaft.addChildNode(labelNode)

            let floorText = SCNText(string: "1", extrusionDepth: 0.04)
            floorText.font = NSFont(name: RetroTheme.retroFontName, size: 0.22)
                ?? NSFont.monospacedSystemFont(ofSize: 0.22, weight: .bold)
            floorText.containerFrame = CGRect(x: 0, y: 0, width: 1.4, height: 0.4)
            floorText.alignmentMode =
                CATextLayerAlignmentMode.center.rawValue
            floorText.firstMaterial?.diffuse.contents =
                NSColor(deviceRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
            floorText.firstMaterial?.emission.contents =
                NSColor(deviceRed: 0.5, green: 0.3, blue: 0.05, alpha: 1)
            let floorNode = SCNNode(geometry: floorText)
            floorNode.position = SCNVector3(
                Double(-cabWidth) / 2 - 0.05,
                Double(cabHeight) / 2 + 0.1,
                Double(cabDepth) / 2)
            cab.addChildNode(floorNode)

            return CabNodes(shaftRoot: shaft, cab: cab,
                            doorLeft: doorLeft, doorRight: doorRight,
                            label: labelNode, floorReadout: floorNode)
        }

        private func updateCab(nodes: CabNodes, elevator: Elevator) {
            let y = Float(elevator.position - 1.0) * floorHeight
            nodes.cab.position = SCNVector3(0, Double(y), 0)

            let openness: Float
            switch elevator.doors {
            case .closed:  openness = 0
            case .opening: openness = Float(elevator.doorProgress)
            case .open:    openness = 1
            case .closing: openness = Float(1.0 - elevator.doorProgress)
            }
            let slide = openness * (cabWidth / 2 - 0.05)
            let baseX = (cabWidth / 4)
            nodes.doorLeft.position = SCNVector3(Double(-baseX - slide),
                                                 0,
                                                 Double(cabDepth) / 2)
            nodes.doorRight.position = SCNVector3(Double(baseX + slide),
                                                  0,
                                                  Double(cabDepth) / 2)

            let isFreight = elevator.profile == .freight
            nodes.cab.geometry?.firstMaterial?.diffuse.contents = isFreight
                ? NSColor(deviceRed: 0.18, green: 0.22, blue: 0.30, alpha: 1)
                : NSColor(white: 0.22, alpha: 1)

            let newLabel = world.displayLabel(for: elevator)
            let labelKey = "\(newLabel):\(elevator.profile.rawValue)"
            if nodes.label.name != labelKey {
                let (plane, _) = Self.makeLabelPlane(
                    text: newLabel, isFreight: isFreight)
                nodes.label.geometry = plane
                nodes.label.name = labelKey
            }

            if let textGeom = nodes.floorReadout.geometry as? SCNText {
                let new = String(format: "%2d", elevator.displayFloor)
                if (textGeom.string as? String) != new {
                    textGeom.string = new
                }
            }
        }

        private static func makeLabelPlane(
            text: String, isFreight: Bool
        ) -> (SCNPlane, NSImage) {
            let fontSize: CGFloat = 64
            let font = NSFont(name: RetroTheme.retroFontName, size: fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            let color = isFreight
                ? NSColor(deviceRed: 0.30, green: 0.85, blue: 1.0, alpha: 1)
                : NSColor(deviceRed: 0.36, green: 1.0, blue: 0.42, alpha: 1)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let size = str.size()
            let imgW = ceil(size.width) + 16
            let imgH = ceil(size.height) + 8

            let img = NSImage(size: NSSize(width: imgW, height: imgH))
            img.lockFocus()
            NSColor.clear.set()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: imgW, height: imgH))
            str.draw(at: NSPoint(x: 8, y: 4))
            img.unlockFocus()

            let worldHeight: CGFloat = 0.45
            let aspect = imgW / imgH
            let plane = SCNPlane(width: worldHeight * aspect,
                                 height: worldHeight)
            plane.firstMaterial?.diffuse.contents = img
            plane.firstMaterial?.lightingModel = .constant
            plane.firstMaterial?.isDoubleSided = true
            return (plane, img)
        }
    }
}
