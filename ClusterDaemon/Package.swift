// swift-tools-version:5.9
import PackageDescription

// Headless cluster-peer daemon for ElevatorSystem.
//
// A self-contained SwiftPM executable -- no external dependencies, so it
// builds offline with `swift build` / `swift run`. It is deliberately kept
// as a SEPARATE tree from the XcodeGen-driven macOS app: the app links
// SwiftUI / SceneKit / AppKit, whereas this daemon only needs Foundation
// and Network.framework. The handful of wire types it shares with the app
// (the peer protocol and the Elevator model) are mirrored here rather than
// cross-imported; keep them in sync with Sources/ElevatorSystem/Networking/
// Protocol.swift and Sources/ElevatorSystem/Models/{Elevator,Constants}.swift.
let package = Package(
    name: "ElevatorClusterDaemon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "elevator-clusterd", targets: ["ElevatorClusterDaemon"])
    ],
    targets: [
        .executableTarget(
            name: "ElevatorClusterDaemon",
            path: "Sources/ElevatorClusterDaemon"
        )
    ]
)
