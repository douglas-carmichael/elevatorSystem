import Foundation
import Network

/// Lightweight TCP listener on `127.0.0.1` that lets an external
/// terminal emulator (Terminal.app, iTerm, xterm, ...) connect to a
/// fresh DCL shell session. Each accepted connection gets its own
/// `DCLEngine`, attached to the shared elevator world / network /
/// automation / language objects, so a telnet client can drive cabs,
/// run `SHOW SYSTEM`, etc. side-by-side with the local SwiftUI shell.
///
/// Connect with:    telnet localhost 2323     (or `nc localhost 2323`)
///
/// Bound to loopback only -- the listener never accepts off-host
/// connections.
@MainActor
final class DCLTelnetServer: ObservableObject {
    /// Port the listener is currently bound to, or `nil` until it has
    /// successfully entered the `.ready` state.
    @Published private(set) var port: UInt16?

    private weak var world: ElevatorWorld?
    private weak var network: PeerNetwork?
    private weak var automation: AutoDriver?
    private weak var language: AppLanguage?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "net.dcarmichael.elevator.telnet")
    private var sessions: [ObjectIdentifier: TelnetSession] = [:]

    static let defaultPort: UInt16 = 2323

    init() {}

    func attach(world: ElevatorWorld, network: PeerNetwork,
                automation: AutoDriver, language: AppLanguage) {
        self.world = world
        self.network = network
        self.automation = automation
        self.language = language
    }

    func start() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: Self.defaultPort) else { return }
        let params = NWParameters.tcp
        // Loopback only: refuse off-host connections.
        params.requiredInterfaceType = .loopback
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            NSLog("DCLTelnetServer: failed to bind to port \(Self.defaultPort): \(error)")
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
        for (_, session) in sessions { session.cancel() }
        sessions.removeAll()
        port = nil
    }

    private func handleNewConnection(_ conn: NWConnection) {
        guard let world, let network else {
            conn.cancel()
            return
        }
        let engine = DCLEngine()
        engine.attach(world: world, network: network,
                      automation: automation, language: language)
        let session = TelnetSession(connection: conn, engine: engine, queue: queue)
        session.onClose = { [weak self, weak session] in
            guard let self, let session else { return }
            Task { @MainActor in
                self.sessions.removeValue(forKey: ObjectIdentifier(session))
            }
        }
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }
}

/// One accepted TCP connection. Owns its own `DCLEngine`,
/// `LineDiscipline`, and `NWConnection`. The receive loop forwards
/// raw bytes into the line discipline; the engine's `outputHandler`
/// pushes whatever the shell emits back out to the socket (with the
/// usual LF -> CRLF normalisation so cursor placement stays correct
/// on telnet-line-mode clients).
@MainActor
final class TelnetSession {
    private let connection: NWConnection
    private let engine: DCLEngine
    private var lineDiscipline: LineDiscipline?
    private let queue: DispatchQueue
    private var closed = false

    var onClose: (() -> Void)?

    init(connection: NWConnection, engine: DCLEngine, queue: DispatchQueue) {
        self.connection = connection
        self.engine = engine
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor in self.handleReady() }
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

    private func handleReady() {
        // Engine pushes user-visible output (banner, prompt, command
        // results) here; we normalise LF -> CRLF so telnet line-mode
        // clients advance to the next line cleanly.
        engine.outputHandler = { [weak self] text in
            guard let self else { return }
            self.sendNormalised(text)
        }
        // The line discipline emits raw bytes (CR / cursor escapes /
        // line redraw) straight to the socket without touching the
        // transcript.
        lineDiscipline = LineDiscipline(dcl: engine) { [weak self] raw in
            guard let self else { return }
            self.sendRaw(raw)
        }
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let bytes = Array(data)
                Task { @MainActor in
                    self.lineDiscipline?.process(bytes)
                }
            }
            if isComplete || error != nil {
                Task { @MainActor in self.fireClose() }
                return
            }
            self.receiveLoop()
        }
    }

    private func sendNormalised(_ text: String) {
        // Mirrors VTShellView.normalizeLineEndings -- engine emits bare
        // LF, telnet clients in line mode expect CRLF.
        guard text.contains("\n") else { return sendRaw(text) }
        var out = ""
        out.reserveCapacity(text.count + 8)
        var prev: Character = "\0"
        for ch in text {
            if ch == "\n" && prev != "\r" { out.append("\r") }
            out.append(ch)
            prev = ch
        }
        sendRaw(out)
    }

    private func sendRaw(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func fireClose() {
        guard !closed else { return }
        closed = true
        // Tear down monitor / test timers held by the engine before
        // dropping the reference so they don't keep firing on a session
        // nobody can see.
        if engine.liveActive {
            engine.stopMonitor(interrupt: false)
        }
        engine.outputHandler = nil
        lineDiscipline = nil
        connection.cancel()
        onClose?()
    }
}
