// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import SwiftUI
import ServiceManagement

struct PreferencesWindow: View {
    @Bindable var preferences: Preferences
    @Bindable var updater: Updater

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start at Login", isOn: $preferences.startAtLogin)

                Toggle("Automatically dismiss GlobalProtect popups", isOn: $preferences.dismissPopups)

                Text("Disable this while debugging new GlobalProtect dialogs or validating popup matching behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if preferences.loginItemNeedsAttention {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Approval needed")
                                .font(.caption.bold())
                            Text("limpet is registered but won't launch at login until you approve it in System Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Login Items Settings") {
                                openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if let err = preferences.lastLoginItemError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Install prerelease versions", isOn: $preferences.installPrereleases)
                Text("Prerelease builds may be unstable. They receive updates before the stable channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .fixedSize(horizontal: false, vertical: true)
        .padding()
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
