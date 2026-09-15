import SwiftUI
import UIKit

/// Design tokens. Dark-first: cars are mostly dark cabins, and the phone app
/// follows so the two surfaces feel like one product.
nonisolated enum Theme {
    // MARK: Color
    static let accent       = Color(red: 0.196, green: 0.835, blue: 0.514)   // #32D583 dash green
    static let accentDeep   = Color(red: 0.090, green: 0.560, blue: 0.330)
    static let live         = Color(red: 1.000, green: 0.353, blue: 0.373)   // #FF5A5F
    static let amber        = Color(red: 1.000, green: 0.710, blue: 0.278)   // #FFB547

    // Adaptive neutrals: resolve per trait collection so Light/Dark (and the car's
    // day/night contentStyle) flip every surface, not just the system chrome.
    static let ground   = adaptive(light: (0.965, 0.969, 0.976), dark: (0.043, 0.059, 0.078))  // #F6F7F9 / #0B0F14
    static let surface  = adaptive(light: (1.000, 1.000, 1.000), dark: (0.082, 0.106, 0.137))  // #FFFFFF / #151B23
    static let raised   = adaptive(light: (0.925, 0.933, 0.945), dark: (0.118, 0.153, 0.200))  // #ECEEF1 / #1E2733
    static let hairline = Color(uiColor: UIColor { @Sendable tc in tc.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.08) })

    static let ink      = adaptive(light: (0.071, 0.086, 0.106), dark: (0.949, 0.961, 0.973))  // #12161B / #F2F5F8
    static let inkMuted = adaptive(light: (0.400, 0.447, 0.510), dark: (0.545, 0.596, 0.659))  // #667282 / #8B98A8
    static let inkFaint = Color(uiColor: UIColor { @Sendable tc in tc.userInterfaceStyle == .dark
        ? UIColor(red: 0.545, green: 0.596, blue: 0.659, alpha: 0.55)
        : UIColor(red: 0.400, green: 0.447, blue: 0.510, alpha: 0.55) })

    nonisolated private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { @Sendable tc in
            let c = tc.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // MARK: Radii
    static let radiusS: CGFloat = 10
    static let radiusM: CGFloat = 16
    static let radiusL: CGFloat = 22
    static let radiusXL: CGFloat = 28

    // MARK: Spacing (4pt grid)
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
    static let s10: CGFloat = 40

    // MARK: Type
    enum Font {
        static func display(_ size: CGFloat, weight: SwiftUI.Font.Weight = .bold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        static let largeTitle = display(34)
        static let title      = display(26)
        static let title2     = display(21, weight: .semibold)
        static let headline   = display(17, weight: .semibold)
        static let tile       = display(15, weight: .semibold)
        static let body       = SwiftUI.Font.system(size: 16)
        static let callout    = SwiftUI.Font.system(size: 15)
        static let caption    = SwiftUI.Font.system(size: 12.5, weight: .medium)
        static let label      = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let mono       = SwiftUI.Font.system(size: 13, weight: .medium, design: .monospaced)
    }

    // MARK: Car sizes
    /// Car displays range from ~425×255pt (compact head units) to ~1200×600 (wide).
    /// Everything scales off `CarMetrics`, resolved from the window size at runtime.
    enum Car {
        static let minTarget: CGFloat = 52
        static func title(_ size: CGFloat = 22) -> SwiftUI.Font { Font.display(size) }
    }
}

nonisolated struct CarMetrics: Equatable {
    /// The car UI is designed at ≥ 800×480 pt. Smaller head units (640×384, 425×255…)
    /// lay out at that design size and are scaled down as one, so every control,
    /// label and the player keep their proportions instead of overflowing.
    static let designSize = CGSize(width: 800, height: 480)
    /// Portrait head units are designed at the rotated size; the layout goes
    /// `compact` there anyway, so only genuinely narrow screens get shrunk.
    static func design(for size: CGSize) -> CGSize {
        size.height > size.width ? CGSize(width: designSize.height, height: designSize.width) : designSize
    }
    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        let d = design(for: size)
        return min(1, size.width / d.width, size.height / d.height)
    }
    /// Size the UI is laid out at (real size ÷ scale).
    static func layoutSize(for size: CGSize) -> CGSize {
        let s = scale(for: size)
        return CGSize(width: size.width / s, height: size.height / s)
    }

    let railWidth: CGFloat
    let tileWidth: CGFloat
    let gutter: CGFloat
    let headerHeight: CGFloat
    let titleSize: CGFloat
    let cardMin: CGFloat
    let compact: Bool

    init(size: CGSize) {
        compact = size.width < 700
        railWidth = compact ? 64 : 88
        tileWidth = compact ? 128 : 172
        gutter = compact ? 12 : 20
        headerHeight = compact ? 46 : 58
        titleSize = compact ? 18 : 24
        cardMin = compact ? 160 : 220
    }

    static let fallback = CarMetrics(size: CGSize(width: 800, height: 480))
}

private struct CarMetricsKey: EnvironmentKey { static let defaultValue = CarMetrics.fallback }
extension EnvironmentValues {
    var carMetrics: CarMetrics { get { self[CarMetricsKey.self] } set { self[CarMetricsKey.self] = newValue } }
}

// MARK: - Reusable modifiers

struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.radiusM
    var padding: CGFloat = Theme.s4
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.radiusM, padding: CGFloat = Theme.s4, tint: Color? = nil) -> some View {
        modifier(GlassCard(radius: radius, padding: padding, tint: tint))
    }

    /// Uppercase eyebrow label used above shelves and in settings.
    func eyebrow() -> some View {
        font(Theme.Font.label)
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Theme.inkMuted)
    }

    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// Deterministic tint for tiles without artwork, so the same channel always gets the same color.
nonisolated enum TileTint {
    static func color(for seed: String) -> Color {
        var hash: UInt32 = 2166136261
        for b in seed.utf8 { hash = (hash ^ UInt32(b)) &* 16777619 }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.42, brightness: 0.55)
    }

    static func gradient(for seed: String) -> LinearGradient {
        let base = color(for: seed)
        return LinearGradient(colors: [base.opacity(0.95), base.opacity(0.55), Theme.raised], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Monogram fallback when a channel has no logo.
struct Monogram: View {
    let text: String
    var size: CGFloat = 22
    var body: some View {
        Text(initials)
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
    }
    private var initials: String {
        let words = text.split(separator: " ").filter { !$0.isEmpty && $0.first!.isLetter || $0.first!.isNumber }
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(text.trimmed.prefix(2)).uppercased()
    }
}

