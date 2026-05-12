import SwiftUI
import ServiceManagement

struct PreferencesWindow: View {
    @Bindable var preferences: Preferences
    @Bindable var updater: Updater

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start at Login", isOn: $preferences.startAtLogin)
                if let err = preferences.lastLoginItemError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                HStack {
                    Button("Check Now") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                    Spacer()
                    if let date = updater.lastUpdateCheckDate {
                        Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("About") {
                LabeledContent("limpet") {
                    Text(versionString)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
