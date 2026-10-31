import EktharDriveCore
import SwiftUI

extension HealthLevel {
    var color: Color {
        switch self {
        case .inactive: Theme.inkTertiary
        case .healthy: Theme.success
        case .degraded: Theme.warning
        case .error: Theme.danger
        }
    }

    var label: String {
        switch self {
        case .inactive: "Inactive"
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .error: "Needs attention"
        }
    }
}

extension ProviderKind {
    var symbol: String {
        switch self {
        case .googleDrive: "externaldrive.badge.icloud"
        case .oracleSFTP: "server.rack"
        }
    }
}

extension ConnectionState {
    var label: String {
        switch self {
        case .notConfigured: "Not connected"
        case .unverified: "Ready"
        case .testing: "Checking…"
        case .connected: "Connected"
        case .failed(let e): e.title
        }
    }
}

/// Status light. Healthy drives get a soft halo; drives that are working or retrying pulse.
struct StatusDot: View {
    let health: HealthLevel
    var pulsing = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if health == .healthy || pulsing {
                Circle().fill(health.color.opacity(0.22)).frame(width: 14, height: 14)
                    .scaleEffect(pulsing && pulse ? 1.35 : 1)
                    .opacity(pulsing && pulse ? 0 : 1)
            }
            Circle().fill(health.color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { if pulsing && !reduceMotion { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true } } }
        .help(health.label)
        .accessibilityLabel(health.label)
    }
}

struct StatusLabel: View {
    let text: String
    let health: HealthLevel
    var pulsing = false
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(health: health, pulsing: pulsing)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(health == .inactive ? Theme.inkSecondary : Theme.ink)
                .contentTransition(.opacity)
        }
        .animation(Theme.gentle, value: text)
    }
}

extension MountPhase {
    var isBusy: Bool {
        switch self {
        case .mounting, .unmounting, .waitingForUploads, .retrying: true
        default: false
        }
    }
}

/// Capacity bar that never invents numbers: unknown values render as "Unavailable".
struct CapacityView: View {
    let usage: StorageUsage?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let usage, let fraction = usage.usedFraction {
                CapacityBar(fraction: fraction, height: compact ? 5 : 7)
                HStack {
                    Text("\(ByteFormat.string(usage.used)) used").monospacedDigit().foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(ByteFormat.string(usage.free)) free of \(ByteFormat.string(usage.total))").monospacedDigit().secondaryText()
                }
                .font(.system(size: compact ? 11 : 12, weight: .medium))
            } else if let usage, usage.used != nil {
                Text("\(ByteFormat.string(usage.used)) used. Total capacity not reported by this provider.")
                    .font(.caption12).secondaryText()
            } else {
                Text("Capacity unavailable").font(.caption12).secondaryText()
            }
        }
    }
}

struct ErrorBanner: View {
    let error: DriveError
    var actions: [(String, () -> Void)] = []

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)).frame(width: 30, height: 30)
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(error.title).font(.bodyStrong).foregroundStyle(Theme.ink)
                Text(error.detail).font(.caption12).secondaryText().fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { i, a in
                            if i == 0 { Button(a.0, action: a.1).buttonStyle(.secondary) } else { Button(a.0, action: a.1).buttonStyle(.inlineLink) }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.20)))
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
    }

    private var tint: Color { error.category == .pendingWrite || error.isRetryable ? Theme.warning : Theme.danger }
    private var icon: String {
        switch error.category {
        case .authentication: "lock.fill"
        case .disconnected: "wifi.exclamationmark"
        case .localDisk: "internaldrive.fill"
        case .pendingWrite: "arrow.up.circle.fill"
        default: "exclamationmark.triangle.fill"
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(title).eyebrowStyle()
            }
            Text(value).font(.metric).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            // Always reserve the detail line so every tile in a row has the same height.
            Text(detail ?? " ").font(.caption12).secondaryText().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(radius: 16, padding: 16)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.titleSmall).foregroundStyle(Theme.ink)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }
}

extension DriveError {
    /// Swift does not always infer typed throws through `do` blocks in closures; this keeps catch sites uniform.
    static func wrap(_ error: any Error) -> DriveError { (error as? DriveError) ?? .unknown(error.localizedDescription) }
}

extension Date {
    var relative: String {
        if abs(timeIntervalSinceNow) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: self, relativeTo: Date())
    }
}

extension Transfer {
    var progressText: String {
        if let total = totalBytes { return "\(ByteFormat.string(transferredBytes)) of \(ByteFormat.string(total))" }
        return ByteFormat.string(transferredBytes)
    }

    var etaText: String {
        guard status == .running, let eta, eta.isFinite, eta >= 0 else { return "--" }
        return Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}

struct TransferRow: View {
    let transfer: Transfer
    let driveName: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.10)).frame(width: 30, height: 30)
                Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(transfer.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(transfer.status == .running ? ByteFormat.speed(transfer.speed) : transfer.status.label)
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().secondaryText()
                }
                if transfer.status == .running, let f = transfer.fraction {
                    CapacityBar(fraction: f, height: 4)
                }
                Text("\(driveName) · \(transfer.progressText)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.vertical, 3)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var tint: Color { transfer.status == .failed ? Theme.danger : Theme.accent }
}

/// Large empty-state illustration: layered rounded shapes behind an SF Symbol.
struct EmptyStateArt: View {
    let symbol: String
    var tint: Color = Theme.accent
    @State private var float = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(tint.opacity(0.06)).frame(width: 120, height: 120).rotationEffect(.degrees(-8))
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.canvas).frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.hairline))
            Image(systemName: symbol).font(.system(size: 36, weight: .medium)).foregroundStyle(tint.gradient)
        }
        .offset(y: float ? -4 : 2)
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { float = true } } }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var symbol: String = "folder"
    var body: some View {
        VStack(spacing: 18) {
            EmptyStateArt(symbol: symbol)
            VStack(spacing: 6) {
                Text(title).font(.titleSmall).foregroundStyle(Theme.ink)
                Text(message).font(.caption12).secondaryText().multilineTextAlignment(.center).frame(maxWidth: 300)
            }
        }
        .appearAnimation()
    }
}
