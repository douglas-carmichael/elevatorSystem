// Cross-platform BSD-socket shim.
//
// The daemon's non-Apple transport (`SocketPeerLink`, `MDNSEngine`) talks to
// the kernel through raw BSD sockets. The call signatures, handle types, error
// reporting, and a few option constants differ across Darwin, glibc, musl, and
// WinSDK; this file hides those differences behind one small Swift-typed API so
// the rest of the socket code reads the same on every platform.
//
// IPv4 addresses cross this API as `UInt32` in **network byte order** (the
// value you can drop straight into `sockaddr_in.sin_addr`); ports cross as
// host-order `UInt16`. Blocking sockets throughout — concurrency is provided by
// the caller's threads, not by non-blocking I/O here.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

// MARK: -- handle type

#if os(Windows)
typealias SocketFD = SOCKET
/// `INVALID_SOCKET` is `(SOCKET)(~0)`; spelled numerically to avoid depending on
/// the macro importing into Swift.
let invalidSocketFD = SocketFD.max
#else
typealias SocketFD = Int32
let invalidSocketFD: SocketFD = -1
#endif

@inline(__always)
func isValidSocket(_ fd: SocketFD) -> Bool {
    #if os(Windows)
    return fd != invalidSocketFD
    #else
    return fd >= 0
    #endif
}

// MARK: -- namespace

enum Net {
    /// mDNS group 224.0.0.251 and port, exposed so the engine doesn't repeat
    /// the literals.
    static let mdnsGroup: UInt32 = ipv4(224, 0, 0, 251)
    static let mdnsPort: UInt16 = 5353

    // MARK: process-wide setup

    /// Winsock needs `WSAStartup` before any socket call; POSIX needs SIGPIPE
    /// ignored so a write to a peer that closed mid-broadcast doesn't kill the
    /// process (Network.framework hid this on Apple; raw sockets don't).
    static func initialize() {
        #if os(Windows)
        var wsa = WSADATA()
        _ = WSAStartup(0x0202, &wsa)   // MAKEWORD(2, 2)
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif
    }

    static func teardown() {
        #if os(Windows)
        _ = WSACleanup()
        #endif
    }

    // MARK: address helpers

