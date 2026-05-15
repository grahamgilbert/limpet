// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

@preconcurrency import ApplicationServices
import AppKit
import Foundation
import OSLog

/// One snapshot of a candidate "GlobalProtect" alert window: its title, the
/// text shown to the user, and a closure that presses its primary button.
public struct PopupWindow: Sendable {
    public let title: String?
    public let bodyText: String?
    public let pressPrimary: @Sendable () -> Bool

    public init(
        title: String?,
        bodyText: String?,
        pressPrimary: @Sendable @escaping () -> Bool
    ) {
        self.title = title
        self.bodyText = bodyText
        self.pressPrimary = pressPrimary
    }
}

public protocol WindowProvider: Sendable {
    func currentWindows() -> [PopupWindow]
}

/// Pure rule: returns `true` if a window with this title and body text is
/// the GlobalProtect "you got disconnected" / "session timeout" / "connectivity
/// issues" popup that we should auto-dismiss.
public func shouldDismissPopup(title: String?, body: String?) -> Bool {
    guard title == "GlobalProtect" else { return false }
    guard let body = body?.lowercased() else { return false }
    return body.contains("disconnected")
        || body.contains("connectivity issues")
        || body.contains("session timeout")
}

/// Implementation of `PopupDismissing` that delegates window enumeration to a
/// `WindowProvider`. The real `WindowProvider` walks the live GP AX tree;
/// tests inject a fake provider with canned data.
public final class PopupDismisserImpl: PopupDismissing, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "popup")
    private let provider: WindowProvider

    public init(provider: WindowProvider) {
        self.provider = provider
    }

    @discardableResult
    public func tick() async -> Bool {
        var dismissed = false
        for window in provider.currentWindows()
            where shouldDismissPopup(title: window.title, body: window.bodyText) {
            let bodyPreview = String((window.bodyText ?? "").prefix(160))
            if window.pressPrimary() {
                dismissed = true
                Self.log.info("dismissed GlobalProtect popup title=\(window.title ?? "<nil>", privacy: .public) body=\(bodyPreview, privacy: .public)")
            } else {
                Self.log.error("failed to dismiss GlobalProtect popup title=\(window.title ?? "<nil>", privacy: .public) body=\(bodyPreview, privacy: .public)")
            }
        }
        return dismissed
    }
}

/// Background loop that dismisses GlobalProtect popups.
///
/// When GlobalProtect is running, it registers an `AXObserver` for
/// `kAXWindowCreatedNotification` so dismissal fires within milliseconds of
/// the popup appearing.  A 5-second fallback poller handles the period before
/// GP launches and any edge cases where the observer misses an event.
///
/// When GP is not running, only the fallback poller runs — it is cheap
/// because `currentWindows()` returns immediately when no GP process exists.
public final class PopupDismisserLoop: @unchecked Sendable {
    private static let bundleID = GlobalProtectInstallation.bundleID
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "popup")

    private let dismisser: PopupDismissing
    private let time: TimeSource
    private let fallbackInterval: Duration
    private let isEnabled: @Sendable () -> Bool
    private var task: Task<Void, Never>?

    // AXObserver machinery — only touched from the dedicated observer runloop thread.
    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private let observerQueue = DispatchQueue(label: "com.grahamgilbert.limpet.axobserver")

    public init(
        dismisser: PopupDismissing,
        time: TimeSource = SystemTimeSource(),
        fallbackInterval: Duration = .seconds(5),
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.dismisser = dismisser
        self.time = time
        self.fallbackInterval = fallbackInterval
        self.isEnabled = isEnabled
    }

    public func start() {
        task?.cancel()
        let dismisser = self.dismisser
        let time = self.time
        let fallbackInterval = self.fallbackInterval
        let isEnabled = self.isEnabled
        let weakSelf = Weak(self)

        // Fallback poller: fires every `fallbackInterval` and also handles
        // attaching/detaching the AXObserver as the GP process comes and goes.
        task = Task.detached {
            while !Task.isCancelled {
                if isEnabled() {
                    _ = await dismisser.tick()
                }
                weakSelf.value?.syncObserver(dismisser: dismisser)
                do {
                    try await time.sleep(for: fallbackInterval)
                } catch {
                    break
                }
            }
            weakSelf.value?.tearDownObserver()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        tearDownObserver()
    }

    deinit {
        task?.cancel()
        tearDownObserver()
    }

    // MARK: - AXObserver

    private func syncObserver(dismisser: PopupDismissing) {
        guard AX.isProcessTrusted(prompt: false) else {
            tearDownObserver()
            return
        }
        let gpApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID).first
        let pid = gpApp?.processIdentifier
        let isEnabled = self.isEnabled

        observerQueue.async { [weak self] in
            guard let self else { return }
            if pid == self.observedPID { return }

            self.tearDownObserverOnQueue()

            guard let pid else { return }

            var obs: AXObserver?
            let ctx = AXCallbackContext(dismisser: dismisser, isEnabled: isEnabled)
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                let ctx = Unmanaged<AXCallbackContext>.fromOpaque(refcon).takeUnretainedValue()
                ctx.scheduleTickIfIdle()
            }
            guard AXObserverCreate(pid, callback, &obs) == .success,
                  let obs else { return }

            let appElement = AXUIElementCreateApplication(pid)
            let retained = Unmanaged.passRetained(ctx)
            let err = AXObserverAddNotification(
                obs,
                appElement,
                kAXWindowCreatedNotification as CFString,
                retained.toOpaque()
            )
            guard err == .success else {
                retained.release()
                return
            }

            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(obs),
                .defaultMode
            )
            Self.log.debug("AXObserver attached to GP pid=\(pid)")
            self.axObserver = obs
            self.observedPID = pid
            self.retainedContextPtr = retained
        }
    }

    // Retained refcon passed to AXObserverAddNotification; released on teardown.
    private var retainedContextPtr: Unmanaged<AXCallbackContext>?

    private func tearDownObserver() {
        observerQueue.async { [weak self] in
            self?.tearDownObserverOnQueue()
        }
    }

    private func tearDownObserverOnQueue() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(obs),
                .defaultMode
            )
            Self.log.debug("AXObserver detached from GP pid=\(self.observedPID ?? -1)")
        }
        retainedContextPtr?.release()
        retainedContextPtr = nil
        axObserver = nil
        observedPID = nil
    }
}

/// Bundles the dismisser and the enabled-check for the AX callback refcon.
final class AXCallbackContext: @unchecked Sendable {
    let dismisser: any PopupDismissing
    let isEnabled: @Sendable () -> Bool
    private var inflightTask: Task<Void, Never>?
    private let lock = NSLock()

    init(dismisser: any PopupDismissing, isEnabled: @escaping @Sendable () -> Bool) {
        self.dismisser = dismisser
        self.isEnabled = isEnabled
    }

    func scheduleTickIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled(), inflightTask == nil else { return }
        let dismisser = self.dismisser
        inflightTask = Task { [weak self] in
            _ = await dismisser.tick()
            self?.lock.withLock { self?.inflightTask = nil }
        }
    }
}

/// Non-retaining wrapper so the loop task can hold a weak self reference.
private final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
