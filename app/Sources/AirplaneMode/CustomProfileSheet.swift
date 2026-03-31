import SwiftUI
import AirplaneModeCore

/// Inline view for editing and applying a custom network profile.
struct CustomProfileSheet: View {
    @Environment(AirplaneModeStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Profile")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                fieldRow(label: "Name", text: $store.customName)
                fieldRow(label: "Base Latency (ms)", text: $store.customLatencyMs)
                fieldRow(label: "Jitter Mean (ms)", text: $store.customJitterMeanMs)
                fieldRow(label: "Jitter P99 (ms)", text: $store.customJitterP99Ms)
                fieldRow(label: "Packet Loss (%)", text: $store.customPacketLoss)
                fieldRow(label: "Burst Length", text: $store.customBurstLen)
                fieldRow(label: "Bandwidth (KB/s)", text: $store.customBandwidthKBs)
            }

            HStack {
                Button("Cancel") { store.destination = .main }
                Spacer()
                Button("Save & Use") {
                    Task {
                        await store.applyCustomProfile()
                        store.destination = .main
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.isActive)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    @ViewBuilder
    private func fieldRow(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .monospacedDigit()
        }
    }
}
