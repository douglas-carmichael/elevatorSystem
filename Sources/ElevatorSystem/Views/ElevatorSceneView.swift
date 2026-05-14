import SwiftUI
import SceneKit
import AppKit
import Combine

struct ElevatorSceneWindow: View {
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        ZStack(alignment: .topLeading) {
            ElevatorSceneRepresentable(world: world)
                .ignoresSafeArea()
            KeyboardHost(onKey: handleKey)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
            HudOverlay()
                .padding(16)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color.black)
    }

    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.intersection([.command, .option, .control]).isEmpty else { return ev }
        let chars = (ev.charactersIgnoringModifiers ?? "").lowercased()
        switch chars {
        case "l":
            language.cycle()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("─ \(language.t("window.scene")) ─")
                .font(RetroTheme.monoLg)
                .foregroundColor(RetroTheme.amber)
                .retroGlow()
            HStack(spacing: 18) {
                StatusLine(label: language.t("hud.cabs"),
                           value: "\(world.elevators.count)",
                           valueColor: RetroTheme.green)
                StatusLine(label: language.t("hud.floors"),
                           value: "\(Sim.firstFloor)–\(Sim.lastFloor)",
                           valueColor: RetroTheme.amberBright)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(world: world)
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
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator {
        let scene = SCNScene()
        let world: ElevatorWorld
        private var cabNodes: [UUID: CabNodes] = [:]
        private var cancellable: AnyCancellable?
        private let shaftSpacing: Float = 3.2
        private let floorHeight: Float = 1.6
        private let cabWidth: Float = 1.7
        private let cabHeight: Float = 1.3
        private let cabDepth: Float = 1.3

        struct CabNodes {
            let shaftRoot: SCNNode
            let cab: SCNNode
            let doorLeft: SCNNode
            let doorRight: SCNNode
            let label: SCNNode
            let floorReadout: SCNNode
        }

        init(world: ElevatorWorld) {
            self.world = world
            buildStaticScene()
            cancellable = world.$elevators
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.sync() }
        }

        func sync() {
            let liveIds = Set(world.elevators.map { $0.id })
            for (id, nodes) in cabNodes where !liveIds.contains(id) {
                nodes.shaftRoot.removeFromParentNode()
                cabNodes.removeValue(forKey: id)
            }

            for (index, elev) in world.elevators.enumerated() {
                let nodes = cabNodes[elev.id] ?? makeCabNodes(forIndex: index, elevator: elev)
                cabNodes[elev.id] = nodes
                positionShaft(nodes.shaftRoot, index: index)
                updateCab(nodes: nodes, elevator: elev)
            }
        }

        private func buildStaticScene() {
            scene.background.contents = NSColor.black

            let camera = SCNCamera()
            camera.fieldOfView = 45
            camera.zNear = 0.1
            camera.zFar = 200
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, Double(floorHeight) * Double(Sim.floorCount) * 0.55, 14)
            cameraNode.eulerAngles = SCNVector3(-0.18, 0, 0)
            scene.rootNode.addChildNode(cameraNode)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.color = NSColor(white: 0.18, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .omni
            key.light?.color = NSColor(deviceRed: 1.0, green: 0.85, blue: 0.5, alpha: 1)
            key.light?.intensity = 1100
            key.position = SCNVector3(-3, Double(floorHeight) * Double(Sim.floorCount), 8)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .omni
            fill.light?.color = NSColor(deviceRed: 0.35, green: 0.55, blue: 1.0, alpha: 1)
            fill.light?.intensity = 400
            fill.position = SCNVector3(6, Double(floorHeight) * 2, 6)
            scene.rootNode.addChildNode(fill)
        }

        private func positionShaft(_ shaft: SCNNode, index: Int) {
            let count = max(1, world.elevators.count)
            let totalWidth = Float(count - 1) * shaftSpacing
            let x = -totalWidth / 2 + Float(index) * shaftSpacing
            shaft.position = SCNVector3(x, 0, 0)
        }

        private func makeCabNodes(forIndex index: Int, elevator: Elevator) -> CabNodes {
            let shaft = SCNNode()
            scene.rootNode.addChildNode(shaft)

            let shaftHeight = floorHeight * Float(Sim.floorCount)

            let backWall = SCNNode(geometry: SCNBox(width: CGFloat(cabWidth + 0.4),
                                                    height: CGFloat(shaftHeight + 0.5),
                                                    length: 0.05,
                                                    chamferRadius: 0))
            backWall.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.10, alpha: 1)
            backWall.geometry?.firstMaterial?.lightingModel = .lambert
            backWall.position = SCNVector3(0, Double(shaftHeight) / 2, -0.7)
            shaft.addChildNode(backWall)

            for floor in Sim.firstFloor...Sim.lastFloor {
                let y = Float(floor - 1) * floorHeight
                let ledge = SCNNode(geometry: SCNBox(width: CGFloat(cabWidth + 0.4),
                                                     height: 0.04,
                                                     length: 0.15,
                                                     chamferRadius: 0))
                ledge.geometry?.firstMaterial?.diffuse.contents = NSColor(deviceRed: 0.6, green: 0.45, blue: 0.18, alpha: 1)
                ledge.position = SCNVector3(0, Double(y), -0.55)
                shaft.addChildNode(ledge)

                let marker = SCNText(string: "\(floor)", extrusionDepth: 0.02)
                marker.font = NSFont(name: RetroTheme.retroFontName, size: 0.32)
                    ?? NSFont.monospacedSystemFont(ofSize: 0.32, weight: .bold)
                marker.firstMaterial?.diffuse.contents = NSColor(deviceRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
                marker.firstMaterial?.emission.contents = NSColor(deviceRed: 0.6, green: 0.35, blue: 0.05, alpha: 1)
                let markerNode = SCNNode(geometry: marker)
                markerNode.scale = SCNVector3(1, 1, 1)
                markerNode.position = SCNVector3(Double(cabWidth) / 2 + 0.2, Double(y) - 0.18, -0.4)
                shaft.addChildNode(markerNode)
            }

            let cab = SCNNode(geometry: SCNBox(width: CGFloat(cabWidth),
                                                height: CGFloat(cabHeight),
                                                length: CGFloat(cabDepth),
                                                chamferRadius: 0.04))
            cab.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.22, alpha: 1)
            cab.geometry?.firstMaterial?.specular.contents = NSColor(white: 0.6, alpha: 1)
            shaft.addChildNode(cab)

            let doorLeft = SCNNode(geometry: SCNBox(width: CGFloat(cabWidth / 2 - 0.02),
                                                     height: CGFloat(cabHeight - 0.1),
                                                     length: 0.04,
                                                     chamferRadius: 0))
            doorLeft.geometry?.firstMaterial?.diffuse.contents = NSColor(deviceRed: 0.32, green: 0.24, blue: 0.10, alpha: 1)
            doorLeft.geometry?.firstMaterial?.emission.contents = NSColor(deviceRed: 0.08, green: 0.06, blue: 0.02, alpha: 1)
            cab.addChildNode(doorLeft)

            let doorRight = SCNNode(geometry: SCNBox(width: CGFloat(cabWidth / 2 - 0.02),
                                                      height: CGFloat(cabHeight - 0.1),
                                                      length: 0.04,
                                                      chamferRadius: 0))
            doorRight.geometry?.firstMaterial?.diffuse.contents = NSColor(deviceRed: 0.32, green: 0.24, blue: 0.10, alpha: 1)
            doorRight.geometry?.firstMaterial?.emission.contents = NSColor(deviceRed: 0.08, green: 0.06, blue: 0.02, alpha: 1)
            cab.addChildNode(doorRight)

            let labelText = SCNText(string: elevator.label, extrusionDepth: 0.04)
            labelText.font = NSFont(name: RetroTheme.retroFontName, size: 0.35)
                ?? NSFont.monospacedSystemFont(ofSize: 0.35, weight: .bold)
            labelText.firstMaterial?.diffuse.contents = NSColor(deviceRed: 0.36, green: 1.0, blue: 0.42, alpha: 1)
            labelText.firstMaterial?.emission.contents = NSColor(deviceRed: 0.18, green: 0.5, blue: 0.22, alpha: 1)
            let labelNode = SCNNode(geometry: labelText)
            labelNode.position = SCNVector3(-0.6, Double(shaftHeight) + 0.1, 0)
            shaft.addChildNode(labelNode)

            let floorText = SCNText(string: "1", extrusionDepth: 0.04)
            floorText.font = NSFont(name: RetroTheme.retroFontName, size: 0.30)
                ?? NSFont.monospacedSystemFont(ofSize: 0.30, weight: .bold)
            floorText.firstMaterial?.diffuse.contents = NSColor(deviceRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
            floorText.firstMaterial?.emission.contents = NSColor(deviceRed: 0.5, green: 0.3, blue: 0.05, alpha: 1)
            let floorNode = SCNNode(geometry: floorText)
            floorNode.position = SCNVector3(-0.3, Double(shaftHeight) - 0.35, 0)
            shaft.addChildNode(floorNode)

            return CabNodes(shaftRoot: shaft, cab: cab, doorLeft: doorLeft, doorRight: doorRight, label: labelNode, floorReadout: floorNode)
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
            nodes.doorLeft.position = SCNVector3(Double(-baseX - slide), 0, Double(cabDepth) / 2)
            nodes.doorRight.position = SCNVector3(Double(baseX + slide), 0, Double(cabDepth) / 2)

            if let textGeom = nodes.floorReadout.geometry as? SCNText {
                let new = String(format: "%2d", elevator.displayFloor)
                if (textGeom.string as? String) != new {
                    textGeom.string = new
                }
            }
        }
    }
}
