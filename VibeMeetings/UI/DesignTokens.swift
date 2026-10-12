import AppKit
import SwiftUI

/// The app's visual vocabulary: one place for the surfaces, type and spacing
/// the main window is built from, so a list row, a card and a chip agree.
///
/// Colours follow the system appearance (a deep neutral in dark mode, near-white
/// in light) and the accent is the asset-catalog `AccentColor`; red is reserved
/// for recording.
enum Tokens {
    // MARK: Colour

    /// The main pane's background.
    static let surface = Color(light: NSColor(white: 0.99, alpha: 1), dark: NSColor(white: 0.115, alpha: 1))
    /// The sidebar — a step away from `surface` so the two panes read as separate.
    static let sidebar = Color(light: NSColor(white: 0.95, alpha: 1), dark: NSColor(white: 0.085, alpha: 1))
    /// Cards, chips and the floating bar sit on this.
    static let raised = Color(light: NSColor(white: 1, alpha: 1), dark: NSColor(white: 0.155, alpha: 1))
    /// Row hover.
    static let hover = Color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07))
    /// Hairlines around raised things.
    static let stroke = Color(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.10))
    /// Recording and Stop — never the accent.
    static let record = Color.red
    /// The app's accent. Applied as the window's tint, so buttons, selection and
    /// `Color.accentColor` are violet whatever the system accent is.
    static let accent = Color(light: NSColor(srgbRed: 0.42, green: 0.29, blue: 0.96, alpha: 1),
                              dark: NSColor(srgbRed: 0.58, green: 0.48, blue: 1.0, alpha: 1))

    // MARK: Type

    /// Page titles ("Meetings", a meeting's name) are serif, which is most of the Granola/Ottex look.
    static let pageTitle = Font.system(.largeTitle, design: .serif).weight(.semibold)
    /// A meeting's own title, one step down from a page title.
    static let detailTitle = Font.system(.title, design: .serif).weight(.semibold)
    static let sectionTitle = Font.system(.subheadline).weight(.semibold)
    static let rowTitle = Font.system(.body).weight(.medium)
    static let secondary = Font.system(.callout)

    // MARK: Metrics

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let chip: CGFloat = 6
        static let row: CGFloat = 8
        static let card: CGFloat = 12
    }

    /// Text lines longer than this are hard to read; pages centre their content at it.
    static let readingWidth: CGFloat = 760
}

private extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    /// Centre this at `Tokens.readingWidth`. Apply it to a ScrollView's *content*,
    /// not the scroll view, so the scroll bar stays at the window's edge.
    func readableWidth() -> some View {
        frame(maxWidth: Tokens.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

/// Light, dark, or follow the system. Dark by default — that's the look the app
/// is designed around — and changeable in Settings → General.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// `nil` means "don't override": follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
