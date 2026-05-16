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
                        .font(RetroTheme.mono)
                        .foregroundColor(RetroTheme.greenDim)
                } else {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                Spacer().frame(height: 8)
                profileFooter
                Spacer()
                statusBar
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 420)
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
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(language.t("dynamics.title"))
                .font(RetroTheme.monoLg)
                .foregroundColor(RetroTheme.amber)
                .retroGlow()
            Text(language.t("dynamics.subtitle"))
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
        }
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
            .font(RetroTheme.mono)
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
            .font(RetroTheme.mono)
            .foregroundColor(color)
            .frame(width: width, alignment: .leading)
    }

    private var profileFooter: some View {
        Text(String(format: "%@  PAX  %.2f fl/s  / %.2f fl/s²    FRT  %.2f fl/s  / %.2f fl/s²",
                    language.t("dynamics.profile.limits"),
                    Sim.paxSpeed, Sim.paxAccel,
                    Sim.freightSpeed, Sim.freightAccel))
            .font(RetroTheme.monoSm)
            .foregroundColor(RetroTheme.amberDim)
    }

    private var statusBar: some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return HStack {
            Text(language.t("dynamics.refresh"))
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            Spacer()
            Text(fmt.string(from: lastUpdate))
                .font(RetroTheme.monoSm)
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
