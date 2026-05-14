import Foundation

enum PeerOp: String, Codable {
    case hello
    case state
    case remove
    case bye
}

struct PeerMessage: Codable {
    let op: PeerOp
    var peerId: String?
    var label: String?
    var elevator: Elevator?
    var elevatorId: UUID?

    static func hello(peerId: String, label: String) -> PeerMessage {
        PeerMessage(op: .hello, peerId: peerId, label: label, elevator: nil, elevatorId: nil)
    }

    static func state(_ elevator: Elevator) -> PeerMessage {
        PeerMessage(op: .state, peerId: nil, label: nil, elevator: elevator, elevatorId: nil)
    }

    static func remove(_ id: UUID) -> PeerMessage {
        PeerMessage(op: .remove, peerId: nil, label: nil, elevator: nil, elevatorId: id)
    }

    static func bye(peerId: String) -> PeerMessage {
        PeerMessage(op: .bye, peerId: peerId, label: nil, elevator: nil, elevatorId: nil)
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
