import Foundation

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
    var snapshot: HostStats.HostSnapshot?

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

    static func stats(peerId: String, snapshot: HostStats.HostSnapshot) -> PeerMessage {
        PeerMessage(op: .stats, peerId: peerId, label: nil, elevator: nil, elevatorId: nil, snapshot: snapshot)
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
