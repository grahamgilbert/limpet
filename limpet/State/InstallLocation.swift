import AppKit
import Foundation
import OSLog

/// Detects when limpet is running from outside `/Applications/` and offers to
/// move itself. Remembers a "no" answer so we don't pester the user every
/// launch.
enum InstallLocation {
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "install")
    private static let suppressKey = "limpet.suppressApplicationsMovePrompt"
    private static let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// `true` when the running bundle is under `/Applications/`.
    static var isInApplications: Bool {
        let bundle = Bundle.main.bundleURL.standardized.resolvingSymlinksInPath()
        let apps = applicationsURL.standardized.resolvingSymlinksInPath()
        return bundle.path.hasPrefix(apps.path + "/")
    }

    /// Show the move prompt if the app is in the wrong place AND the user
    /// hasn't previously declined.
    @MainActor
    static func promptIfNeeded() {
        guard !isInApplications else { return }
        if UserDefaults.standard.bool(forKey: suppressKey) {
            log.info("not in /Applications/, but user previously declined")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Move limpet to Applications?"
        alert.informativeText = """
            limpet works best when it lives in /Applications/. Moving it there \
            keeps Accessibility permission stable and lets Start at Login work \
            reliably.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        alert.addButton(withTitle: "Don't Ask Again")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            moveToApplicationsAndRelaunch()
        case .alertSecondButtonReturn:
            log.info("user declined move (just for now)")
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: suppressKey)
            log.info("user declined move and suppressed future prompts")
        default:
            break
        }
    }

    /// Copy ourselves to `/Applications/`, then relaunch from there and quit
    /// this instance.
    @MainActor
    private static func moveToApplicationsAndRelaunch() {
        let source = Bundle.main.bundleURL
        let dest = applicationsURL.appendingPathComponent("limpet.app")

        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)
            log.info("copied to \(dest.path, privacy: .public)")
        } catch {
            log.error("copy failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Could not move limpet"
            alert.informativeText = """
                \(error.localizedDescription)

                You can move limpet to /Applications/ yourself by dragging it \
                from Finder.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Relaunch from the new location.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, error in
            if let error {
                Self.log.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
