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

@MainActor
final class AppLanguage: ObservableObject {
    @Published var current: Lang

    init(initial: Lang = AppLanguage.detect()) {
        self.current = initial
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
