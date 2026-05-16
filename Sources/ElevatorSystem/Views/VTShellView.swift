import SwiftUI
import AppKit

/// SwiftUI host for the homebrew `RetroTerminalView`, wired up as a fake
/// "host program" that runs the DCL engine. Output from the engine flows
/// into the emulator via `feed(text:)`; keystrokes come back through the
/// emulator's `onInput` callback and pass through a minimal line
/// discipline before being handed to `DCLEngine.submit`.
struct VTShellView: NSViewRepresentable {
    @ObservedObject var dcl: DCLEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(dcl: dcl)
    }

    func makeNSView(context: Context) -> RetroTerminalView {
        let tv = RetroTerminalView(frame: .zero, font: Self.preferredFont())
        context.coordinator.terminalView = tv
        // Bridge keystrokes from the terminal into the line discipline.
        tv.onInput = { [weak coord = context.coordinator] bytes in
            coord?.processInput(bytes: bytes)
        }
        // Wire the engine's output handler the FIRST time the view has
        // real cols/rows -- not here, when frame is still .zero and
        // any banner content would get crushed into a 1x1 buffer that
        // then gets reshaped to its full size with most of the content
        // already lost. The engine's didSet on outputHandler replays
        // the full transcript at this point, so the freshly-sized view
        // gets the banner intact.
        let dcl = self.dcl
        tv.onReady = { [weak tv] in
            guard let tv else { return }
            dcl.outputHandler = { [weak tv] text in
                guard let tv else { return }
                tv.feed(text: Self.normalizeLineEndings(text))
            }
        }
        return tv
    }

    func updateNSView(_ nsView: RetroTerminalView, context: Context) {
        context.coordinator.terminalView = nsView
    }

    /// DCLEngine emits bare `\n` everywhere. The emulator treats LF as
    /// "down one row" (no column reset). Translate every lone LF into
    /// CRLF before feeding the emulator; leave existing CRLFs untouched.
    static func normalizeLineEndings(_ s: String) -> String {
        guard s.contains("\n") else { return s }
        var out = ""
        out.reserveCapacity(s.count + 8)
        var prev: Character = "\0"
        for ch in s {
            if ch == "\n" && prev != "\r" { out.append("\r") }
            out.append(ch)
            prev = ch
        }
        return out
    }

    /// Project's bundled retro font, falling back to the system
    /// monospaced face if VT323 isn't installed.
    private static func preferredFont() -> NSFont {
        if let custom = NSFont(name: "VT323", size: 16) { return custom }
        return NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    // MARK: -- Coordinator (line discipline)

    /// Maintains the current input line as a UTF-8 byte buffer with a
    /// cursor position, parses CSI escape sequences (arrow keys, Home /
    /// End), navigates the DCL engine's command history on Up / Down,
    /// and redraws the line via `\r prompt text ESC[K` after every
    /// state change so mid-line edits land in the right place.
    /// Ctrl-Y / Ctrl-C still aborts a running MONITOR or test utility.
    @MainActor
    final class Coordinator: NSObject {
        let dcl: DCLEngine
        weak var terminalView: RetroTerminalView?

        /// UTF-8 bytes for the current line. `cursor` is a byte offset
        /// that always sits on a character boundary -- continuation
        /// bytes (0x80...0xBF) are skipped together as one unit when
        /// the cursor moves.
        private var inputBytes: [UInt8] = []
        private var cursor: Int = 0

        /// Index into `dcl.history` while the user is browsing it with
        /// Up / Down. `nil` means the user is editing a fresh line.
        private var historyIndex: Int? = nil
        /// Working draft preserved when the user first presses Up, so
        /// Down past the newest entry restores what they had typed.
        private var savedDraft: [UInt8] = []

        /// CSI parser state. Real terminals send arrow keys as ESC [ A,
        /// ESC [ B, ESC [ C, ESC [ D (and Home / End as ESC [ H / F);
        /// the parser collects parameter bytes 0x30...0x3F and dispatches
        /// on the first byte in 0x40...0x7E.
        private enum EscState {
            case normal
            case sawESC
            case inCSI
        }
        private var escState: EscState = .normal

        init(dcl: DCLEngine) {
            self.dcl = dcl
        }

        func processInput(bytes: [UInt8]) {
            guard let source = terminalView else { return }
            // When the diagnostic menu is up, forward arrow keys + Enter
            // + Ctrl-Y straight to the engine instead of running them
            // through the line discipline.
            if case .diagnosticMenu = dcl.liveMode {
                dcl.handleDiagnosticMenuKey(bytes)
                return
            }
            // The screen-mode editor owns the whole input stream while
            // it's up: arrow keys, printable input, Enter, Backspace,
            // Page Up / Down, Ctrl-Z (save+exit), Ctrl-Y (discard).
            if case .screenEditor = dcl.liveMode {
                dcl.handleScreenEditorKey(bytes)
                return
            }
            var dirty = false
            for b in bytes {
                switch escState {
                case .sawESC:
                    if b == 0x5B {              // '['
                        escState = .inCSI
                    } else {
                        // Bare ESC or unsupported escape sequence -- drop.
                        escState = .normal
                    }
                    continue
                case .inCSI:
                    if (0x40...0x7E).contains(b) {
                        handleCSI(final: b)
                        escState = .normal
                        dirty = true
                    }
                    // 0x30...0x3F: parameter bytes -- accumulated implicitly
                    // by waiting for the final byte. We don't currently use
                    // them (the keys we handle have no parameters).
                    continue
                case .normal:
                    break
                }
                switch b {
                case 0x1B:                                  // ESC
                    escState = .sawESC
                case 0x0D, 0x0A:                            // CR / LF
                    submitLine(tv: source)
                    dirty = false                           // CRLF already emitted
                case 0x08, 0x7F:                            // BS / DEL
                    backspaceAtCursor()
                    dirty = true
                case 0x03, 0x19:                            // Ctrl-C / Ctrl-Y
                    if dcl.liveActive {
                        dcl.stopMonitor(interrupt: true)
                    } else {
                        cancelLine(tv: source)
                    }
                    dirty = false
                case 0x15:                                  // Ctrl-U: kill line
                    killLine()
                    dirty = true
                case 0x01:                                  // Ctrl-A: home
                    cursor = 0
                    dirty = true
                case 0x05:                                  // Ctrl-E: end
                    cursor = inputBytes.count
                    dirty = true
                case 0x09:                                  // TAB -> space
                    insertByte(0x20)
                    dirty = true
                default:
                    if b >= 0x20 {
                        insertByte(b)
                        dirty = true
                    }
                }
            }
            if dirty {
                redraw(tv: source)
            }
        }

        private func handleCSI(final: UInt8) {
            switch final {
            case 0x41:                              // A - Up
                recallPreviousHistory()
            case 0x42:                              // B - Down
                recallNextHistory()
            case 0x43:                              // C - Right
                advanceCursor()
            case 0x44:                              // D - Left
                retreatCursor()
            case 0x48:                              // H - Home
                cursor = 0
            case 0x46:                              // F - End
                cursor = inputBytes.count
            default:
                break
            }
        }

        // MARK: -- Line buffer manipulation

        private func insertByte(_ b: UInt8) {
            inputBytes.insert(b, at: cursor)
            cursor += 1
            // Typing leaves history-browse mode -- the next Up should
            // re-seed from the newest history entry, not relative to
            // the recalled line the user just modified.
            historyIndex = nil
        }

        private func backspaceAtCursor() {
            guard cursor > 0 else { return }
            // Walk back through any UTF-8 continuation bytes and remove
            // the entire multi-byte character in one keystroke.
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

        private func cancelLine(tv: RetroTerminalView) {
            inputBytes.removeAll()
            cursor = 0
            historyIndex = nil
            tv.feed(text: "\r\n")
            dcl.out("%DCL-S-INTRUPT, interrupted\n")
            dcl.out(dcl.prompt)
        }

        private func submitLine(tv: RetroTerminalView) {
            let line = String(decoding: inputBytes, as: UTF8.self)
            inputBytes.removeAll()
            cursor = 0
            historyIndex = nil
            tv.feed(text: "\r\n")
            dcl.submit(line)
        }

        // MARK: -- History navigation

        private func recallPreviousHistory() {
            guard !dcl.history.isEmpty else { return }
            if historyIndex == nil {
                savedDraft = inputBytes
                historyIndex = dcl.history.count - 1
            } else if let idx = historyIndex, idx > 0 {
                historyIndex = idx - 1
            } else {
                return                              // already at oldest
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
                // Past the newest entry -- restore the working draft.
                historyIndex = nil
                inputBytes = savedDraft
            }
            cursor = inputBytes.count
        }

        // MARK: -- Redraw

        /// Emit CR (return to column 1) + prompt + line + ESC[K
        /// (erase to end of line) + ESC[<n>D (move cursor back) so the
        /// terminal cursor lands at the logical cursor position. This is
        /// the "readline" trick that lets mid-line edits work cleanly.
        private func redraw(tv: RetroTerminalView) {
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
            tv.feed(text: s)
        }

        private func utf8GlyphCount(_ bytes: [UInt8]) -> Int {
            bytes.reduce(0) { acc, b in acc + ((b & 0xC0 == 0x80) ? 0 : 1) }
        }
    }
}
