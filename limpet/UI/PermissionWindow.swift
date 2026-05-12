// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import SwiftUI
import AppKit

struct PermissionWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility Permission Required")
                        .font(.title2.bold())
                    Text("limpet needs Accessibility to control GlobalProtect.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("To grant permission:").font(.headline)
                Label("Click **Grant Permission** below.", systemImage: "1.circle.fill")
                Label("In the macOS dialog, click **Open System Settings**.", systemImage: "2.circle.fill")
                Label("Toggle **limpet** on in the Accessibility list.", systemImage: "3.circle.fill")
                Label("This window closes automatically.", systemImage: "4.circle.fill")
            }
            .labelStyle(.titleAndIcon)

            Spacer(minLength: 0)

            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
                Button("Open Accessibility Settings") {
                    openAccessibilitySettings()
                }
                Button("Grant Permission") {
                    _ = AX.isProcessTrusted(prompt: true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 320)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
