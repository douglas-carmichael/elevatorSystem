import SwiftUI
import AppKit

/// Window that hosts the SwiftTerm-backed VT220/320 emulator. The emulator
/// is wired to a DCLEngine via VTShellView -- output goes through
/// `dcl.outputHandler`, keystrokes route back through the line-discipline
/// coordinator and into `dcl.submit(_:)`.
struct DCLShellWindow: View {
    @EnvironmentObject var dcl: DCLEngine
    @EnvironmentObject var language: AppLanguage
    @State private var hostWindow: NSWindow?

    var body: some View {
        // The full-screen diagnostic display (DCLDiagnostics.refreshTestDisplay)
        // homes the cursor and paints an 18-line, 78-column box; the
        // login banner + LPD splash + prompt also runs ~22 lines. Size the
        // window so SwiftTerm computes at least 24 rows / 80 cols at the
        // VT323 16pt body font, otherwise the top scrolls off the screen.
        VTShellView(dcl: dcl)
            .frame(minWidth: 820, minHeight: 600)
            .background(Color.black)
            // No `.ignoresSafeArea()`: with it, the view extends under
            // the macOS title bar and anything at row 0 (the Welcome
            // banner line, the `$ ` prompt after CLEAR) gets hidden
            // behind the chrome.
            .background(WindowAccessor { hostWindow = $0 })
            .onChange(of: dcl.loggedOut) { loggedOut in
                // LOGOUT / EXIT closes the DCL window. We delay briefly so
                // the operator sees the "logged out" line before the
                // window disappears, then reset the flag so a future
                // LOGOUT will fire.
                guard loggedOut else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    hostWindow?.close()
                    dcl.loggedOut = false
                }
            }
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
