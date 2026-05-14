import SwiftUI
import AppKit

struct KeyboardHost: NSViewRepresentable {
    let onKey: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> KeyboardHostView {
        let v = KeyboardHostView()
        v.onKey = onKey
        return v
    }

    func updateNSView(_ nsView: KeyboardHostView, context: Context) {
        nsView.onKey = onKey
    }
}

final class KeyboardHostView: NSView {
    var onKey: ((NSEvent) -> NSEvent?)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            install()
        } else {
            uninstall()
        }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            guard ev.window === self.window else { return ev }
            return self.onKey?(ev) ?? ev
        }
    }

    private func uninstall() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit {
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
    }
}

enum KeyCode {
    static let f1: UInt16 = 122
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    static let questionMark: UInt16 = 44
}
