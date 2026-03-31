import SwiftUI
import AirplaneModeCore

/// Main menu bar panel content.
struct MenuBarView: View {
    @Environment(AirplaneModeStore.self) private var store

    var body: some View {
        switch store.destination {
        case .main:
            mainContent
        case .customProfile:
            CustomProfileSheet()
                .environment(store)
        case .domains:
            DomainsSheet()
                .environment(store)
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.vertical, 8)
            profilesSection
            if store.isActive {
                Divider().padding(.vertical, 8)
                liveStatsSection
            }
            Divider().padding(.vertical, 8)
            domainsSection
            Divider().padding(.vertical, 8)
            footerSection
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        @Bindable var store = store
        HStack {
            Text("AirplaneMode")
                .font(.headline)
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Toggle("", isOn: Binding(
                get: { store.isActive },
                set: { newValue in
                    Task {
                        if newValue {
                            await store.activate()
                        } else {
                            await store.deactivate()
                        }
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }

        if let error = store.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.top, 4)
        }
    }

    // MARK: - Profiles

    @State private var showInfoFor: PresetProfile?

    @ViewBuilder
    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                ForEach(PresetProfile.allCases, id: \.rawValue) { preset in
                    presetRow(preset)
                }
                // Custom profile row
                customProfileRow
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: PresetProfile) -> some View {
        HStack {
            Button {
                Task { await store.setProfile(preset) }
            } label: {
                HStack {
                    Image(systemName: store.selectedProfile == preset
                        ? "circle.inset.filled" : "circle")
                        .foregroundStyle(store.selectedProfile == preset ? Color.accentColor : .secondary)
                        .font(.system(size: 12))

                    Text(preset.displayName)
                        .font(.body)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if preset != .none {
                Button {
                    showInfoFor = showInfoFor == preset ? nil : preset
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { showInfoFor == preset },
                    set: { if !$0 { showInfoFor = nil } }
                )) {
                    presetDetailView(preset.profile)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var customProfileRow: some View {
        HStack {
            Button {
                // Select custom profile (applies if already configured)
                if store.isActive {
                    Task { await store.applyCustomProfile() }
                }
            } label: {
                HStack {
                    Image(systemName: store.selectedProfile == .none && store.customName != "Custom"
                        ? "circle.inset.filled" : "circle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))

                    Text("Custom")
                        .font(.body)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                store.destination = .customProfile
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func presetDetailView(_ profile: NetworkProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profile.name)
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Latency").foregroundStyle(.secondary)
                    Text("\(profile.latencyMs)ms")
                }
                GridRow {
                    Text("Jitter mean").foregroundStyle(.secondary)
                    Text("\(profile.jitterMeanMs)ms")
                }
                GridRow {
                    Text("Jitter P99").foregroundStyle(.secondary)
                    Text("\(profile.jitterP99Ms)ms")
                }
                GridRow {
                    Text("Bandwidth").foregroundStyle(.secondary)
                    Text(formatBandwidth(profile.bandwidthBps))
                }
                GridRow {
                    Text("Packet loss").foregroundStyle(.secondary)
                    Text(formatLoss(profile.packetLoss))
                }
                if profile.burstLen > 0 {
                    GridRow {
                        Text("Burst length").foregroundStyle(.secondary)
                        Text("\(profile.burstLen)")
                    }
                }
            }
            .font(.caption)
            .monospacedDigit()
        }
        .padding(12)
    }

    // MARK: - Live Stats

    @ViewBuilder
    private var liveStatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Stats")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                if store.hasRecentActivity {
                    statRow(
                        label: "Latency",
                        value: store.stats.map { "\($0.latencyMs)ms" } ?? "--",
                        values: store.latencyHistory,
                        color: .orange,
                        valueFormatter: { "\(Int($0))ms" }
                    )

                    statRow(
                        label: "Throughput",
                        value: formattedThroughput,
                        values: store.throughputHistory,
                        color: .cyan,
                        referenceValue: store.stats.map { Double($0.throughputBytesPerSec) },
                        valueFormatter: { formatBytesPerSec(Int($0)) }
                    )
                } else {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                            Text("No activity")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        Spacer()
                    }
                }

                countersRow
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func statRow(
        label: String,
        value: String,
        values: [Double],
        color: Color,
        referenceValue: Double? = nil,
        valueFormatter: @escaping (Double) -> String = { "\(Int($0))" }
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
                    .fontWeight(.medium)
            }

            SparklineView(
                values: values,
                color: color,
                referenceValue: referenceValue,
                valueFormatter: valueFormatter
            )
            .frame(height: 40)
        }
    }

    @ViewBuilder
    private var countersRow: some View {
        if let s = store.stats {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(latencyStatusColor)
                        .frame(width: 6, height: 6)
                    Text(formatPacketCount(s.packetsTotal) + " pkts")
                        .font(.caption)
                        .monospacedDigit()
                }

                if s.drops > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8))
                        Text("\(s.drops) dropped")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                Text(store.lossPercentage + " loss")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Text(store.uptimeString)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Domains

    @ViewBuilder
    private var domainsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Domains")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.destination = .domains
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                if store.matchDomains.isEmpty {
                    Label("System-wide", systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.matchDomains, id: \.self) { domain in
                        Button {
                            if let url = URL(string: "https://\(domain)") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label(domain, systemImage: "globe")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerSection: some View {
        HStack {
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private var latencyStatusColor: Color {
        switch store.latencyColor {
        case .good: .green
        case .moderate: .yellow
        case .bad: .red
        }
    }

    private var formattedThroughput: String {
        guard let s = store.stats else { return "--" }
        return formatBytesPerSec(s.throughputBytesPerSec)
    }

    private func formatBytesPerSec(_ bps: Int) -> String {
        if bps == 0 { return "Idle" }
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", Double(bps) / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f KB/s", Double(bps) / 1_000) }
        return "\(bps) B/s"
    }

    private func formatBandwidth(_ bps: Int) -> String {
        if bps == 0 { return "Unlimited" }
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", Double(bps) * 8 / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f KB/s", Double(bps) / 1_000) }
        return "\(bps) B/s"
    }

    private func formatLoss(_ loss: Double) -> String {
        if loss == 0 { return "0%" }
        return String(format: "%.1f%%", loss * 100)
    }

    private func formatPacketCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
