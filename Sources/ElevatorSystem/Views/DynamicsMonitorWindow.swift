import SwiftUI

/// Standalone VT320-style window that mirrors `MONITOR DYNAMICS` from the
/// DCL shell so a viewer can watch the trapezoidal velocity profile
/// without dropping into the terminal. Samples every 500 ms; tracks the
/// prior-tick velocity per cab so the displayed acceleration follows the
/// motor command between refreshes.
struct DynamicsMonitorWindow: View {
    @EnvironmentObject var world: ElevatorWorld
    @EnvironmentObject var language: AppLanguage

    @State private var rows: [Row] = []
    @State private var lastVelocity: [UUID: Double] = [:]
    @State private var lastSample: Date = Date()
    @State private var lastUpdate: Date = Date()
    @State private var velocityHistory: [UUID: [Double]] = [:]

    // 60-second rolling window at 500 ms sample rate -> 120 slots; the
    // trace anchors the newest sample to the right edge so it reads
    // like a commissioning-tool scope rather than a left-to-right
    // history that wanders off the screen as the buffer fills.
    private static let traceCapacity: Int = 120

    // Window-local fonts: the global RetroTheme.mono/monoSm are tuned
    // for dense panels (control panel, alarm table); this window is
    // viewed from further back during a demo, so the table and labels
    // get bumped up a tier without affecting the rest of the app.
    private static let bodyFont = Font.custom(RetroTheme.retroFontName,
                                              size: 19, relativeTo: .body)
    private static let smallFont = Font.custom(RetroTheme.retroFontName,
                                               size: 16, relativeTo: .footnote)
    private static let titleFont = Font.custom(RetroTheme.retroFontName,
                                               size: 26, relativeTo: .title3)

    var body: some View {
        ZStack {
            RetroTheme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                header
                tableHeader
                Rectangle()
                    .fill(RetroTheme.amberDim)
                    .frame(height: 1)
                if rows.isEmpty {
                    Text(language.t("dynamics.empty"))
                        .font(Self.bodyFont)
                        .foregroundColor(RetroTheme.greenDim)
                } else {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                Spacer().frame(height: 8)
                velocityTrace
                Spacer().frame(height: 8)
                profileFooter
                stateGloss
                Spacer()
                statusBar
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 700)
        .environment(\.colorScheme, .dark)
        .onAppear { sample() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                sample()
            }
        }
    }

    // MARK: - Sampling

    private struct Row: Identifiable {
        let id: UUID
        let label: String
        let position: Double
        let velocity: Double
        let accel: Double
        let target: Int?
        let state: String
        let isFreight: Bool
    }

    private func sample() {
        let now = Date()
        let dt = max(0.001, now.timeIntervalSince(lastSample))
        let cabs = world.sortedElevators
        let computed: [Row] = cabs.map { cab in
            let prev = lastVelocity[cab.id] ?? cab.velocity
            return Row(id: cab.id,
                       label: world.displayLabel(for: cab),
                       position: cab.position,
                       velocity: cab.velocity,
                       accel: (cab.velocity - prev) / dt,
                       target: cab.queue.first,
                       state: Self.state(for: cab),
                       isFreight: cab.profile == .freight)
        }
        rows = computed
        lastVelocity = Dictionary(uniqueKeysWithValues:
                                    cabs.map { ($0.id, $0.velocity) })
        lastSample = now
        lastUpdate = now

        for cab in cabs {
            var buf = velocityHistory[cab.id, default: []]
            buf.append(cab.velocity)
            if buf.count > Self.traceCapacity {
                buf.removeFirst(buf.count - Self.traceCapacity)
            }
            velocityHistory[cab.id] = buf
        }
        let currentIds = Set(cabs.map(\.id))
        velocityHistory = velocityHistory.filter { currentIds.contains($0.key) }
    }

    // MARK: - Subviews

