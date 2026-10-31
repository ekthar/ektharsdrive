import EktharDriveCore
import SwiftUI

extension HealthLevel {
    var color: Color {
        switch self {
        case .inactive: .secondary
        case .healthy: .green
        case .degraded: .orange
        case .error: .red
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
        case .unverified: "Configured"
        case .testing: "Checking…"
        case .connected: "Connected"
        case .failed(let e): e.title
        }
    }
}

struct StatusDot: View {
    let health: HealthLevel
    var body: some View {
        Circle().fill(health.color).frame(width: 8, height: 8)
            .accessibilityLabel(health.label)
    }
}

struct StatusLabel: View {
    let text: String
    let health: HealthLevel
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(health: health)
            Text(text).foregroundStyle(health == .inactive ? .secondary : .primary)
        }
    }
}

/// Capacity bar that never invents numbers: unknown values render as "Unavailable".
struct CapacityView: View {
    let usage: StorageUsage?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let usage, let fraction = usage.usedFraction {
                ProgressView(value: fraction)
                    .tint(fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor)
                HStack {
                    Text("\(ByteFormat.string(usage.used)) used").monospacedDigit()
                    Spacer()
                    Text("\(ByteFormat.string(usage.free)) free of \(ByteFormat.string(usage.total))").monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(compact ? .caption : .callout)
            } else if let usage, usage.used != nil {
                Text("\(ByteFormat.string(usage.used)) used. Total capacity not reported by this provider.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Capacity unavailable").font(compact ? .caption : .callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct ErrorBanner: View {
    let error: DriveError
    var actions: [(String, () -> Void)] = []

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(error.title).font(.headline)
                Text(error.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !actions.isEmpty {
                    HStack {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                            Button(a.0, action: a.1)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25)))
    }

    private var tint: Color { error.category == .pendingWrite ? .orange : (error.isRetryable ? .orange : .red) }
    private var icon: String {
        switch error.category {
        case .authentication: "lock.trianglebadge.exclamationmark"
        case .disconnected: "wifi.exclamationmark"
        case .localDisk: "internaldrive"
        case .pendingWrite: "arrow.up.circle"
        default: "exclamationmark.triangle"
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension DriveError {
    /// Swift does not always infer typed throws through `do` blocks in closures; this keeps catch sites uniform.
    static func wrap(_ error: any Error) -> DriveError { (error as? DriveError) ?? .unknown(error.localizedDescription) }
}

extension Date {
    var relative: String { RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date()) }
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
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(transfer.status == .failed ? .red : .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(transfer.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(transfer.status.label).font(.caption).foregroundStyle(.secondary)
                }
                if transfer.status == .running, let f = transfer.fraction {
                    ProgressView(value: f).controlSize(.small)
                }
                HStack {
                    Text(driveName)
                    Text(transfer.progressText).monospacedDigit()
                    if transfer.status == .running { Text(ByteFormat.speed(transfer.speed)).monospacedDigit() }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
