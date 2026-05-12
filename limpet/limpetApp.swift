import SwiftUI
import ApplicationServices

@main
struct limpetApp: App {
    @NSApplicationDelegateAdaptor(LimpetAppDelegate.self) private var delegate
    @State private var appState: AppState
    @State private var preferences: Preferences
    @State private var trust: AccessibilityTrustWatcher
    @State private var updater: Updater
    private let controller: AccessibilityVpnController
    private let monitor: LogTailingStatusMonitor
    private let popupLoop: PopupDismisserLoop
    private let watchdogTask: Task<Void, Never>

    @MainActor
    init() {
        let appState = AppState()
        let preferences = Preferences()
        let controller = AccessibilityVpnController()
        let monitor = LogTailingStatusMonitor()
        let updater = Updater()

        let watchdog = Watchdog(
            controller: controller,
            stateSink: appState,
            desired: preferences.desiredStateProxy()
        )
        let stream = monitor.stream
        let dog = watchdog
        self.watchdogTask = Task.detached {
            await dog.consume(stream)
        }

        let dismisser = PopupDismisserImpl(provider: GlobalProtectWindowProvider())
        let loop = PopupDismisserLoop(dismisser: dismisser)
        loop.start()

        self._appState = State(initialValue: appState)
        self._preferences = State(initialValue: preferences)
        self._trust = State(initialValue: AccessibilityTrustWatcher())
        self._updater = State(initialValue: updater)
        self.controller = controller
        self.monitor = monitor
        self.popupLoop = loop
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                appState: appState,
                preferences: preferences,
                trust: trust,
                controller: controller,
                openPreferences: showPreferencesWindow
            )
        } label: {
            MenuBarLabel(state: appState.connection)
        }
        .menuBarExtraStyle(.window)

        Window("limpet — Permission Required", id: "permission") {
            PermissionWindow()
                .onChange(of: trust.isTrusted) { _, granted in
                    if granted {
                        for window in NSApp.windows where window.identifier?.rawValue == "permission" {
                            window.close()
                        }
                    }
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 320)

        Window("limpet — Preferences", id: "preferences") {
            PreferencesWindow(preferences: preferences, updater: updater)
        }
        .windowResizability(.contentSize)
    }

    @MainActor
    private func showPreferencesWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "preferences" }) {
            window.makeKeyAndOrderFront(nil)
        } else if let url = URL(string: "limpet://preferences") {
            NSWorkspace.shared.open(url)
        }
    }
}

final class LimpetAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        InstallLocation.promptIfNeeded()

        if AX.isProcessTrusted(prompt: false) {
            for window in NSApp.windows where window.identifier?.rawValue == "permission" {
                window.close()
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.identifier?.rawValue == "permission" {
                window.makeKeyAndOrderFront(nil)
            }
        }

        // Preferences window stays closed until the user invokes it.
        for window in NSApp.windows where window.identifier?.rawValue == "preferences" {
            window.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
