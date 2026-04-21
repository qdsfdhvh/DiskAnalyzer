import SwiftUI

/// "Quiet Data" — bright, restrained, confident. Paper-white ground, near-black
/// text, a single warm accent used sparingly. One sans-serif family (SF Pro)
/// plus SF Mono for tabular numbers. The rule of thumb: fewer elements,
/// tighter alignment, more whitespace.
enum DT {

    // MARK: - Color

    static let bg         = Color(red: 0.980, green: 0.976, blue: 0.965)  // #FAF9F6 warm paper
    static let surface    = Color.white
    static let surfaceAlt = Color(red: 0.969, green: 0.965, blue: 0.957)  // #F7F6F4
    static let hover      = Color(red: 0.953, green: 0.949, blue: 0.941)  // #F3F2EF

    static let line       = Color(red: 0.914, green: 0.906, blue: 0.890)  // #E9E7E3
    static let lineStrong = Color(red: 0.827, green: 0.816, blue: 0.792)  // #D3D0CA

    static let fg        = Color(red: 0.067, green: 0.067, blue: 0.075)   // #111113 near-black
    static let fgMuted   = Color(red: 0.447, green: 0.447, blue: 0.455)   // #727274
    static let fgSubtle  = Color(red: 0.722, green: 0.722, blue: 0.725)   // #B8B8B9

    /// Single accent — warm terracotta. Used only where it earns attention:
    /// the biggest row, scanning state, hover on interactive elements. Not a
    /// brand color plastered everywhere.
    static let accent     = Color(red: 0.820, green: 0.482, blue: 0.310)  // #D17B4F
    static let accentSoft = Color(red: 0.941, green: 0.871, blue: 0.827)  // #F0DED3

    /// Tier bar tints — mostly neutral, accent reserved for real outliers so
    /// the eye doesn't fatigue. Everything below 10 GB reads the same muted
    /// gray; the visual delta is the bar *width*, not a rainbow of colors.
    static func tier(forBytes bytes: Int64) -> Color {
        switch bytes {
        case ..<(1024 * 1024 * 1024):       return fgSubtle.opacity(0.35)   // <1 GB
        case ..<(10 * 1024 * 1024 * 1024):  return fgMuted.opacity(0.45)    // <10 GB
        case ..<(50 * 1024 * 1024 * 1024):  return accent.opacity(0.55)     // <50 GB
        default:                            return accent                  // 50 GB+
        }
    }

    // MARK: - Typography
    //
    // Single family: SF Pro for everything, SF Mono only where we need
    // tabular alignment. No serif, no extra display faces — minimalism
    // earns its character from spacing and weight, not font variety.

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: - Metrics

    static let gutter: CGFloat = 28
    static let rowVPadding: CGFloat = 10
}

// MARK: - Size formatting that separates number from unit

extension SizeFormatter {
    /// ("413.4", "GB") — lets the view scale the number and unit independently.
    static func split(_ bytes: Int64) -> (number: String, unit: String) {
        let s = SizeFormatter.string(bytes)
        if let idx = s.firstIndex(of: " ") {
            return (String(s[..<idx]), String(s[s.index(after: idx)...]))
        }
        return (s, "")
    }
}

// MARK: - Quiet button style

/// One button style, two variants. No shadows, no gradients, no corner radius
/// above 6pt — the chrome is a 1px line and a subtle fill.
struct QuietButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost }
    var variant: Variant = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DT.text(12, weight: .medium))
            .foregroundStyle(foreground(configuration))
            .padding(.horizontal, variant == .ghost ? 10 : 14)
            .padding(.vertical, 8)
            .background(background(configuration))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(border, lineWidth: variant == .secondary ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private func foreground(_ c: Configuration) -> Color {
        switch variant {
        case .primary: return .white
        case .secondary, .ghost: return DT.fg
        }
    }

    private func background(_ c: Configuration) -> Color {
        switch variant {
        case .primary: return DT.fg
        case .secondary: return c.isPressed ? DT.hover : DT.surface
        case .ghost: return c.isPressed ? DT.hover : Color.clear
        }
    }

    private var border: Color { DT.lineStrong }
}
