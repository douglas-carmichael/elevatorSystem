import Foundation
import Network

/// Modbus TCP server on `127.0.0.1:5020` that exposes elevator state at
/// standard register addresses so any PLC HMI, SCADA front-end, or
/// industrial-automation toolchain (OpenPLC, Node-RED, FactoryIO,
/// pymodbus, mbpoll, QModMaster, ...) can read cab positions and
/// drive cars over the wire the same way it would talk to a real
/// elevator controller's gateway.
///
/// Port 502 is the Modbus-TCP IANA-registered port, but Unix systems
/// require root to bind below 1024 -- we use 5020, the canonical
/// non-privileged alternative every industrial-automation tool
/// supports via `-p 5020`.
///
/// Register map (8 cabs supported, 0-indexed Modbus addresses):
///
///   Coils (single-bit, R/W) -- FC 01 read, FC 05 write:
///     0..7    Cab[0..7]  Door OPEN command
///     8..15   Cab[0..7]  Door CLOSE command
///     16..23  Cab[0..7]  STOP / cancel queue
///
///   Discrete inputs (single-bit, RO) -- FC 02:
///     0..7    Cab[0..7]  is locally owned
///     8..15   Cab[0..7]  is moving  (direction != idle)
///     16..23  Cab[0..7]  doors open (state == open)
///     24..31  Cab[0..7]  holding brake engaged
///     32..39  Cab[0..7]  door light-curtain obstructed
///     40..47  Cab[0..7]  platform overload  (load > 110% rated)
///
///   Holding registers (16-bit, R/W) -- FC 03 read, FC 06 write:
///     0..7    Cab[0..7]  Profile      (0 = PAX,    1 = Freight)
///     8..15   Cab[0..7]  Mode         (0 = Manual, 1 = Auto)
///     16..23  Cab[0..7]  Target floor (write to enqueue a CALL)
///
///   Input registers (16-bit, RO) -- FC 04:
///     0..7    Cab[0..7]  Position x10 (floor 3.5 = 35)
///     8..15   Cab[0..7]  Direction    (0=idle, 1=up, 2=down)
///     16..23  Cab[0..7]  Door state   (0=closed, 1=opening, 2=open, 3=closing)
///     24..31  Cab[0..7]  Queue depth
///     32..39  Cab[0..7]  Door progress (0..100 percent)
///     40..47  Cab[0..7]  Cab velocity x100 (signed Int16)
///     48..55  Cab[0..7]  Platform load (kg)
///     100     Number of cabs registered
///     101     Number of remote peers connected
///     102     Building floor count (top floor)
///     103     Number of telnet sessions
///     104     Number of Modbus clients connected
///     105     Building safety mode  (0=normal, 1=fire, 2=EPO)
///     106     Recall floor
///     107     Active SCADA alarm count
///     108     Highest active severity (0=none, 1=Advisory, 2=Minor, 3=Major, 4=Critical)
///     109     Dispatch mode (0=collective, 1=destination)
///     110     Active hall-call count
///
/// Function codes accepted: FC 01/02/03/04/05/06/0F/10. Anything else
/// returns exception 0x01 (illegal function). Requests for any unit-id
/// other than this dispatcher's id (=1) or the broadcast id (=0) get
/// exception 0x02 (illegal data address).
@MainActor
final class ModbusTCPServer: ObservableObject {
    @Published private(set) var port: UInt16?
    /// Number of active Modbus client connections. Drives the MODBUS
    /// indicator in the Group Dispatcher status strip.
    @Published private(set) var clientCount: Int = 0

