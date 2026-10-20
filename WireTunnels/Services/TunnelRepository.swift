import Foundation

final class TunnelRepository {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        createDirectoriesIfNeeded()
    }

    func load() -> [Tunnel] {
        guard FileManager.default.fileExists(atPath: AppPaths.metadataFile.path),
              let data = try? Data(contentsOf: AppPaths.metadataFile),
              let tunnels = try? decoder.decode([Tunnel].self, from: data) else {
            return []
        }
        return tunnels
    }

    func save(_ tunnels: [Tunnel]) {
        try? saveChecked(tunnels)
    }

    func saveChecked(_ tunnels: [Tunnel]) throws {
        try encoder.encode(tunnels).write(to: AppPaths.metadataFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.metadataFile.path)
    }

    private func createDirectoriesIfNeeded() {
        let dir = AppPaths.metadataFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.userConfigDir, withIntermediateDirectories: true)
    }
}
