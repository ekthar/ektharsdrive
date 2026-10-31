import AppKit
import EktharDriveCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Design tokens ("Studio White")

/// Colors, type, radii and motion for the whole app. Light-first: a white canvas, near-black ink,
/// one indigo accent, soft layered shadows and hairline borders.
public enum Theme {
    // Surfaces
    static let canvas = Color.white
    static let surface = Color(red: 0.965, green: 0.969, blue: 0.976)       // #F6F7F9
    static let surfaceSunken = Color(red: 0.945, green: 0.949, blue: 0.959) // #F1F2F5
    static let hairline = Color.black.opacity(0.07)
    static let hairlineStrong = Color.black.opacity(0.11)

    // Ink
    static let ink = Color(red: 0.043, green: 0.051, blue: 0.071)          // #0B0D12
    static let inkSecondary = Color(red: 0.357, green: 0.384, blue: 0.439) // #5B6270
    static let inkTertiary = Color(red: 0.604, green: 0.631, blue: 0.678)  // #9AA1AD

    // Accent and states
    static let accent = Color(red: 0.231, green: 0.357, blue: 0.992)       // #3B5BFD
    static let accentDeep = Color(red: 0.431, green: 0.278, blue: 1.0)     // #6E47FF
    static let accentGradient = LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accentSoft = accent.opacity(0.10)
    static let success = Color(red: 0.071, green: 0.718, blue: 0.416)      // #12B76A
    static let warning = Color(red: 0.969, green: 0.565, blue: 0.035)      // #F79009
    static let danger = Color(red: 0.941, green: 0.267, blue: 0.220)       // #F04438

    // Shape
    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 12
    static let controlRadius: CGFloat = 9

    // Motion
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.86)
    static let gentle = Animation.easeOut(duration: 0.35)
}

// MARK: - Typography (SF Pro, tuned sizes, weights and tracking)

extension Font {
    static let display = Font.system(size: 30, weight: .semibold, design: .default)
    static let titleLarge = Font.system(size: 22, weight: .semibold, design: .default)
    static let titleSmall = Font.system(size: 16, weight: .semibold, design: .default)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let body13 = Font.system(size: 13, weight: .regular)
    static let caption12 = Font.system(size: 12, weight: .regular)
    static let eyebrow = Font.system(size: 10.5, weight: .semibold)
    static let metric = Font.system(size: 24, weight: .semibold, design: .rounded)
}

extension View {
    func displayStyle() -> some View { font(.display).tracking(-0.7).foregroundStyle(Theme.ink) }
    func titleStyle() -> some View { font(.titleLarge).tracking(-0.4).foregroundStyle(Theme.ink) }
    /// Small uppercase label above a group, like Apple's own settings sections.
    func eyebrowStyle() -> some View { font(.eyebrow).tracking(0.8).textCase(.uppercase).foregroundStyle(Theme.inkTertiary) }
    func secondaryText() -> some View { foregroundStyle(Theme.inkSecondary) }
}

// MARK: - Surfaces

/// White card: continuous corners, hairline border, two-layer soft shadow.
struct CardSurface: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var padding: CGFloat = 18
    var elevated = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.canvas)
                    .shadow(color: .black.opacity(0.035), radius: 1, y: 1)
                    .shadow(color: .black.opacity(elevated ? 0.10 : 0.055), radius: elevated ? 22 : 14, y: elevated ? 12 : 6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
            }
    }
}

extension View {
    func premiumCard(radius: CGFloat = Theme.cardRadius, padding: CGFloat = 18) -> some View {
        modifier(CardSurface(radius: radius, padding: padding))
    }

    /// Lifts slightly with a deeper shadow while the pointer is over it.
    func hoverLift(_ amount: CGFloat = 1.012) -> some View { modifier(HoverLift(scale: amount)) }

    /// Fades and rises into place when first shown. `index` staggers items in a list or grid.
    func appearAnimation(index: Int = 0, offset: CGFloat = 10, enabled: Bool = true) -> some View {
        modifier(AppearIn(index: index, offset: offset, enabled: enabled))
    }
}

struct HoverLift: ViewModifier {
    let scale: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.06 : 0), radius: 18, y: 10)
            .animation(Theme.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

struct AppearIn: ViewModifier {
    let index: Int
    let offset: CGFloat
    var enabled = true
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : offset)
            .onAppear {
                guard !shown else { return }
                if !enabled || reduceMotion { shown = true; return }
                withAnimation(Theme.spring.delay(min(Double(index), 14) * 0.028)) { shown = true }
            }
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .frame(height: large ? 40 : 30)
            .background(RoundedRectangle(cornerRadius: large ? 11 : Theme.controlRadius, style: .continuous).fill(Theme.accentGradient))
            .overlay(RoundedRectangle(cornerRadius: large ? 11 : Theme.controlRadius, style: .continuous).strokeBorder(.white.opacity(0.18)))
            .shadow(color: Theme.accent.opacity(configuration.isPressed ? 0.15 : 0.32), radius: configuration.isPressed ? 4 : 10, y: configuration.isPressed ? 2 : 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, large ? 20 : 12)
            .frame(height: large ? 40 : 30)
            .background(RoundedRectangle(cornerRadius: large ? 11 : Theme.controlRadius, style: .continuous)
                .fill(configuration.isPressed ? Theme.surfaceSunken : Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: large ? 11 : Theme.controlRadius, style: .continuous).strokeBorder(Theme.hairlineStrong))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Quiet text-style button for inline actions ("See all").
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent.opacity(configuration.isPressed ? 0.6 : 1))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(large: true) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryLarge: SecondaryButtonStyle { SecondaryButtonStyle(large: true) }
}