    /// Builds a dotted-quad into an `s_addr`-ready network-order `UInt32`.
    /// `.bigEndian` is `htonl`, so this is endianness-correct, not LE-only.
    @inline(__always)
    static func ipv4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        let host = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
        return host.bigEndian
    }

    /// Parses "a.b.c.d" to a network-order `UInt32`, or nil if malformed.
    static func parseIPv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var octets = [UInt8]()
        for p in parts {
            guard let v = UInt8(p) else { return nil }
            octets.append(v)
        }
        return ipv4(octets[0], octets[1], octets[2], octets[3])
    }

    /// Formats a network-order `s_addr` as "a.b.c.d".
    static func ipv4String(_ netOrder: UInt32) -> String {
        let host = UInt32(bigEndian: netOrder)
        return "\(host >> 24 & 0xff).\(host >> 16 & 0xff).\(host >> 8 & 0xff).\(host & 0xff)"
    }

    /// The primary reachable LAN IPv4 (network order), for the mDNS A record.
    ///
    /// Uses the portable "UDP connect" trick: connecting a datagram socket sends
    /// nothing but makes the kernel pick the source address it would route from,
    /// which `getsockname` then reports. Works the same on POSIX and Winsock and
    /// needs no `getifaddrs`/`GetAdaptersAddresses`. Loopback/0.0.0.0 results are
    /// rejected so we don't advertise an address no peer could dial.
    static func primaryIPv4() -> UInt32? {
        for target in [ipv4(8, 8, 8, 8), mdnsGroup] {
            let fd = makeUDP()
            guard isValidSocket(fd) else { continue }
            defer { closeFD(fd) }
            guard connect(fd, ip: target, port: 53) else { continue }
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &addr) { p -> Bool in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 }
            }
            guard ok else { continue }
            let ip = addrOf(addr)
            let host = UInt32(bigEndian: ip)
            if ip != 0 && (host >> 24) != 127 { return ip }   // reject 0.0.0.0 and 127/8
        }
        return nil
    }

    private static func makeSockaddrIn(ip: UInt32, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_addr.S_un.S_addr = ip
        #elseif canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = ip
        #else
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = ip
        #endif
        addr.sin_port = port.bigEndian
        return addr
    }

    private static func addrOf(_ sa: sockaddr_in) -> UInt32 {
        #if os(Windows)
        return sa.sin_addr.S_un.S_addr
        #else
        return sa.sin_addr.s_addr
        #endif
    }

    // MARK: socket creation

    static func makeTCP() -> SocketFD { socket(AF_INET, sockStream, 0) }
    static func makeUDP() -> SocketFD { socket(AF_INET, sockDgram, 0) }

    // SOCK_STREAM == 1, SOCK_DGRAM == 2 on Linux/macOS/Windows. Hardcoded
    // because the symbols import inconsistently — a plain Int32 macro on
    // Darwin/musl/Windows, but a typed `enum __socket_type` on glibc (where
    // `.rawValue` would be required and would then fail to compile elsewhere).
    private static let sockStream: Int32 = 1
    private static let sockDgram: Int32 = 2

    // MARK: options

    /// IP-level options use protocol level `IPPROTO_IP`, which is 0 everywhere;
    /// spelled as a literal to sidestep the constant importing as an enum.
    private static let ipLevel: Int32 = 0

    private static func setIntOption(_ fd: SocketFD, level: Int32, name: Int32, value: Int32) {
        var v = value
        withUnsafePointer(to: &v) { p in
            #if os(Windows)
            p.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) { cp in
                _ = setsockopt(fd, level, name, cp, Int32(MemoryLayout<Int32>.size))
            }
            #else
            _ = setsockopt(fd, level, name, p, socklen_t(MemoryLayout<Int32>.size))
            #endif
        }
    }

    /// `SO_REUSEADDR` (+ `SO_REUSEPORT` where it exists) so the mDNS socket can
    /// share :5353 with the system responder and restarts rebind promptly.
    static func setReuse(_ fd: SocketFD) {
        setIntOption(fd, level: Int32(SOL_SOCKET), name: Int32(SO_REUSEADDR), value: 1)
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        // SO_REUSEPORT is absent from WinSDK; required alongside SO_REUSEADDR on
        // BSD/Darwin to actually share the multicast port.
        setIntOption(fd, level: Int32(SOL_SOCKET), name: Int32(SO_REUSEPORT), value: 1)
        #endif
    }

    static func setMulticastTTL(_ fd: SocketFD, _ ttl: Int32) {
        // RFC 6762 §11: mDNS is sent with IP TTL 255; conformant responders may
        // drop lower-TTL packets.
        setIntOption(fd, level: ipLevel, name: Int32(IP_MULTICAST_TTL), value: ttl)
    }

    static func setMulticastLoop(_ fd: SocketFD, _ on: Bool) {
        setIntOption(fd, level: ipLevel, name: Int32(IP_MULTICAST_LOOP), value: on ? 1 : 0)
    }

    static func joinMulticast(_ fd: SocketFD, group: UInt32) -> Bool {
        var mreq = ip_mreq()
        #if os(Windows)
        mreq.imr_multiaddr.S_un.S_addr = group
        mreq.imr_interface.S_un.S_addr = 0   // INADDR_ANY: default interface
        #else
        mreq.imr_multiaddr.s_addr = group
        mreq.imr_interface.s_addr = 0
        #endif
        return withUnsafePointer(to: &mreq) { p -> Bool in
            #if os(Windows)
            return p.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<ip_mreq>.size) { cp in
                setsockopt(fd, ipLevel, Int32(IP_ADD_MEMBERSHIP), cp, Int32(MemoryLayout<ip_mreq>.size)) == 0
            }
            #else
            return setsockopt(fd, ipLevel, Int32(IP_ADD_MEMBERSHIP), p, socklen_t(MemoryLayout<ip_mreq>.size)) == 0
            #endif
        }
    }

    // MARK: bind / listen / accept / connect

    /// Binds to `0.0.0.0:port` (port 0 → kernel-assigned). Returns success.
    static func bindAny(_ fd: SocketFD, port: UInt16) -> Bool {
        var addr = makeSockaddrIn(ip: 0, port: port)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// The actual port a socket is bound to (for reading back a `bind(:0)`).
    static func boundPort(_ fd: SocketFD) -> UInt16? {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len) == 0
            }
        }
        guard ok else { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }

    // Qualify the C symbol: this enum has its own `accept`/`connect` statics, so
    // bare calls could resolve to the wrong thing; `listen` is qualified for
    // symmetry and clarity.
    static func listen(_ fd: SocketFD, backlog: Int32 = 16) -> Bool {
        #if canImport(Darwin)
        return Darwin.listen(fd, backlog) == 0
        #elseif canImport(Glibc)
        return Glibc.listen(fd, backlog) == 0
        #elseif canImport(Musl)
        return Musl.listen(fd, backlog) == 0
        #else
        return WinSDK.listen(fd, backlog) == 0
        #endif
    }

    /// Accepts one connection; returns the new fd and the peer's IP (network
    /// order) for logging, or nil on error.
    static func accept(_ fd: SocketFD) -> (fd: SocketFD, peerIP: UInt32)? {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &addr) { p -> SocketFD in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                #if canImport(Darwin)
                return Darwin.accept(fd, sa, &len)
                #elseif canImport(Glibc)
                return Glibc.accept(fd, sa, &len)
                #elseif canImport(Musl)
                return Musl.accept(fd, sa, &len)
                #else
                return WinSDK.accept(fd, sa, &len)
                #endif
            }
        }
        guard isValidSocket(client) else { return nil }
        return (client, addrOf(addr))
    }

    static func connect(_ fd: SocketFD, ip: UInt32, port: UInt16) -> Bool {
        var addr = makeSockaddrIn(ip: ip, port: port)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                #if canImport(Darwin)
                return Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                #elseif canImport(Glibc)
                return Glibc.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                #elseif canImport(Musl)
                return Musl.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                #else
                return WinSDK.connect(fd, sa, Int32(MemoryLayout<sockaddr_in>.size)) == 0
                #endif
            }
        }
    }

    // MARK: stream I/O

    /// Sends every byte (looping over partial writes). False on error/closed.
    static func sendAll(_ fd: SocketFD, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        return bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }   // empty send is a no-op success
            while offset < bytes.count {
                let n = rawSend(fd, base + offset, bytes.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Reads up to `max` bytes. nil on peer-close (0) or error (<0).
    static func recvSome(_ fd: SocketFD, max: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return rawRecv(fd, base, max)
        }
        guard n > 0 else { return nil }
        return Array(buf[0..<n])
    }

    private static func rawSend(_ fd: SocketFD, _ ptr: UnsafeRawPointer, _ len: Int) -> Int {
        #if os(Windows)
        return Int(WinSDK.send(fd, ptr.assumingMemoryBound(to: CChar.self), Int32(len), 0))
        #elseif canImport(Darwin)
        return Darwin.send(fd, ptr, len, 0)
        #elseif canImport(Glibc)
        return Glibc.send(fd, ptr, len, 0)
        #else
        return Musl.send(fd, ptr, len, 0)
        #endif
    }

    private static func rawRecv(_ fd: SocketFD, _ ptr: UnsafeMutableRawPointer, _ len: Int) -> Int {
        #if os(Windows)
        return Int(WinSDK.recv(fd, ptr.assumingMemoryBound(to: CChar.self), Int32(len), 0))
        #elseif canImport(Darwin)
        return Darwin.recv(fd, ptr, len, 0)
        #elseif canImport(Glibc)
        return Glibc.recv(fd, ptr, len, 0)
        #else
        return Musl.recv(fd, ptr, len, 0)
        #endif
    }

    // MARK: datagram I/O

    static func sendTo(_ fd: SocketFD, _ bytes: [UInt8], ip: UInt32, port: UInt16) -> Bool {
        var addr = makeSockaddrIn(ip: ip, port: port)
        return withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bytes.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    let salen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    #if os(Windows)
                    let n = WinSDK.sendto(fd, base.assumingMemoryBound(to: CChar.self), Int32(bytes.count), 0, sa, Int32(salen))
                    return n == Int32(bytes.count)
                    #elseif canImport(Darwin)
                    return Darwin.sendto(fd, base, bytes.count, 0, sa, salen) == bytes.count
                    #elseif canImport(Glibc)
                    return Glibc.sendto(fd, base, bytes.count, 0, sa, salen) == bytes.count
                    #else
                    return Musl.sendto(fd, base, bytes.count, 0, sa, salen) == bytes.count
                    #endif
                }
            }
        }
    }

    /// Blocks for one datagram. Returns payload + source IP (network order) and
    /// source port (host order), or nil on error.
    static func recvFrom(_ fd: SocketFD, max: Int) -> (bytes: [UInt8], ip: UInt32, port: UInt16)? {
        var buf = [UInt8](repeating: 0, count: max)
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) { ap -> Int in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                buf.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    #if os(Windows)
                    return Int(WinSDK.recvfrom(fd, base.assumingMemoryBound(to: CChar.self), Int32(max), 0, sa, &len))
                    #elseif canImport(Darwin)
                    return Darwin.recvfrom(fd, base, max, 0, sa, &len)
                    #elseif canImport(Glibc)
                    return Glibc.recvfrom(fd, base, max, 0, sa, &len)
                    #else
                    return Musl.recvfrom(fd, base, max, 0, sa, &len)
                    #endif
                }
            }
        }
        guard n >= 0 else { return nil }
        return (Array(buf[0..<n]), addrOf(addr), UInt16(bigEndian: addr.sin_port))
    }

    // MARK: teardown

    /// Unblocks a thread parked in `recv`/`accept` so it can be joined, then the
    /// fd is closed. `shutdown` is racier than close-from-another-thread but is
    /// the portable way to wake a blocked reader.
    static func shutdownBoth(_ fd: SocketFD) {
        #if os(Windows)
        _ = WinSDK.shutdown(fd, 2)   // SD_BOTH == 2 (macro may not import)
        #elseif canImport(Darwin)
        _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
        #elseif canImport(Glibc)
        _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
        #else
        _ = Musl.shutdown(fd, Int32(SHUT_RDWR))
        #endif
    }

    static func closeFD(_ fd: SocketFD) {
        guard isValidSocket(fd) else { return }
        #if os(Windows)
        _ = closesocket(fd)
        #elseif canImport(Darwin)
        _ = Darwin.close(fd)
        #elseif canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Musl.close(fd)
        #endif
    }
}