    private weak var world: ElevatorWorld?
    private weak var network: PeerNetwork?
    private weak var automation: AutoDriver?
    private weak var telnet: DCLTelnetServer?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "net.dcarmichael.elevator.modbus")
    private var clients: [ObjectIdentifier: ModbusClient] = [:] {
        didSet { clientCount = clients.count }
    }

    static let defaultPort: UInt16 = 5020
    static let maxCabs: Int = 8
    /// Modbus slave address of this dispatcher. Convention on TCP is
    /// to address a single device as unit-id 1; clients targeting any
    /// other unit-id (other than the broadcast id 0) get an exception
    /// 0x02 (illegal data address) response, matching how a real
    /// gateway behaves when forwarded a request for a missing slave.
    static let localUnitId: UInt8 = 1

    init() {}

    func attach(world: ElevatorWorld, network: PeerNetwork,
                automation: AutoDriver, telnet: DCLTelnetServer) {
        self.world = world
        self.network = network
        self.automation = automation
        self.telnet = telnet
    }

    func start() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: Self.defaultPort) else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            NSLog("ModbusTCPServer: failed to bind to port \(Self.defaultPort): \(error)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                if case .ready = state {
                    self.port = Self.defaultPort
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { @MainActor in self.handleNewConnection(conn) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, client) in clients { client.cancel() }
        clients.removeAll()
        port = nil
    }

    private func handleNewConnection(_ conn: NWConnection) {
        guard let world, let network, let automation else {
            conn.cancel()
            return
        }
        let client = ModbusClient(connection: conn,
                                  world: world,
                                  network: network,
                                  automation: automation,
                                  telnet: telnet,
                                  modbusServer: self,
                                  queue: queue)
        client.onClose = { [weak self, weak client] in
            guard let self, let client else { return }
            Task { @MainActor in
                self.clients.removeValue(forKey: ObjectIdentifier(client))
            }
        }
        clients[ObjectIdentifier(client)] = client
        client.start()
    }
}

/// One Modbus-TCP client connection. Parses MBAP-framed PDUs, dispatches
/// supported function codes (FC 01/02/03/04/05/06), and answers with
/// either the response PDU or a Modbus exception (function code OR'd
/// with 0x80 + 1-byte exception code).
@MainActor
final class ModbusClient {
    private let connection: NWConnection
    private weak var world: ElevatorWorld?
    private weak var network: PeerNetwork?
    private weak var automation: AutoDriver?
    private weak var telnet: DCLTelnetServer?
    private weak var modbusServer: ModbusTCPServer?
    private let queue: DispatchQueue
    private var inboundBuffer: Data = Data()
    private var closed = false

    var onClose: (() -> Void)?

