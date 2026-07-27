import Foundation

/// Persists `HopChain` pairings — mirrors `TunnelRepository` exactly, just a
/// different file and model.
final class HopChainRepository {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var file: URL {
        AppPaths.userMetadataDir.appendingPathComponent("hopChains.json")
    }

    init() {
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [HopChain] {
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let chains = try? decoder.decode([HopChain].self, from: data) else {
            return []
        }
        return chains
    }

    func save(_ chains: [HopChain]) {
        try? FileManager.default.createDirectory(at: AppPaths.userMetadataDir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(chains) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
