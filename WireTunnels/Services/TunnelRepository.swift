import Foundation

final class TunnelRepository {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let metadataFile: URL
    private let configDirectory: URL

    init(metadataFile: URL = AppPaths.metadataFile, configDirectory: URL = AppPaths.userConfigDir) {
        self.metadataFile = metadataFile
        self.configDirectory = configDirectory
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        createDirectoriesIfNeeded()
    }

    func load() -> [Tunnel] {
        guard FileManager.default.fileExists(atPath: metadataFile.path),
              let data = try? Data(contentsOf: metadataFile),
              let tunnels = try? decoder.decode([Tunnel].self, from: data) else {
            return []
        }
        return tunnels
    }

    func save(_ tunnels: [Tunnel]) {
        try? saveChecked(tunnels)
    }

    func saveChecked(_ tunnels: [Tunnel]) throws {
        try encoder.encode(tunnels).write(to: metadataFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataFile.path)
    }

    private func createDirectoriesIfNeeded() {
        let dir = metadataFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }
}
