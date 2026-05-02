import SwiftUI
import SendToX4Core

struct SettingsView: View {
    @State private var x4IP: String = ""
    @State private var apiKey: String = ""
    @State private var llmEnabled: Bool = true
    @State private var subnetScanEnabled: Bool = true
    @State private var probeInterval: Double = 5
    @State private var saveStatus: String = ""

    var body: some View {
        Form {
            Section("Xteink X4") {
                LabeledContent("Last-known IP") {
                    TextField("e.g. 192.168.1.42", text: $x4IP)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
                Toggle("Scan local subnet if last-known IP doesn't respond", isOn: $subnetScanEnabled)
                LabeledContent("Probe interval") {
                    HStack {
                        Slider(value: $probeInterval, in: 2...30, step: 1)
                            .frame(width: 160)
                        Text("\(Int(probeInterval))s").monospacedDigit().frame(width: 28)
                    }
                }
                Text("Tip: set a DHCP reservation for your X4 on your router so its IP never changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Polish (Claude)") {
                Toggle("Use Claude to clean up captures", isOn: $llmEnabled)
                LabeledContent("Anthropic API key") {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                Text("Stored in your macOS Keychain. Polish never rewrites article text — it only removes site chrome and detects chapters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if !saveStatus.isEmpty {
                    Text(saveStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear(perform: load)
    }

    private func load() {
        let snap = SettingsStore.shared.snapshot
        x4IP = snap.lastKnownX4IP ?? ""
        llmEnabled = snap.llmEnabled
        subnetScanEnabled = snap.subnetScanEnabled
        probeInterval = snap.probeIntervalSeconds
        apiKey = SettingsStore.shared.anthropicAPIKey() ?? ""
    }

    private func save() {
        do {
            try SettingsStore.shared.update { s in
                s.lastKnownX4IP = x4IP.trimmingCharacters(in: .whitespaces).nonEmpty
                s.llmEnabled = llmEnabled
                s.subnetScanEnabled = subnetScanEnabled
                s.probeIntervalSeconds = probeInterval
            }
            try SettingsStore.shared.setAnthropicAPIKey(apiKey.trimmingCharacters(in: .whitespaces))
            saveStatus = "Saved."
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
