import Foundation

// WIRE-COMPATIBLE MIRROR of Sources/ElevatorSystem/Networking/Protocol.swift.
//
// Newline-delimited JSON over TCP. The app uses a plain JSONEncoder /
// JSONDecoder (default `deferredToDate` date strategy) for this channel --
// we must too, or the `.stats` snapshot's `sampledAt` would fail to decode
// on the app side. Optional fields are encoded with `encodeIfPresent`
// (Swift's synthesized Codable), so a `.hello` carries only op/peerId/label.

/// Mirror of the app's `HostStats.HostSnapshot`. The enclosing type name
/// doesn't travel on the wire -- only the property names below do -- so a
/// top-level struct with matching fields is interchangeable with the app's
/// nested one. Feeds the app's MONITOR CLUSTER per-node row.
struct HostSnapshot: Codable {
    let cpuBusy: Double            // percent
    let memUsedPercent: Double
    let bufferedIORate: Double     // page-fault rate / sec
    let directIORate: Double       // disk ops / sec
    let lockRate: Double           // synthetic; lookups / sec
    let processCount: Int
    let sampledAt: Date
}

enum PeerOp: String, Codable {
    case hello
    case state
    case remove
    case bye
    case stats
}

struct PeerMessage: Codable {
    let op: PeerOp
    var peerId: String?
    var label: String?
    var elevator: Elevator?
    var elevatorId: UUID?
    var snapshot: HostSnapshot?

    static func hello(peerId: String, label: String) -> PeerMessage {
        PeerMessage(op: .hello, peerId: peerId, label: label, elevator: nil, elevatorId: nil, snapshot: nil)
    }

    static func state(_ elevator: Elevator) -> PeerMessage {
        PeerMessage(op: .state, peerId: nil, label: nil, elevator: elevator, elevatorId: nil, snapshot: nil)
    }

    static func remove(_ id: UUID) -> PeerMessage {
        PeerMessage(op: .remove, peerId: nil, label: nil, elevator: nil, elevatorId: id, snapshot: nil)
    }

    static func bye(peerId: String) -> PeerMessage {
        PeerMessage(op: .bye, peerId: peerId, label: nil, elevator: nil, elevatorId: nil, snapshot: nil)
    }

    static func stats(peerId: String, snapshot: HostSnapshot) -> PeerMessage {
        PeerMessage(op: .stats, peerId: peerId, label: nil, elevator: nil, elevatorId: nil, snapshot: snapshot)
    }
}

enum WireCodec {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    static func encode(_ msg: PeerMessage) -> Data? {
        guard var body = try? encoder.encode(msg) else { return nil }
        body.append(0x0A)   // newline frame terminator
        return body
    }

    static func decode(_ line: Data) -> PeerMessage? {
        try? decoder.decode(PeerMessage.self, from: line)
    }
}
