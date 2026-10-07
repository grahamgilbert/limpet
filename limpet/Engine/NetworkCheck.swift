// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import OSLog

public protocol NetworkChecking: Sendable {
    /// True when it is worth poking GlobalProtect: the network is up, we are not
    /// behind a captive portal, and (when configured) the VPN portal answers.
    /// Poking GP otherwise only raises its window over the captive-portal login.
    func isReady() async -> Bool
}

public struct AlwaysReadyNetworkCheck: NetworkChecking {
    public init() {}
    public func isReady() async -> Bool { true }
}

/// Two probes:
/// 1. Apple's captive-portal probe. A real internet connection returns an exact
///    body; a captive portal returns a redirect or its own page. A response that
///    is not "Success" means captive: block. "No network" errors also block.
///    Any other failure (timeout, DNS, blocked host) is ambiguous: some
///    networks only let GP's portal through until the VPN is up, so the portal
///    probe decides.
/// 2. The GP portal, if one is configured. Proves the thing we actually need.
///    With no portal configured and an ambiguous Apple probe we let GP try.
public struct SystemNetworkCheck: NetworkChecking {
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "network")
    static let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!

    enum AppleProbe { case success, captive, offline, unreachable }

    /// Answers every redirect with "don't follow": the first response is the
    /// evidence, and chasing a captive portal's redirect chain proves nothing.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let portalAddress: @Sendable @MainActor () -> String
    private let session: URLSession

    public init(portalAddress: @escaping @Sendable @MainActor () -> String) {
        self.portalAddress = portalAddress
        let config = URLSessionConfiguration.ephemeral
        // Request timeout resets as bytes arrive; the resource timeout is the
        // hard cap on a portal that trickles a response forever.
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        self.session = URLSession(configuration: config)
    }

    public func isReady() async -> Bool {
        let apple = await appleProbe()
        if apple == .captive || apple == .offline {
            Self.log.notice("network not ready: apple probe \(String(describing: apple), privacy: .public)")
            return false
        }
        let addr = await MainActor.run { portalAddress() }
        guard let url = Self.portalURL(from: addr) else { return true }
        guard await portalAnswers(url) else {
            Self.log.notice("network not ready: portal unreachable")
            return false
        }
        return true
    }

    private func appleProbe() async -> AppleProbe {
        do {
            let (data, _) = try await session.data(for: URLRequest(url: Self.probeURL), delegate: NoRedirect())
            return Self.isAppleSuccess(data) ? .success : .captive
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            return .offline
        } catch {
            return .unreachable
        }
    }

    /// Any HTTP response, or a TLS failure, means the host answered. Only
    /// DNS/connect/timeout errors count as unreachable: a portal with an odd
    /// certificate must not stall the VPN forever.
    private func portalAnswers(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            _ = try await session.data(for: request, delegate: NoRedirect())
            return true
        } catch let error as URLError {
            switch error.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRequired,
                 .clientCertificateRejected, .cannotParseResponse, .badServerResponse:
                return true
            default:
                return false
            }
        } catch {
            return false
        }
    }

    static func isAppleSuccess(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8)?.contains("<TITLE>Success</TITLE>") ?? false
    }

    /// Accepts "vpn.example.com" or a full URL. Blank means "no portal check".
    static func portalURL(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    }
}
