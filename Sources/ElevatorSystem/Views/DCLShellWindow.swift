import SwiftUI
import AppKit

struct DCLShellWindow: View {
    @EnvironmentObject var dcl: DCLEngine
    @EnvironmentObject var language: AppLanguage
    @State private var input: String = ""
    @State private var hostWindow: NSWindow?
    @FocusState private var promptFocused: Bool

    var body: some View {
        ZStack {
            RetroTheme.bg.ignoresSafeArea()

            // Always-on Ctrl-Y / Ctrl-C interrupt monitor for continuous MONITOR.
            KeyboardHost(onKey: handleKey)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)

            if let live = dcl.liveDisplay {
                liveMonitorView(live)
            } else {
                shellView
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .background(WindowAccessor { hostWindow = $0 })
        .onAppear { promptFocused = true }
        .onChange(of: dcl.loggedOut) { loggedOut in
            // LOGOUT / EXIT closes the DCL window. We delay briefly so the
            // user sees the "logged out at ..." message before the window
            // disappears, then reset the flag so a future LOGOUT will fire.
            guard loggedOut else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                hostWindow?.close()
                dcl.loggedOut = false
            }
        }
        .onChange(of: dcl.liveDisplay) { newValue in
            // When MONITOR releases, give focus back to the prompt field.
            if newValue == nil { promptFocused = true }
        }
    }

    // MARK: -- Shell (transcript + inline prompt)

    private var shellView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(dcl.transcript)
                        .font(RetroTheme.mono)
                        .foregroundColor(RetroTheme.amber)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Inline prompt: lives at the END of the transcript so
                    // it scrolls together with the rest of the output.
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(dcl.prompt)
                            .font(RetroTheme.mono)
                            .foregroundColor(RetroTheme.amberBright)
                            .retroGlow()
                        TextField("", text: $input)
                            .textFieldStyle(.plain)
                            .font(RetroTheme.mono)
                            .foregroundColor(RetroTheme.amberBright)
                            .focused($promptFocused)
                            .onSubmit { submit() }
                    }
                    .padding(.top, 2)
                    .id("promptLine")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .contentShape(Rectangle())
            .onTapGesture { promptFocused = true }
            .onChange(of: dcl.transcript) { _ in
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo("promptLine", anchor: .bottom)
                }
            }
            .onChange(of: input) { _ in
                proxy.scrollTo("promptLine", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("promptLine", anchor: .bottom)
            }
        }
    }

    // MARK: -- Live MONITOR overlay

    private func liveMonitorView(_ text: String) -> some View {
        ScrollView(.vertical) {
            FixedAdvanceText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(Color.black)
    }

    // MARK: -- Keyboard

    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.control) else { return ev }
        let key = (ev.charactersIgnoringModifiers ?? "").lowercased()
        // Ctrl-Y is the standard interrupt; honor Ctrl-C as well since real
        // OpenVMS MONITOR also accepts it inside the utility.
        if key == "y" || key == "c" {
            if dcl.liveDisplay != nil {
                dcl.stopMonitor(interrupt: true)
                return nil
            }
        }
        return ev
    }

    private func submit() {
        let raw = input
        input = ""
        dcl.submit(raw)
        promptFocused = true
    }
}

/// Draws terminal text on a fixed character-cell grid so that every glyph
/// — including space and accented characters — occupies exactly the same
/// horizontal space, just like a real hardware terminal.
private struct FixedAdvanceText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TerminalGridView {
        TerminalGridView()
    }

    func updateNSView(_ view: TerminalGridView, context: Context) {
        view.update(newText: text)
    }
}

private final class TerminalGridView: NSView {
    private var text: String = ""
    private let termFont: NSFont
    private let textColor: NSColor
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat

    init() {
        let font = NSFont(name: RetroTheme.retroFontName, size: 16)
            ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        self.termFont = font
        self.textColor = NSColor(RetroTheme.amber)
        self.cellWidth = font.maximumAdvancement.width
        self.cellHeight = ceil(font.ascender - font.descender + font.leading)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let maxCols = lines.map(\.count).max() ?? 0
        return NSSize(
            width: CGFloat(maxCols) * cellWidth,
            height: CGFloat(lines.count) * cellHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: termFont,
            .foregroundColor: textColor
        ]
        for (row, line) in lines.enumerated() {
            let y = CGFloat(row) * cellHeight
            for (col, char) in line.enumerated() {
                let x = CGFloat(col) * cellWidth
                String(char).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            }
        }
    }

    func update(newText: String) {
        guard text != newText else { return }
        text = newText
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

/// Captures the NSWindow hosting this SwiftUI view so we can close it
/// programmatically (LOGOUT / EXIT in the DCL shell). This works on
/// macOS 13+, unlike the SwiftUI dismissWindow environment value.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in onResolve(v?.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onResolve(nsView?.window) }
    }
}
