import Foundation

/// Reusable readline-style line discipline that drives a `DCLEngine`.
/// The local SwiftUI terminal view (`VTShellView`) and each telnet
/// session (`DCLTelnetServer`) both wrap their byte stream in one of
/// these so cursor keys, mid-line editing, and Up / Down history work
/// identically across local and remote connections.
///
/// `write` is the closure that emits raw bytes (as a String of ASCII
/// glyphs and / or VT escape sequences) to wherever the user is sitting
/// -- the local emulator's `feed(text:)` call, or a TCP socket's send.
/// Bytes pushed through `write` do NOT pass through `DCLEngine.out`, so
/// they never land in the transcript -- they're purely terminal control
/// (CR, prompt redraw, line-erase). The engine's regular output (banner,
/// SHOW responses, prompt after submit) still flows through the engine's
/// `outputHandler`, which the caller wires separately.
@MainActor
final class LineDiscipline {
    private let dcl: DCLEngine
    private let write: (String) -> Void

    /// UTF-8 bytes for the current input line. `cursor` is a byte offset
    /// that always sits on a character boundary -- continuation bytes
    /// (0x80...0xBF) move with their leading byte as one unit.
    private var inputBytes: [UInt8] = []
    private var cursor: Int = 0

    /// Index into `dcl.history` while the user is browsing it with the
    /// Up / Down arrows. `nil` means they're editing a fresh line.
    private var historyIndex: Int? = nil
    /// Working draft preserved when the user presses Up the first time,
    /// so Down past the newest entry restores what they had typed.
    private var savedDraft: [UInt8] = []

    private enum EscState {
        case normal
        case sawESC
        case inCSI
    }
    private var escState: EscState = .normal

    init(dcl: DCLEngine, write: @escaping (String) -> Void) {
        self.dcl = dcl
        self.write = write
    }

    // MARK: -- Entry point

    func process(_ bytes: [UInt8]) {
        // Live full-screen modes own the byte stream completely.
        if case .diagnosticMenu = dcl.liveMode {
            dcl.handleDiagnosticMenuKey(bytes)
            return
        }
        if case .screenEditor = dcl.liveMode {
            dcl.handleScreenEditorKey(bytes)
            return
        }
        var dirty = false
        for b in bytes {
            switch escState {
            case .sawESC:
                if b == 0x5B {
                    escState = .inCSI
                } else if b == 0x1B {
                    // ESC ESC: an alternative interrupt gesture for
                    // users whose tty driver eats ^Y / ^C / ^Z (DSUSP /
                    // INTR / SUSP -- a common problem when connecting
                    // via `nc localhost 2323` from a macOS terminal,
                    // where the local tty layer intercepts those bytes
                    // before nc forwards them to us).
                    escState = .normal
                    if dcl.liveActive {
                        dcl.stopMonitor(interrupt: true)
                    } else if dcl.mailComposingBody {
                        // ESC ESC finishes a MAIL message body for telnet
                        // users whose tty eats CTRL/Z (the same fallback the
                        // screen editor offers).
                        endMailBody()
                    }
                } else {
                    escState = .normal
                }
                continue
            case .inCSI:
                if (0x40...0x7E).contains(b) {
                    handleCSI(final: b)
                    escState = .normal
                    dirty = true
                }
                continue
            case .normal:
                break
            }
            switch b {
            case 0x1B:
                escState = .sawESC
            case 0x0D, 0x0A:
                submitLine()
                dirty = false
            case 0x08, 0x7F:
                backspaceAtCursor()
                dirty = true
            case 0x03, 0x19:
                if dcl.liveActive {
                    dcl.stopMonitor(interrupt: true)
                } else if dcl.mailComposing {
                    inputBytes.removeAll()
                    cursor = 0
                    historyIndex = nil
                    dcl.abortMailMessage()
                } else {
                    cancelLine()
                }
                dirty = false
            case 0x1A:
                // CTRL/Z ends a MAIL message body; harmless elsewhere.
                if dcl.mailComposingBody {
                    endMailBody()
                }
                dirty = false
            case 0x15:
                killLine()
                dirty = true
            case 0x01:
                cursor = 0
                dirty = true
            case 0x05:
                cursor = inputBytes.count
                dirty = true
            case 0x09:
                insertByte(0x20)
                dirty = true
            default:
                if b >= 0x20 {
                    insertByte(b)
                    dirty = true
                }
            }
        }
        if dirty { redraw() }
    }

