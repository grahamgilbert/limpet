import SwiftUI
import ApplicationServices

@main
struct limpetApp: App {
    @NSApplicationDelegateAdaptor(LimpetAppDelegate.self) private var delegate
    @State private var appState: AppState
    @State private var preferences: Preferences
    @State private var trust: AccessibilityTrustWatcher
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
                controller: controller
            )
        } label: {
            Image(systemName: appState.connection.menuBarSystemImage)
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
    }
}

final class LimpetAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always stay accessory — no Dock icon, no Cmd-Tab entry. `.accessory`
        // apps can still show windows; we just float the permission window to
        // the front when needed.
        NSApp.setActivationPolicy(.accessory)

        // Offer to move ourselves into /Applications/ on first launch from a
        // weird location. Skipped if user previously chose "Don't Ask Again".
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
