// Minimal DNS / mDNS wire codec.
//
// Just enough of RFC 1035 (+ the DNS-SD record shapes of RFC 6763) to publish
// and browse an `_elevatorsys._tcp.local` service without a dependency: PTR,
// SRV, TXT, and A records, plus AAAA tolerated on decode.
//
// Reading MUST decompress 0xC0 name pointers — Apple's `mDNSResponder`
// compresses aggressively. Writing emits fully-uncompressed names: valid, a few
// bytes larger, and far simpler to get right. All decode paths are bounds-
// checked and non-crashing: the input is untrusted multicast traffic.

enum DNSType: UInt16 {
    case a = 1
    case ptr = 12
    case txt = 16
    case aaaa = 28
    case srv = 33
    case any = 255
}

/// mDNS uses class IN (1); the top bit is the QU bit on questions and the
/// cache-flush bit on records.
let dnsClassIN: UInt16 = 0x0001
let dnsTopBit: UInt16 = 0x8000
/// QR bit in the header flags word — set on responses.
let dnsFlagResponse: UInt16 = 0x8000
/// AA bit — mDNS responders answer authoritatively.
let dnsFlagAuthoritative: UInt16 = 0x0400

struct DNSQuestion {
    var name: String
    var type: UInt16
    /// QU bit: the querier asked for a unicast reply.
    var unicastResponse: Bool
}

enum DNSRData {
    case a(UInt32)                 // IPv4 in network byte order (s_addr-ready)
    case ptr(String)               // target name
    case srv(priority: UInt16, weight: UInt16, port: UInt16, target: String)
    case txt([String])             // character-strings, each typically "key=value"
    case aaaa([UInt8])             // 16 bytes; decoded but not used for dialing
    case raw(type: UInt16, bytes: [UInt8])
}

struct DNSRecord {
    var name: String
    var type: UInt16
    var cacheFlush: Bool
    var ttl: UInt32
    var rdata: DNSRData

    /// Parses a TXT record's `key=value` strings into a dictionary (keys kept
    /// verbatim; DNS-SD keys are case-insensitive but we match exact case).
    var txtPairs: [String: String] {
        guard case let .txt(strings) = rdata else { return [:] }
        var out: [String: String] = [:]
        for s in strings {
            if let eq = s.firstIndex(of: "=") {
                out[String(s[..<eq])] = String(s[s.index(after: eq)...])
            } else {
                out[s] = ""
            }
        }
        return out
    }
}

struct DNSMessage {
    var id: UInt16 = 0
    var flags: UInt16 = 0
    var questions: [DNSQuestion] = []
    var answers: [DNSRecord] = []
    var authorities: [DNSRecord] = []
    var additionals: [DNSRecord] = []

    var isResponse: Bool { flags & dnsFlagResponse != 0 }

    /// Every record regardless of section — a browser resolving a service must
    /// look in additionals (where Apple bundles SRV/TXT/A), not just answers.
    var allRecords: [DNSRecord] { answers + authorities + additionals }

    // MARK: encode

    func encode() -> [UInt8] {
        let w = DNSWriter()
        w.u16(id)
        w.u16(flags)
        w.u16(UInt16(questions.count))
        w.u16(UInt16(answers.count))
        w.u16(UInt16(authorities.count))
        w.u16(UInt16(additionals.count))
        for q in questions {
            w.name(q.name)
            w.u16(q.type)
            w.u16((q.unicastResponse ? dnsTopBit : 0) | dnsClassIN)
        }
        for r in answers { DNSMessage.encodeRecord(w, r) }
        for r in authorities { DNSMessage.encodeRecord(w, r) }
        for r in additionals { DNSMessage.encodeRecord(w, r) }
        return w.buf
    }

    private static func encodeRecord(_ w: DNSWriter, _ r: DNSRecord) {
        w.name(r.name)
        w.u16(r.type)
        w.u16((r.cacheFlush ? dnsTopBit : 0) | dnsClassIN)
        w.u32(r.ttl)
        let rd = DNSWriter()
        switch r.rdata {
        case let .a(ip):
            let host = UInt32(bigEndian: ip)
            rd.bytes([UInt8(host >> 24 & 0xff), UInt8(host >> 16 & 0xff),
                      UInt8(host >> 8 & 0xff), UInt8(host & 0xff)])
        case let .ptr(target):
            rd.name(target)
        case let .srv(priority, weight, port, target):
            rd.u16(priority); rd.u16(weight); rd.u16(port); rd.name(target)
        case let .txt(strings):
            if strings.isEmpty {
                rd.u8(0)                       // a TXT with a single empty string
            } else {
                for s in strings {
                    let sb = Array(s.utf8.prefix(255))
                    rd.u8(UInt8(sb.count)); rd.bytes(sb)
                }
            }
        case let .aaaa(b):
            rd.bytes(b)
        case let .raw(_, b):
            rd.bytes(b)
        }
        w.u16(UInt16(rd.buf.count))
        w.bytes(rd.buf)
    }

