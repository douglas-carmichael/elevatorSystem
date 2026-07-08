import Foundation
import Combine

enum Lang: String, CaseIterable, Identifiable {
    case en
    case fr
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .en: return "English"
        case .fr: return "Français"
        }
    }
    var code: String { rawValue.uppercased() }
}

/// Which lift-safety standard's terminology the UI presents. The app
/// follows the UI language by default (French cohorts see the European
/// EN 81 wording; English sees ASME A17.1), overridable via `SET STANDARD`.
enum SafetyStandard: String, CaseIterable, Identifiable {
    case asme
    case en81
    var id: String { rawValue }
    var label: String {
        switch self {
        case .asme: return "ASME A17.1"
        case .en81: return "EN 81-20/50"
        }
    }
}

@MainActor
final class AppLanguage: ObservableObject {
    @Published var current: Lang
    /// Explicit operator override (SET STANDARD ASME|EN81). When nil the
    /// terminology follows `current`: FR → EN 81, EN → ASME.
    @Published var standardOverride: SafetyStandard?

    init(initial: Lang = AppLanguage.detect()) {
        self.current = initial
        self.standardOverride = nil
    }

    /// The safety standard currently in effect, honouring an explicit
    /// override and otherwise following the UI language.
    var standard: SafetyStandard {
        standardOverride ?? (current == .fr ? .en81 : .asme)
    }

    /// Looks up a safety term that differs by standard. `base` is a key
    /// stem; the resolved key is "<base>.<asme|en81>", localized to
    /// `current`.
    func safetyTerm(_ base: String) -> String {
        Strings.lookup("\(base).\(standard.rawValue)", lang: current)
    }

    nonisolated private static func detect() -> Lang {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("fr") ? .fr : .en
    }

    func t(_ key: String) -> String {
        Strings.lookup(key, lang: current)
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        let raw = Strings.lookup(key, lang: current)
        return String(format: raw, arguments: args)
    }

    func cycle() {
        let all = Lang.allCases
        guard let idx = all.firstIndex(of: current) else { return }
        current = all[(idx + 1) % all.count]
    }
}
