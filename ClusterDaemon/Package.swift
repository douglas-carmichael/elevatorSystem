// swift-tools-version:5.9
import PackageDescription

// Headless cluster-peer daemon for ElevatorSystem.
//
// A self-contained SwiftPM executable -- no external dependencies, so it
// builds offline with `swift build` / `swift run`. It is deliberately kept
// as a SEPARATE tree from the XcodeGen-driven macOS app: the app links
// SwiftUI / SceneKit / AppKit, whereas this daemon only needs Foundation.
//
// CROSS-PLATFORM: builds and runs on macOS, Linux, and Windows. On Apple it
// uses Bonjour/Network.framework (auto-linked via `import Network`); elsewhere
// it uses a hand-rolled mDNS + BSD-socket transport that speaks the same wire.
// `platforms:` only sets the Apple deployment floor -- Linux and Windows build
// implicitly and are not constrained by it.
//
// The handful of wire types it shares with the app (the peer protocol and the
// Elevator model) are mirrored here rather than cross-imported; keep them in
// sync with Sources/ElevatorSystem/Networking/Protocol.swift and
// Sources/ElevatorSystem/Models/{Elevator,Constants}.swift.
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
            path: "Sources/ElevatorClusterDaemon",
            linkerSettings: [
                // Winsock (sockets) + PSAPI (EnumProcesses / GetProcessMemoryInfo).
                // IOKit/Network on macOS auto-link from their `import`s.
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("psapi", .when(platforms: [.windows])),
            ]
        )
    ]
)