    // MARK: decode

    static func decode(_ data: [UInt8]) -> DNSMessage? {
        let r = DNSReader(data)
        do {
            var m = DNSMessage()
            m.id = try r.u16()
            m.flags = try r.u16()
            let qd = try r.u16(); let an = try r.u16(); let ns = try r.u16(); let ar = try r.u16()
            for _ in 0..<qd {
                let name = try r.name()
                let type = try r.u16()
                let qclass = try r.u16()
                m.questions.append(DNSQuestion(name: name, type: type,
                                               unicastResponse: qclass & dnsTopBit != 0))
            }
            m.answers = try DNSMessage.readRecords(r, an)
            m.authorities = try DNSMessage.readRecords(r, ns)
            m.additionals = try DNSMessage.readRecords(r, ar)
            return m
        } catch {
            return nil
        }
    }

    private static func readRecords(_ r: DNSReader, _ count: UInt16) throws -> [DNSRecord] {
        var out: [DNSRecord] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count { out.append(try readRecord(r)) }
        return out
    }

    private static func readRecord(_ r: DNSReader) throws -> DNSRecord {
        let name = try r.name()
        let type = try r.u16()
        let cls = try r.u16()
        let ttl = try r.u32()
        let rdlen = Int(try r.u16())
        let rdStart = r.pos
        let rdata: DNSRData
        switch type {
        case DNSType.a.rawValue:
            let b = try r.bytes(4)
            rdata = .a(Net.ipv4(b[0], b[1], b[2], b[3]))
        case DNSType.ptr.rawValue:
            rdata = .ptr(try r.name())
        case DNSType.srv.rawValue:
            let priority = try r.u16(); let weight = try r.u16(); let port = try r.u16()
            rdata = .srv(priority: priority, weight: weight, port: port, target: try r.name())
        case DNSType.txt.rawValue:
            rdata = .txt(try readTXT(r, rdlen))
        case DNSType.aaaa.rawValue:
            rdata = .aaaa(try r.bytes(min(16, max(0, rdlen))))
        default:
            rdata = .raw(type: type, bytes: try r.bytes(rdlen))
        }
        // Trust RDLENGTH over how far the type-specific parse advanced — this
        // resynchronises even if a compressed name inside RDATA left the cursor
        // somewhere unexpected, or the record type surprised us.
        r.pos = rdStart + rdlen
        return DNSRecord(name: name, type: type, cacheFlush: cls & dnsTopBit != 0,
                         ttl: ttl, rdata: rdata)
    }

    private static func readTXT(_ r: DNSReader, _ rdlen: Int) throws -> [String] {
        var out: [String] = []
        let end = r.pos + rdlen
        while r.pos < end {
            let len = Int(try r.u8())
            if len == 0 { continue }
            guard r.pos + len <= end else { break }
            out.append(String(decoding: try r.bytes(len), as: UTF8.self))
        }
        return out
    }

    // MARK: self-test