    // MARK: -- Buffer manipulation

    private func insertByte(_ b: UInt8) {
        inputBytes.insert(b, at: cursor)
        cursor += 1
        historyIndex = nil
    }

    private func backspaceAtCursor() {
        guard cursor > 0 else { return }
        repeat {
            cursor -= 1
            let removed = inputBytes.remove(at: cursor)
            if removed & 0xC0 != 0x80 { break }
        } while cursor > 0
        historyIndex = nil
    }

    private func advanceCursor() {
        guard cursor < inputBytes.count else { return }
        cursor += 1
        while cursor < inputBytes.count, inputBytes[cursor] & 0xC0 == 0x80 {
            cursor += 1
        }
    }

    private func retreatCursor() {
        guard cursor > 0 else { return }
        cursor -= 1
        while cursor > 0, inputBytes[cursor] & 0xC0 == 0x80 {
            cursor -= 1
        }
    }

    private func killLine() {
        inputBytes.removeAll()
        cursor = 0
        historyIndex = nil
    }

    private func cancelLine() {
        inputBytes.removeAll()
        cursor = 0
        historyIndex = nil
        write("\r\n")
        dcl.out("%DCL-S-INTRUPT, interrupted\n")
        dcl.out(dcl.prompt)
    }

    /// Finish a MAIL message body: the current partial input line (typed
    /// but not yet Return-ed) becomes the last body line, then the engine
    /// sends the message.
    private func endMailBody() {
        let line = String(decoding: inputBytes, as: UTF8.self)
        inputBytes.removeAll()
        cursor = 0
        historyIndex = nil
        write("\r\n")
        dcl.endMailMessage(partial: line)
    }

    private func submitLine() {
        let line = String(decoding: inputBytes, as: UTF8.self)
        inputBytes.removeAll()
        cursor = 0
        historyIndex = nil
        write("\r\n")
        // dcl.submit is async because WAIT actually pauses via Task.sleep;
        // detach so the line-discipline keystroke handler returns
        // immediately and we don't block keyboard input while a script
        // is sleeping.
        Task { @MainActor in
            await dcl.submit(line)
        }
    }

    // MARK: -- History

    private func recallPreviousHistory() {
        guard !dcl.history.isEmpty else { return }
        if historyIndex == nil {
            savedDraft = inputBytes
            historyIndex = dcl.history.count - 1
        } else if let idx = historyIndex, idx > 0 {
            historyIndex = idx - 1
        } else {
            return
        }
        if let idx = historyIndex {
            inputBytes = Array(dcl.history[idx].utf8)
            cursor = inputBytes.count
        }
    }

    private func recallNextHistory() {
        guard let idx = historyIndex else { return }
        let next = idx + 1
        if next < dcl.history.count {
            historyIndex = next
            inputBytes = Array(dcl.history[next].utf8)
        } else {
            historyIndex = nil
            inputBytes = savedDraft
        }
        cursor = inputBytes.count
    }

    // MARK: -- CSI dispatch

    private func handleCSI(final: UInt8) {
        switch final {
        case 0x41: recallPreviousHistory()      // A - Up
        case 0x42: recallNextHistory()          // B - Down
        case 0x43: advanceCursor()              // C - Right
        case 0x44: retreatCursor()              // D - Left
        case 0x48: cursor = 0                   // H - Home
        case 0x46: cursor = inputBytes.count    // F - End
        default: break
        }
    }

    // MARK: -- Redraw

    private func redraw() {
        var s = "\r"
        s += dcl.prompt
        s += String(decoding: inputBytes, as: UTF8.self)
        s += "\u{1B}[K"
        let total  = utf8GlyphCount(inputBytes)
        let before = utf8GlyphCount(Array(inputBytes.prefix(cursor)))
        let trailing = total - before
        if trailing > 0 {
            s += "\u{1B}[\(trailing)D"
        }
        write(s)
    }

    private func utf8GlyphCount(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { acc, b in acc + ((b & 0xC0 == 0x80) ? 0 : 1) }
    }
}
