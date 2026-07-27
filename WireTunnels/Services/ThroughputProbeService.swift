import Foundation

/// Measures download throughput against a user-supplied URL — never a built-in
/// default host. Only runs when the user has explicitly set `Tunnel.speedTestURL`,
/// matching the "no third-party host involved" ethos of `PingService`/`testConnection`.
enum ThroughputProbeService {
    // Plain constants, read only from the nonisolated function below — safe to
    // access from any isolation context despite the project's MainActor-by-default
    // setting.
    private nonisolated static let maxBytes = 20 * 1_024 * 1_024
    private nonisolated static let defaultTimeout: TimeInterval = 8

    /// Megabits per second, or nil if the request failed, timed out, or returned no bytes.
    /// Blocking — call from a background task, not the main actor.
    nonisolated static func measureThroughput(url: URL, timeout: TimeInterval = defaultTimeout) async -> Double? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let start = Date()
        var totalBytes = 0

        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            for try await byte in bytes {
                _ = byte
                totalBytes += 1
                if totalBytes >= maxBytes { break }
                if Date().timeIntervalSince(start) >= timeout { break }
            }
        } catch {
            return nil
        }

        let elapsed = Date().timeIntervalSince(start)
        guard totalBytes > 0, elapsed > 0 else { return nil }
        let bits = Double(totalBytes) * 8
        return bits / elapsed / 1_000_000
    }
}