    init(connection: NWConnection,
         world: ElevatorWorld,
         network: PeerNetwork,
         automation: AutoDriver,
         telnet: DCLTelnetServer?,
         modbusServer: ModbusTCPServer,
         queue: DispatchQueue) {
        self.connection = connection
        self.world = world
        self.network = network
        self.automation = automation
        self.telnet = telnet
        self.modbusServer = modbusServer
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor in self.receiveLoop() }
            case .failed, .cancelled:
                Task { @MainActor in self.fireClose() }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: -- Receive loop / framing

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.inboundBuffer.append(data)
                    self.drainFrames()
                }
            }
            if isComplete || error != nil {
                Task { @MainActor in self.fireClose() }
                return
            }
            Task { @MainActor in self.receiveLoop() }
        }
    }

    /// MBAP header is 7 bytes; the `Length` field at offset 4-5 covers
    /// everything after the length field (Unit ID + PDU).
    ///
    /// `Data.removeFirst(_:)` advances the buffer's `startIndex` rather
    /// than physically dropping bytes, so all reads here are anchored to
    /// the current `startIndex`. `subdata(in:)` returns a fresh `Data`
    /// (startIndex 0) so `handleFrame` can use absolute offsets safely.
    private func drainFrames() {
        while inboundBuffer.count >= 7 {
            let base = inboundBuffer.startIndex
            let length = (UInt16(inboundBuffer[base + 4]) << 8)
                       | UInt16(inboundBuffer[base + 5])
            let totalSize = 6 + Int(length)
            guard inboundBuffer.count >= totalSize else { return }
            let frame = inboundBuffer.subdata(in: base..<(base + totalSize))
            inboundBuffer.removeFirst(totalSize)
            handleFrame(frame)
        }
    }

    private func handleFrame(_ frame: Data) {
        guard frame.count >= 8 else { return }
        let txnId = (UInt16(frame[0]) << 8) | UInt16(frame[1])
        let unitId = frame[6]
        let fc = frame[7]
        let pdu = frame.subdata(in: 8..<frame.count)

        // Unit-id (slave-address) gating. Modbus reserves 0 for
        // broadcast (we accept it but don't respond per spec... we do
        // here so a generic client doesn't time out); any non-local
        // unit-id gets exception 0x02 (illegal data address). A real
        // gateway behaves the same way when it doesn't have a slave
        // configured at that address.
        if unitId != 0 && unitId != ModbusTCPServer.localUnitId {
            sendResponse(txnId: txnId,
                         unitId: unitId,
                         pdu: Data([fc | 0x80, 0x02]))
            return
        }

        let response: Data
        switch fc {
        case 0x01: response = handleReadCoils(pdu)
        case 0x02: response = handleReadDiscreteInputs(pdu)
        case 0x03: response = handleReadHoldingRegisters(pdu)
        case 0x04: response = handleReadInputRegisters(pdu)
        case 0x05: response = handleWriteSingleCoil(pdu)
        case 0x06: response = handleWriteSingleRegister(pdu)
        case 0x0F: response = handleWriteMultipleCoils(pdu)
        case 0x10: response = handleWriteMultipleRegisters(pdu)
        default:
            response = Data([fc | 0x80, 0x01])      // illegal function
        }
        sendResponse(txnId: txnId, unitId: unitId, pdu: response)
    }

    private func sendResponse(txnId: UInt16, unitId: UInt8, pdu: Data) {
        var out = Data()
        out.append(UInt8(txnId >> 8))
        out.append(UInt8(txnId & 0xFF))
        out.append(0x00); out.append(0x00)          // protocol id = 0
        let length = UInt16(1 + pdu.count)
        out.append(UInt8(length >> 8))
        out.append(UInt8(length & 0xFF))
        out.append(unitId)
        out.append(pdu)
        connection.send(content: out, completion: .contentProcessed { _ in })
    }

    private func fireClose() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    // MARK: -- Function-code handlers

    private func handleReadCoils(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x81, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        guard count >= 1, count <= 2000 else { return Data([0x81, 0x03]) }
        let byteCount = (Int(count) + 7) / 8
        var bits = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<Int(count) {
            if readCoil(at: start &+ UInt16(i)) {
                bits[i / 8] |= UInt8(1 << (i % 8))
            }
        }
        var out = Data([0x01, UInt8(byteCount)])
        out.append(contentsOf: bits)
        return out
    }

    private func handleReadDiscreteInputs(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x82, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        guard count >= 1, count <= 2000 else { return Data([0x82, 0x03]) }
        let byteCount = (Int(count) + 7) / 8
        var bits = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<Int(count) {
            if readDiscreteInput(at: start &+ UInt16(i)) {
                bits[i / 8] |= UInt8(1 << (i % 8))
            }
        }
        var out = Data([0x02, UInt8(byteCount)])
        out.append(contentsOf: bits)
        return out
    }

    private func handleReadHoldingRegisters(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x83, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        guard count >= 1, count <= 125 else { return Data([0x83, 0x03]) }
        var out = Data([0x03, UInt8(count * 2)])
        for i in 0..<Int(count) {
            let v = readHoldingRegister(at: start &+ UInt16(i))
            out.append(UInt8(v >> 8))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }

    private func handleReadInputRegisters(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x84, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        guard count >= 1, count <= 125 else { return Data([0x84, 0x03]) }
        var out = Data([0x04, UInt8(count * 2)])
        for i in 0..<Int(count) {
            let v = readInputRegister(at: start &+ UInt16(i))
            out.append(UInt8(v >> 8))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }

    private func handleWriteSingleCoil(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x85, 0x03]) }
        let addr = u16(pdu, 0)
        let value = u16(pdu, 2)
        guard value == 0x0000 || value == 0xFF00 else {
            return Data([0x85, 0x03])
        }
        writeCoil(at: addr, on: value == 0xFF00)
        return pdu                                  // echo
    }

    private func handleWriteSingleRegister(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x86, 0x03]) }
        let addr = u16(pdu, 0)
        let value = u16(pdu, 2)
        writeHoldingRegister(at: addr, value: value)
        return pdu                                  // echo
    }

    /// FC 0x0F -- Write Multiple Coils. Lets a PLC stage several
    /// commands (e.g. close-all-doors across the building) in one
    /// transaction. Response echoes the starting address and the coil
    /// count, per spec §6.11.
    private func handleWriteMultipleCoils(_ pdu: Data) -> Data {
        guard pdu.count >= 5 else { return Data([0x8F, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        let byteCount = Int(pdu[pdu.startIndex + 4])
        guard count >= 1, count <= 1968,
              byteCount == (Int(count) + 7) / 8,
              pdu.count >= 5 + byteCount
        else { return Data([0x8F, 0x03]) }
        for i in 0..<Int(count) {
            let byte = pdu[pdu.startIndex + 5 + i / 8]
            let bit = (byte >> UInt8(i % 8)) & 0x01
            writeCoil(at: start &+ UInt16(i), on: bit == 1)
        }
        var out = Data([0x0F])
        out.append(UInt8(start >> 8))
        out.append(UInt8(start & 0xFF))
        out.append(UInt8(count >> 8))
        out.append(UInt8(count & 0xFF))
        return out
    }

    /// FC 0x10 -- Write Multiple Registers. The bread-and-butter call
    /// for a real PLC HMI pushing setpoints: load N consecutive
    /// holding registers in a single request (e.g. dispatch every
    /// cab's target floor at once). Response echoes the starting
    /// address and register count, per spec §6.12.
    private func handleWriteMultipleRegisters(_ pdu: Data) -> Data {
        guard pdu.count >= 5 else { return Data([0x90, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        let byteCount = Int(pdu[pdu.startIndex + 4])
        guard count >= 1, count <= 123,
              byteCount == Int(count) * 2,
              pdu.count >= 5 + byteCount
        else { return Data([0x90, 0x03]) }
        for i in 0..<Int(count) {
            let value = u16(pdu, 5 + i * 2)
            writeHoldingRegister(at: start &+ UInt16(i), value: value)
        }
        var out = Data([0x10])
        out.append(UInt8(start >> 8))
        out.append(UInt8(start & 0xFF))
        out.append(UInt8(count >> 8))
        out.append(UInt8(count & 0xFF))
        return out
    }

    // MARK: -- Register accessors

    private func cab(at index: Int) -> Elevator? {
        guard let cabs = world?.sortedElevators, index < cabs.count else { return nil }
        return cabs[index]
    }

    private func readCoil(at address: UInt16) -> Bool {
        let group = Int(address) / 8
        let cabIdx = Int(address) % 8
        guard let c = cab(at: cabIdx) else { return false }
        switch group {
        case 0:                                     // door OPEN command (pending?)
            return c.doors == .opening
        case 1:                                     // door CLOSE command
            return c.doors == .closing
        case 2:                                     // STOP active
            return c.queue.isEmpty == false
        default:
            return false
        }
    }

    private func writeCoil(at address: UInt16, on: Bool) {
        guard on else { return }                    // pulse-on commands only
        let group = Int(address) / 8
        let cabIdx = Int(address) % 8
        guard let c = cab(at: cabIdx), let world else { return }
        switch group {
        case 0:                                     // door OPEN
            _ = world.mutateLocal(c.id) { e in e.requestDoorsOpen() }
        case 1:                                     // door CLOSE
            _ = world.mutateLocal(c.id) { e in e.requestDoorsClose() }
        case 2:                                     // STOP / cancel queue
            _ = world.mutateLocal(c.id) { e in e.queue.removeAll() }
        default:
            break
        }
    }

    private func readDiscreteInput(at address: UInt16) -> Bool {
        let group = Int(address) / 8
        let cabIdx = Int(address) % 8
        guard let c = cab(at: cabIdx) else { return false }
        switch group {
        case 0: return world?.canControl(c) ?? false
        case 1: return c.direction != .idle
        case 2: return c.doors == .open
        case 3: return c.brakeEngaged
        case 4: return c.doorObstructed
        case 5: return c.loadKg > c.profile.ratedLoadKg * 1.10
        default: return false
        }
    }

    private func readHoldingRegister(at address: UInt16) -> UInt16 {
        let group = Int(address) / 8
        let cabIdx = Int(address) % 8
        guard let c = cab(at: cabIdx) else { return 0 }
        switch group {
        case 0: return c.profile == .freight ? 1 : 0
        case 1: return c.automatic ? 1 : 0
        case 2: return 0                            // target floor: write-only
        default: return 0
        }
    }

    private func writeHoldingRegister(at address: UInt16, value: UInt16) {
        let group = Int(address) / 8
        let cabIdx = Int(address) % 8
        guard let c = cab(at: cabIdx), let world else { return }
        switch group {
        case 0:                                     // profile
            _ = world.mutateLocal(c.id) { e in
                e.profile = (value == 0 ? .pax : .freight)
            }
        case 1:                                     // mode
            if value == 0 {
                _ = automation?.takeManualControl(cabId: c.id)
            } else {
                _ = automation?.returnToAutomatic(cabId: c.id)
            }
        case 2:                                     // target floor -> enqueue
            let floor = Int(value)
            _ = world.mutateLocal(c.id) { e in e.enqueue(floor: floor) }
        default:
            break
        }
    }

    private func readInputRegister(at address: UInt16) -> UInt16 {
        if address < 40 {
            let group = Int(address) / 8
            let cabIdx = Int(address) % 8
            guard let c = cab(at: cabIdx) else { return 0 }
            switch group {
            case 0:                                 // position x10
                return UInt16(max(0, min(0xFFFF, Int(c.position * 10.0))))
            case 1:                                 // direction
                switch c.direction {
                case .idle: return 0
                case .up:   return 1
                case .down: return 2
                }
            case 2:                                 // door state
                switch c.doors {
                case .closed:  return 0
                case .opening: return 1
                case .open:    return 2
                case .closing: return 3
                }
            case 3:                                 // queue depth
                return UInt16(c.queue.count)
            case 4:                                 // door progress %
                return UInt16(c.doorProgress * 100.0)
            case 5:                                 // velocity x 100 (signed)
                let v = Int(c.velocity * 100.0)
                let clamped = max(-32768, min(32767, v))
                return UInt16(bitPattern: Int16(clamped))
            case 6:                                 // platform load (kg)
                return UInt16(max(0, min(0xFFFF, Int(c.loadKg.rounded()))))
            default:
                return 0
            }
        }
        switch address {
        case 100: return UInt16(world?.elevators.count ?? 0)
        case 101: return UInt16(network?.peers.count ?? 0)
        case 102: return UInt16(Sim.lastFloor)
        case 103: return UInt16(telnet?.sessionCount ?? 0)
        case 104: return UInt16(modbusServer?.clientCount ?? 0)
        case 105:                                   // Building mode
            switch world?.buildingMode {
            case .fireRecall:     return 1
            case .emergencyPower: return 2
            default:              return 0
            }
        case 106: return UInt16(world?.recallFloor ?? Sim.firstFloor)
        case 107:                                   // Active alarm count
            return UInt16(min(0xFFFF, world?.activeAlarms.count ?? 0))
        case 109:                                   // Dispatch mode
            return world?.dispatchMode == .destination ? 1 : 0
        case 108:                                   // Highest active severity
            // 0 = no active alarms, 1..4 = Advisory / Minor / Major /
            // Critical. Lets a PLC HMI light a coloured beacon
            // straight from one register read instead of pulling the
            // whole alarm log over Modbus.
            guard let s = world?.highestActiveSeverity else { return 0 }
            return UInt16(s.rawValue + 1)
        case 110: return UInt16(min(0xFFFF, world?.hallCalls.count ?? 0))
        default:  return 0
        }
    }

    // MARK: -- Helpers

    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        return (UInt16(data[data.startIndex + offset]) << 8)
             | UInt16(data[data.startIndex + offset + 1])
    }
}
