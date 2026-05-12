import Foundation
import Observation

@MainActor
@Observable
public final class AppState: StateSink {
    public var connection: ConnectionState
    public var lastError: String?

    public init(connection: ConnectionState = .unknown) {
        self.connection = connection
    }

    public nonisolated func update(_ state: ConnectionState) {
        Task { @MainActor in
            self.connection = state
        }
    }
}