    /// Loopback encode→decode plus a hand-built compression-pointer fixture.
    /// Run at startup under a debug flag, mirroring the app's `SELFTEST` ethos.
    static func selfTest() -> Bool {
        // 1. Round-trip a full DNS-SD announcement.
        let instance = "SIMNODE-abc12345._elevatorsys._tcp.local"
        var msg = DNSMessage()
        msg.flags = dnsFlagResponse | dnsFlagAuthoritative
        msg.answers = [DNSRecord(name: "_elevatorsys._tcp.local", type: DNSType.ptr.rawValue,
                                 cacheFlush: false, ttl: 4500, rdata: .ptr(instance))]
        msg.additionals = [
            DNSRecord(name: instance, type: DNSType.srv.rawValue, cacheFlush: true, ttl: 120,
                      rdata: .srv(priority: 0, weight: 0, port: 52017, target: "clusterd-abc12345.local")),
            DNSRecord(name: instance, type: DNSType.txt.rawValue, cacheFlush: true, ttl: 120,
                      rdata: .txt(["peerId=ABC12345-DEAD", "label=SIMNODE"])),
            DNSRecord(name: "clusterd-abc12345.local", type: DNSType.a.rawValue, cacheFlush: true,
                      ttl: 120, rdata: .a(Net.ipv4(192, 168, 1, 42))),
        ]
        guard let decoded = DNSMessage.decode(msg.encode()) else { return false }
        guard decoded.isResponse,
              decoded.answers.count == 1,
              case let .ptr(t) = decoded.answers[0].rdata, t == instance else { return false }
        var sawSRV = false, sawTXT = false, sawA = false
        for rec in decoded.additionals {
            switch rec.rdata {
            case let .srv(_, _, port, target):
                sawSRV = (port == 52017 && target == "clusterd-abc12345.local")
            case .txt:
                sawTXT = (rec.txtPairs["peerId"] == "ABC12345-DEAD" && rec.txtPairs["label"] == "SIMNODE")
            case let .a(ip):
                sawA = (ip == Net.ipv4(192, 168, 1, 42))
            default: break
            }
        }
        guard sawSRV, sawTXT, sawA else { return false }

        // 2. Decode a fixture whose question name is a compression pointer.
        //    Header (id=0, flags=0, qd=1); then the literal name
        //    "x._tcp.local" at offset 12, then a second question that points
        //    back to it — proving pointer following resolves the full name.
        var raw: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        let nameStart = raw.count                    // offset 12
        for label in ["x", "_tcp", "local"] {
            raw.append(UInt8(label.utf8.count)); raw.append(contentsOf: label.utf8)
        }
        raw.append(0x00)
        raw.append(contentsOf: [0x00, 0x0c, 0x00, 0x01])              // type PTR, class IN
        raw.append(contentsOf: [0xc0, UInt8(nameStart)])             // pointer to offset 12
        raw.append(contentsOf: [0x00, 0x0c, 0x00, 0x01])
        guard let ptrMsg = DNSMessage.decode(raw),
              ptrMsg.questions.count == 2,
              ptrMsg.questions[0].name == "x._tcp.local",
              ptrMsg.questions[1].name == "x._tcp.local" else { return false }
        return true
    }
}

// MARK: - readers / writers

/// Bounds-checked cursor over a received datagram. Every read throws rather
/// than trapping so a malformed packet degrades to a nil decode.
final class DNSReader {
    private let buf: [UInt8]
    var pos: Int = 0

    init(_ buf: [UInt8]) { self.buf = buf }

    struct Overflow: Error {}

    func u8() throws -> UInt8 {
        guard pos < buf.count else { throw Overflow() }
        defer { pos += 1 }
        return buf[pos]
    }

    func u16() throws -> UInt16 {
        let hi = try u8(); let lo = try u8()
        return UInt16(hi) << 8 | UInt16(lo)
    }

    func u32() throws -> UInt32 {
        let hi = try u16(); let lo = try u16()
        return UInt32(hi) << 16 | UInt32(lo)
    }

    func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos + n <= buf.count else { throw Overflow() }
        defer { pos += n }
        return Array(buf[pos..<pos + n])
    }

    /// Reads a (possibly compressed) domain name. Advances `pos` to just past
    /// the name in the *current* section — following a pointer does not drag
    /// the cursor to the pointed-at location.
    func name() throws -> String {
        var labels: [String] = []
        var cursor = pos
        var jumped = false
        var hops = 0
        while true {
            guard cursor < buf.count else { throw Overflow() }
            let len = buf[cursor]
            if len & 0xC0 == 0xC0 {
                guard cursor + 1 < buf.count else { throw Overflow() }
                let ptr = (Int(len & 0x3F) << 8) | Int(buf[cursor + 1])
                if !jumped { pos = cursor + 2 }
                jumped = true
                cursor = ptr
                hops += 1
                if hops > 128 { throw Overflow() }   // malformed or pointer loop
            } else if len == 0 {
                if !jumped { pos = cursor + 1 }
                break
            } else {
                let start = cursor + 1
                let end = start + Int(len)
                guard end <= buf.count else { throw Overflow() }
                labels.append(String(decoding: buf[start..<end], as: UTF8.self))
                cursor = end
                if !jumped { pos = end }
            }
        }
        return labels.joined(separator: ".")
    }
}

final class DNSWriter {
    var buf: [UInt8] = []

    func u8(_ v: UInt8) { buf.append(v) }
    func u16(_ v: UInt16) { buf.append(UInt8(v >> 8)); buf.append(UInt8(v & 0xff)) }
    func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xffff)) }
    func bytes(_ b: [UInt8]) { buf.append(contentsOf: b) }

    /// Emits a name as length-prefixed labels ending in a zero byte — never
    /// compressed.
    func name(_ s: String) {
        for label in s.split(separator: ".") {
            let lb = Array(label.utf8.prefix(63))
            buf.append(UInt8(lb.count))
            buf.append(contentsOf: lb)
        }
        buf.append(0)
    }
}
