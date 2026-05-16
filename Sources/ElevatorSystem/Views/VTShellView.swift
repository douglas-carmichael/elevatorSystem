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

    /// Buffers each typed line until Enter, then submits it to the engine.
    /// Ctrl-Y / Ctrl-C aborts a running MONITOR or test utility.
    @MainActor
    final class Coordinator: NSObject {
        let dcl: DCLEngine
        weak var terminalView: RetroTerminalView?

        /// Bytes buffer the current line until the user hits Enter.
        private var inputBytes: [UInt8] = []
        /// Tracks ESC ... sequences (arrow keys, function keys) so we
        /// can swallow them rather than echoing them as glyphs.
        private var escapePending: Int = 0

        init(dcl: DCLEngine) {
            self.dcl = dcl
        }

        func processInput(bytes: [UInt8]) {
            guard let source = terminalView else { return }
            // When the diagnostic menu is up, forward arrow keys + Enter
            // + Ctrl-Y straight to the engine instead of running them
            // through the line discipline. The menu intercepts navigation
            // and selection; everything else is dropped.
            if case .diagnosticMenu = dcl.liveMode {
                dcl.handleDiagnosticMenuKey(bytes)
                return
            }
            for b in bytes {
                if escapePending > 0 {
                    escapePending -= 1
                    if (0x40...0x7E).contains(b) || escapePending == 0 {
                        escapePending = 0
                    }
                    continue
                }
                switch b {
                case 0x1B:                                    // ESC
                    escapePending = 8
                case 0x0D, 0x0A:                              // CR / LF
                    let line = String(decoding: inputBytes, as: UTF8.self)
                    inputBytes.removeAll()
                    source.feed(text: "\r\n")
                    dcl.submit(line)
                case 0x08, 0x7F:                              // BS / DEL
                    if !inputBytes.isEmpty {
                        while let last = inputBytes.last, last & 0xC0 == 0x80 {
                            inputBytes.removeLast()
                        }
                        if !inputBytes.isEmpty { inputBytes.removeLast() }
                        source.feed(text: "\u{08} \u{08}")
                    }
                case 0x03, 0x19:                              // Ctrl-C / Ctrl-Y
                    if dcl.liveActive {
                        dcl.stopMonitor(interrupt: true)
                    } else {
                        inputBytes.removeAll()
                        source.feed(text: "\r\n")
                        dcl.out("%DCL-S-INTRUPT, interrupted\n")
                        dcl.out(dcl.prompt)
                    }
                case 0x15:                                    // Ctrl-U: kill line
                    let glyphs = utf8GlyphCount(inputBytes)
                    inputBytes.removeAll()
                    if glyphs > 0 {
                        source.feed(text: String(repeating: "\u{08} \u{08}", count: glyphs))
                    }
                case 0x09:                                    // TAB -> space
                    inputBytes.append(0x20)
                    source.feed(text: " ")
                default:
                    if b >= 0x20 {
                        inputBytes.append(b)
                        source.feed(byteArray: [b])
                    }
                }
            }
        }

        private func utf8GlyphCount(_ bytes: [UInt8]) -> Int {
            return bytes.reduce(0) { acc, b in
                acc + ((b & 0xC0 == 0x80) ? 0 : 1)
            }
        }
    }
}
