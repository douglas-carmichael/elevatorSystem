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

    /// Thin shim that owns a `LineDiscipline` bound to the SwiftUI
    /// `RetroTerminalView`. All the actual cursor / history / redraw
    /// logic lives in `LineDiscipline` so the telnet server can reuse it.
    @MainActor
    final class Coordinator: NSObject {
        let dcl: DCLEngine
        weak var terminalView: RetroTerminalView? {
            didSet { rebuildLineDisciplineIfNeeded() }
        }

        private var lineDiscipline: LineDiscipline?

        init(dcl: DCLEngine) {
            self.dcl = dcl
        }

        func processInput(bytes: [UInt8]) {
            rebuildLineDisciplineIfNeeded()
            lineDiscipline?.process(bytes)
        }

        private func rebuildLineDisciplineIfNeeded() {
            guard lineDiscipline == nil, let tv = terminalView else { return }
            lineDiscipline = LineDiscipline(dcl: dcl) { [weak tv] text in
                tv?.feed(text: text)
            }
        }
    }
}
