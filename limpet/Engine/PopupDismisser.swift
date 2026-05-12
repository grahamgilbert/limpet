// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation

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
    private let provider: WindowProvider

    public init(provider: WindowProvider) {
        self.provider = provider
    }

    @discardableResult
    public func tick() async -> Bool {
        var dismissed = false
        for window in provider.currentWindows()
            where shouldDismissPopup(title: window.title, body: window.bodyText) {
            if window.pressPrimary() {
                dismissed = true
            }
        }
        return dismissed
    }
}

/// Background loop that runs a `PopupDismissing` once per `interval`.
public final class PopupDismisserLoop: @unchecked Sendable {
    private let dismisser: PopupDismissing
    private let time: TimeSource
    private let interval: Duration
    private var task: Task<Void, Never>?

    public init(dismisser: PopupDismissing, time: TimeSource = SystemTimeSource(), interval: Duration = .seconds(1)) {
        self.dismisser = dismisser
        self.time = time
        self.interval = interval
    }

    public func start() {
        task?.cancel()
        let dismisser = self.dismisser
        let time = self.time
        let interval = self.interval
        task = Task.detached {
            while !Task.isCancelled {
                _ = await dismisser.tick()
                do {
                    try await time.sleep(for: interval)
                } catch {
                    break
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
