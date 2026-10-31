import AppKit
import EktharDriveCore
import SwiftUI
import UniformTypeIdentifiers

/// Design tokens: continuous rounded corners, layered materials, hairline borders, soft depth.
enum Theme {
    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 12
    static let controlRadius: CGFloat = 9
    static let hairline = Color.primary.opacity(0.08)
}

struct PremiumCard: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.background.secondary)
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
    }
}

extension View {
    func premiumCard(radius: CGFloat = Theme.cardRadius, padding: CGFloat = 18) -> some View {
        modifier(PremiumCard(radius: radius, padding: padding))
    }
}

/// Rounded app-icon style tile for a provider.
struct DriveIconTile: View {
    let provider: ProviderKind
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: provider.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: tint.opacity(0.25), radius: size * 0.12, y: size * 0.05)
    }

    var tint: Color {
        switch provider {
        case .googleDrive: Color(red: 0.16, green: 0.47, blue: 0.95)
        case .oracleSFTP: Color(red: 0.86, green: 0.27, blue: 0.20)
        }
    }
}

/// Circular capacity gauge. Shows "—" when the provider did not report capacity.
struct CapacityRing: View {
    let usage: StorageUsage?
    var size: CGFloat = 64
    var lineWidth: CGFloat = 7

    var body: some View {
        let fraction = usage?.usedFraction
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.005, fraction))
                    .stroke(color(fraction).gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded)).monospacedDigit()
                if size >= 60 { Text("used").font(.system(size: size * 0.13)).foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(fraction.map { "\(Int($0 * 100)) percent used" } ?? "Capacity unavailable")
    }

    private func color(_ f: Double) -> Color { f > 0.9 ? .red : f > 0.75 ? .orange : .accentColor }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

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

    static func kind(for item: FileItem) -> String {
        if item.isDirectory { return "Folder" }
        return UTType(filenameExtension: item.pathExtension)?.localizedDescription ?? (item.pathExtension.isEmpty ? "Document" : item.pathExtension.uppercased() + " file")
    }
}