    private var header: some View {
        Text(language.t("dynamics.title"))
            .font(Self.titleFont)
            .foregroundColor(RetroTheme.amber)
            .retroGlow()
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            headerCell(language.t("dynamics.col.cab"),  width: 70)
            headerCell(language.t("dynamics.col.pos"),  width: 130)
            headerCell(language.t("dynamics.col.vel"),  width: 160)
            headerCell(language.t("dynamics.col.acc"),  width: 130)
            headerCell(language.t("dynamics.col.tgt"),  width: 90)
            headerCell(language.t("dynamics.col.state"), width: nil)
        }
    }

    private func headerCell(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .font(Self.bodyFont)
            .foregroundColor(RetroTheme.amberDim)
            .frame(width: width, alignment: .leading)
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 0) {
            cell(row.label, width: 70,
                 color: row.isFreight ? RetroTheme.cyan : RetroTheme.green)
            cell(String(format: "%6.2f fl", row.position), width: 130,
                 color: RetroTheme.amberBright)
            cell(String(format: "%+6.3f fl/s", row.velocity), width: 160,
                 color: velocityColor(row.velocity))
            cell(String(format: "%+6.3f", row.accel), width: 130,
                 color: accelColor(row.accel))
            cell(row.target.map { String(format: "%6d", $0) } ?? "    --",
                 width: 90, color: RetroTheme.amber)
            cell(row.state, width: nil, color: stateColor(row.state))
        }
    }

    private func cell(_ text: String, width: CGFloat?, color: Color) -> some View {
        Text(text)
            .font(Self.bodyFont)
            .foregroundColor(color)
            .frame(width: width, alignment: .leading)
    }

    private var velocityTrace: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Text(language.t("dynamics.trace.title"))
                    .font(Self.smallFont)
                    .foregroundColor(RetroTheme.amberDim)
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(traceColor(for: idx))
                            .frame(width: 8, height: 8)
                        Text(row.label)
                            .font(Self.smallFont)
                            .foregroundColor(RetroTheme.amberDim)
                    }
                }
                Spacer()
                Text(language.t("dynamics.trace.axis"))
                    .font(Self.smallFont)
                    .foregroundColor(RetroTheme.amberDim)
            }
            Canvas { context, size in
                drawTrace(context: context, size: size)
            }
            .frame(height: 140)
            .background(RetroTheme.bg)
            .overlay(
                Rectangle()
                    .stroke(RetroTheme.amberDim, lineWidth: 1)
            )
            if velocityHistory.values.allSatisfy({ $0.count < 2 }) {
                Text(language.t("dynamics.trace.empty"))
                    .font(Self.smallFont)
                    .foregroundColor(RetroTheme.greenDim)
            }
        }
    }

    private static let tracePalette: [Color] = [
        RetroTheme.green,
        RetroTheme.cyan,
        RetroTheme.amberBright,
        .red,
        RetroTheme.greenDim,
    ]

    private func traceColor(for index: Int) -> Color {
        Self.tracePalette[index % Self.tracePalette.count]
    }

    // Scope-style velocity-vs-time plot. Y-axis is symmetric around
    // zero with the trapezoidal-profile speed ceiling marked as a
    // dashed limit line; X-axis is `traceCapacity` slots, newest sample
    // anchored to the right edge.
    private func drawTrace(context: GraphicsContext, size: CGSize) {
        let maxSpeed = max(Sim.paxSpeed, Sim.freightSpeed) * 1.15
        let midY = size.height / 2
        let yScale = midY / CGFloat(maxSpeed)

        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: midY))
        zero.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(zero,
                       with: .color(RetroTheme.amberDim),
                       lineWidth: 0.5)

        for limit in [Sim.paxSpeed, Sim.freightSpeed] {
            let dy = CGFloat(limit) * yScale
            for y in [midY - dy, midY + dy] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(p,
                               with: .color(RetroTheme.amberDim.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
            }
        }

        let totalSlots = max(1, Self.traceCapacity - 1)
        let xStep = size.width / CGFloat(totalSlots)

        for (idx, row) in rows.enumerated() {
            guard let history = velocityHistory[row.id], history.count > 1 else { continue }
            let startSlot = Self.traceCapacity - history.count
            var path = Path()
            for (i, v) in history.enumerated() {
                let x = CGFloat(startSlot + i) * xStep
                let y = midY - CGFloat(v) * yScale
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path,
                           with: .color(traceColor(for: idx)),
                           lineWidth: 1.2)
        }
    }

    // FR-only bridge from the firmware-side English state mnemonics
    // (which match what real KONE/Otis/Schindler service terminals
    // print) to the French operational vocabulary a GEII student writes
    // in their maintenance logs. Rendered only when the UI language is
    // French; in English the column needs no gloss.
    @ViewBuilder private var stateGloss: some View {
        if language.current == .fr {
            Text(language.t("dynamics.state.gloss"))
                .font(Self.smallFont)
                .foregroundColor(RetroTheme.amberDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var profileFooter: some View {
        Text(String(format: "%@  PAX  %.2f fl/s  / %.2f fl/s²    FRT  %.2f fl/s  / %.2f fl/s²",
                    language.t("dynamics.profile.limits"),
                    Sim.paxSpeed, Sim.paxAccel,
                    Sim.freightSpeed, Sim.freightAccel))
            .font(Self.smallFont)
            .foregroundColor(RetroTheme.amberDim)
    }

    private var statusBar: some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return HStack {
            Text(language.t("dynamics.refresh"))
                .font(Self.smallFont)
                .foregroundColor(RetroTheme.amberDim)
            Spacer()
            Text(fmt.string(from: lastUpdate))
                .font(Self.smallFont)
                .foregroundColor(RetroTheme.green)
        }
    }

    // MARK: - Coloring

    private func velocityColor(_ v: Double) -> Color {
        if abs(v) < 0.05 { return RetroTheme.amberDim }
        return v > 0 ? RetroTheme.green : RetroTheme.cyan
    }

    private func accelColor(_ a: Double) -> Color {
        if abs(a) < 0.05 { return RetroTheme.amberDim }
        return a > 0 ? RetroTheme.amberBright : RetroTheme.amber
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "ACCEL":              return RetroTheme.amberBright
        case "CRUISE":             return RetroTheme.green
        case "DECEL":              return RetroTheme.amber
        case "STOPPING", "PARKED": return RetroTheme.amberDim
        case "DOORS":              return RetroTheme.cyan
        case "PHASE-II", "INDEP":  return RetroTheme.red
        case "BRAKE", "OBSTR":     return RetroTheme.red
        case "IDLE":               return RetroTheme.greenDim
        default:                   return RetroTheme.amber
        }
    }

    // Mirror of DCLEngine.dynamicsState(for:) so the panel reads identical
    // to MONITOR DYNAMICS in the shell.
    private static func state(for cab: Elevator) -> String {
        if cab.doorObstructed { return "OBSTR" }
        if cab.doors == .opening || cab.doors == .closing { return "DOORS" }
        if cab.doors == .open { return "PARKED" }
        if cab.phaseTwoActive { return "PHASE-II" }
        if cab.independentActive { return "INDEP" }
        if cab.brakeEngaged && cab.queue.first != nil { return "BRAKE" }
        guard let target = cab.queue.first else {
            return abs(cab.velocity) > 0.05 ? "STOPPING" : "IDLE"
        }
        let dy = Double(target) - cab.position
        let stoppingDistance = (cab.velocity * cab.velocity) /
            (2 * cab.profile.travelAccel)
        let cruise = abs(cab.velocity) >=
            cab.profile.travelFloorsPerSecond * 0.95
        if abs(dy) <= stoppingDistance + 0.05 { return "DECEL" }
        if cruise { return "CRUISE" }
        return "ACCEL"
    }
}
