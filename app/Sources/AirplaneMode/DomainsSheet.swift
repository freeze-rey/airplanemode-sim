import SwiftUI
import AirplaneModeCore

/// Inline view for editing the list of domains routed through the relay.
/// Empty list = system-wide routing.
struct DomainsSheet: View {
    @Environment(AirplaneModeStore.self) private var store
    @State private var domainsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Matched Domains")
                .font(.headline)

            Text(
                "One domain per line. Subdomains are included automatically. "
                + "Leave empty for system-wide routing."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            TextEditor(text: $domainsText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .border(Color.secondary.opacity(0.3))

            Text("Example: chatgpt.com will also match api.chatgpt.com, cdn.chatgpt.com, etc.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if store.isActive {
                Label(
                    "Saving will reinstall the relay profile. macOS will prompt you to approve in System Settings.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { store.destination = .main }
                Spacer()
                Button("Save & Apply") {
                    let domains = domainsText
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    Task {
                        await store.updateDomains(domains)
                        store.destination = .main
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            domainsText = store.matchDomains.joined(separator: "\n")
        }
    }
}
