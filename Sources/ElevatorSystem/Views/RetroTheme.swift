import SwiftUI

enum RetroTheme {
    static let bg            = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let bgPanel       = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let amber         = Color(red: 1.00, green: 0.72, blue: 0.20)
    static let amberDim      = Color(red: 0.62, green: 0.45, blue: 0.12)
    static let amberBright   = Color(red: 1.00, green: 0.86, blue: 0.45)
    static let green         = Color(red: 0.36, green: 1.00, blue: 0.42)
    static let greenDim      = Color(red: 0.20, green: 0.55, blue: 0.22)
    static let red           = Color(red: 1.00, green: 0.30, blue: 0.28)
    static let cyan          = Color(red: 0.45, green: 0.95, blue: 1.00)

    static let retroFontName = "VT323"

    static let mono   = Font.custom(retroFontName, size: 16, relativeTo: .body)
    static let monoSm = Font.custom(retroFontName, size: 13, relativeTo: .footnote)
    static let monoLg = Font.custom(retroFontName, size: 22, relativeTo: .title3)
    static let monoXl = Font.custom(retroFontName, size: 30, relativeTo: .title)

    static let glow = Color(red: 1.00, green: 0.72, blue: 0.20).opacity(0.45)
}

extension View {
    func retroGlow() -> some View {
        self.shadow(color: RetroTheme.glow, radius: 2.5, x: 0, y: 0)
    }
}