extension ButtonStyle where Self == LinkButtonStyle {
    static var inlineLink: LinkButtonStyle { LinkButtonStyle() }
}

// MARK: - Graphics

/// Rounded app-icon style tile for a provider, with a soft glossy highlight.
struct DriveIconTile: View {
    let provider: ProviderKind
    var size: CGFloat = 44

    var body: some View {
        let radius = size * 0.27
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [tint.mix(.white, 0.12), tint.mix(.black, 0.10)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            }
            .overlay {
                Image(systemName: provider.symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.6) }
            .shadow(color: tint.opacity(0.30), radius: size * 0.16, y: size * 0.08)
    }

    var tint: Color { provider.tint }
}

extension ProviderKind {
    var tint: Color {
        switch self {
        case .googleDrive: Color(red: 0.102, green: 0.451, blue: 0.910) // Google blue
        case .oracleSFTP: Color(red: 0.780, green: 0.275, blue: 0.204)  // Oracle red
        }
    }
}

extension Color {
    /// Blend toward another color (0 = self, 1 = other).
    func mix(_ other: Color, _ amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let t = CGFloat(amount)
        return Color(red: a.redComponent + (b.redComponent - a.redComponent) * t,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t)
    }
}

/// Capacity gauge that sweeps in when shown and when the value changes. Shows "—" when capacity is unknown.
struct CapacityRing: View {
    let usage: StorageUsage?
    var size: CGFloat = 64
    var lineWidth: CGFloat = 7
    @State private var drawn: Double = 0

    var body: some View {
        let fraction = usage?.usedFraction
        ZStack {
            Circle().stroke(Theme.surfaceSunken, lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.004, drawn))
                    .stroke(AngularGradient(colors: ringColors(fraction), center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: ringColors(fraction).last!.opacity(0.25), radius: 4, y: 2)
            }
            VStack(spacing: -1) {
                Text(fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                    .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.ink)
                if size >= 56, fraction != nil {
                    Text("% used").font(.system(size: size * 0.12, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1)) { drawn = fraction ?? 0 } }
        .onChange(of: fraction) { _, new in withAnimation(Theme.spring) { drawn = new ?? 0 } }
        .accessibilityLabel(fraction.map { "\(Int($0 * 100)) percent used" } ?? "Capacity unavailable")
    }

    private func ringColors(_ f: Double) -> [Color] {
        if f > 0.9 { return [Theme.danger.mix(.white, 0.25), Theme.danger] }
        if f > 0.75 { return [Theme.warning.mix(.white, 0.25), Theme.warning] }
        return [Theme.accent, Theme.accentDeep]
    }
}

/// Thin animated bar version of the gauge, for sidebars and rows.
struct CapacityBar: View {
    let fraction: Double?
    var height: CGFloat = 5
    @State private var drawn: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceSunken)
                if fraction != nil {
                    Capsule().fill(fill).frame(width: max(height, geo.size.width * drawn))
                }
            }
        }
        .frame(height: height)
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.85).delay(0.1)) { drawn = fraction ?? 0 } }
        .onChange(of: fraction) { _, new in withAnimation(Theme.spring) { drawn = new ?? 0 } }
    }

    private var fill: LinearGradient {
        let f = fraction ?? 0
        let colors: [Color] = f > 0.9 ? [Theme.danger.mix(.white, 0.2), Theme.danger] : f > 0.75 ? [Theme.warning.mix(.white, 0.2), Theme.warning] : [Theme.accent, Theme.accentDeep]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.inkSecondary
    var symbol: String?
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.14)))
        .foregroundStyle(color)
    }
}

/// Moving highlight for loading placeholders.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.6)
                }
                .mask(content)
            }
            .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// Soft skeleton tile shown while a folder loads.
struct SkeletonTile: View {
    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceSunken).frame(width: 64, height: 64)
            RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceSunken).frame(width: 78, height: 9)
            RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceSunken).frame(width: 48, height: 8)
        }
        .frame(width: 112, height: 132)
        .shimmer()
    }
}

// MARK: - File icons

/// File-type icons from the system, by type only, so remote files are never read just to draw an icon.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let key = item.isDirectory ? "/folder" : item.pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: item.pathExtension) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }

    private static var bitmaps: [String: CGImage] = [:]

    /// The icon pre-rendered once per type at 128 px. Drawing a multi-size NSImage for every tile on
    /// every scroll frame was a large part of the scrolling lag.
    static func bitmap(for item: FileItem) -> CGImage {
        let key = item.isDirectory ? "/folder" : item.pathExtension.lowercased()
        if let b = bitmaps[key] { return b }
        let image = icon(for: item)
        var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            ?? NSImage(size: NSSize(width: 1, height: 1)).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        bitmaps[key] = cg
        return cg
    }

    static func kind(for item: FileItem) -> String {
        if item.isDirectory { return "Folder" }
        return UTType(filenameExtension: item.pathExtension)?.localizedDescription ?? (item.pathExtension.isEmpty ? "Document" : item.pathExtension.uppercased() + " file")
    }
}
