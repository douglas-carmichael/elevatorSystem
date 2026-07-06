import Foundation

enum PeerOp: String, Codable {
    case hello
    case state
    case remove
    case bye
    case stats
    /// A control request aimed at a cab OWNED BY THE RECEIVER. It lets a
    /// node drive a cab it doesn't own: the request travels to the owning
    /// peer, which applies it to its own cab and broadcasts the resulting
    /// `.state` back. The receiver only ever mutates cabs it owns, so this
    /// carries no authority beyond "please queue this on your cab".
    case command
}

/// The manipulations one node can request of another node's cab. Mirrors
/// exactly the dispatch actions the operator can already perform on a
/// locally-owned cab (floor call, doors open / close, abort queue).
enum CabCommandKind: String, Codable {
    case call    // enqueue a floor (car call)
    case open    // request doors open
    case close   // request doors close
    case stop    // clear the queue (abort outstanding calls)
}

/// A control request for a specific remote cab. `floor` is only meaningful
/// for `.call`; `originPeerId` records the requester for audit/logging.
struct CabCommand: Codable, Hashable {
    var elevatorId: UUID
    var kind: CabCommandKind
    var floor: Int?
    var originPeerId: String
}

struct PeerMessage: Codable {
    let op: PeerOp
    var peerId: String?
    var label: String?
    var elevator: Elevator?
    var elevatorId: UUID?
    var snapshot: HostStats.HostSnapshot?
    var command: CabCommand?

    static func hello(peerId: String, label: String) -> PeerMessage {
        PeerMessage(op: .hello, peerId: peerId, label: label, elevator: nil, elevatorId: nil, snapshot: nil, command: nil)
    }

    static func state(_ elevator: Elevator) -> PeerMessage {
        PeerMessage(op: .state, peerId: nil, label: nil, elevator: elevator, elevatorId: nil, snapshot: nil, command: nil)
    }

    static func remove(_ id: UUID) -> PeerMessage {
        PeerMessage(op: .remove, peerId: nil, label: nil, elevator: nil, elevatorId: id, snapshot: nil, command: nil)
    }

    static func bye(peerId: String) -> PeerMessage {
        PeerMessage(op: .bye, peerId: peerId, label: nil, elevator: nil, elevatorId: nil, snapshot: nil, command: nil)
    }

    static func stats(peerId: String, snapshot: HostStats.HostSnapshot) -> PeerMessage {
        PeerMessage(op: .stats, peerId: peerId, label: nil, elevator: nil, elevatorId: nil, snapshot: snapshot, command: nil)
    }

    static func command(_ command: CabCommand) -> PeerMessage {
        PeerMessage(op: .command, peerId: nil, label: nil, elevator: nil, elevatorId: nil, snapshot: nil, command: command)
    }
}

enum WireCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    static func encode(_ msg: PeerMessage) -> Data? {
        guard var body = try? encoder.encode(msg) else { return nil }
        body.append(0x0A)
        return body
    }

    static func decode(_ line: Data) -> PeerMessage? {
        try? decoder.decode(PeerMessage.self, from: line)
    }
}
