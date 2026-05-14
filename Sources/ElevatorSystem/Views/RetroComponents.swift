import SwiftUI

struct BoxPanel<Content: View>: View {
    let title: String?
    let accent: Color
    @ViewBuilder let content: () -> Content

    init(title: String? = nil,
         accent: Color = RetroTheme.amber,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content
    }

    var body: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RetroTheme.bgPanel)
            .overlay(
                Rectangle()
                    .stroke(accent.opacity(0.85), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if let title {
                    Text("─ \(title) ")
                        .font(RetroTheme.monoSm)
                        .foregroundColor(accent)
                        .padding(.horizontal, 4)
                        .background(RetroTheme.bg)
                        .offset(x: 12, y: -8)
                        .retroGlow()
                }
            }
    }
}

struct RetroButton: View {
    let label: String
    let enabled: Bool
    let highlighted: Bool
    let action: () -> Void

    init(_ label: String,
         enabled: Bool = true,
         highlighted: Bool = false,
         action: @escaping () -> Void) {
        self.label = label
        self.enabled = enabled
        self.highlighted = highlighted
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(RetroTheme.mono)
                .foregroundColor(enabled
                    ? (highlighted ? RetroTheme.bg : RetroTheme.amber)
                    : RetroTheme.amberDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(highlighted ? RetroTheme.amber : Color.clear)
                .overlay(
                    Rectangle().stroke(enabled ? RetroTheme.amber : RetroTheme.amberDim, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct StatusLine: View {
    let label: String
    let value: String
    let valueColor: Color

    init(label: String, value: String, valueColor: Color = RetroTheme.amberBright) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .foregroundColor(RetroTheme.amberDim)
            Text(value)
                .foregroundColor(valueColor)
                .retroGlow()
        }
        .font(RetroTheme.mono)
    }
}

struct BlinkingCursor: View {
    @State private var on = true
    var body: some View {
        Text("▌")
            .font(RetroTheme.mono)
            .foregroundColor(RetroTheme.amber)
            .opacity(on ? 1.0 : 0.0)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { _ in
                    on.toggle()
                }
            }
    }
}

struct HRule: View {
    let color: Color
    init(_ color: Color = RetroTheme.amberDim) { self.color = color }
    var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}
