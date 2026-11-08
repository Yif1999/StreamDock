import AppKit
import Foundation

/// One source for both the cover key and the light strip.
@MainActor
struct ArtworkLoader {
    struct Artwork {
        let image: Data
        let palette: [Swatch]

        init?(image: Data) {
            guard let decoded = NSImage(data: image)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            self.image = image
            palette = ArtworkPalette.colors(from: decoded)
        }
    }

    private let storefronts: [String]
    private let request: (URL) async -> Data?

    init(storefronts: [String] = Self.storefronts, request: @escaping (URL) async -> Data? = Self.fetch) {
        self.storefronts = storefronts
        self.request = request
    }

    private static var storefronts: [String] {
        let region = Locale.current.region?.identifier ?? "US"
        let alternatives = region == "CN" ? ["HK", "TW", "US", "JP", "GB"] : ["US", "HK", "TW", "JP", "GB"]
        return [region] + alternatives.filter { $0 != region }
    }

    /// A lookup sends the catalog ID to Apple. Without an ID, search by song and artist and
    /// accept only a unique match including the album. Unverified URL-track artwork is never used.
    func load(for track: AppleMusic.Track, localArtwork: () async -> Data?) async -> Artwork? {
        let local = await localArtwork()
        guard !Task.isCancelled else { return nil }
        if let local, let artwork = Artwork(image: local) { return artwork }
        if let catalog = track.catalog { return await lookupArtwork(catalog) }
        return await searchArtwork(track)
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            let wrapperType: String?
            let trackId: Int?
            let collectionId: Int?
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let trackTimeMillis: Int?
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    private func lookupArtwork(_ catalog: AppleMusic.CatalogID) async -> Artwork? {
        let countries = catalog.storefront.map { [$0] + storefronts.filter { $0 != catalog.storefront } } ?? storefronts
        for country in countries {
            let results = await results(at: "lookup", query: ["id": String(catalog.id), "country": country])
            let match = results.first {
                switch catalog.kind {
                case .song: $0.trackId == catalog.id
                case .album: $0.wrapperType == "collection" && $0.collectionId == catalog.id
                }
            }
            if let artwork = await download(match?.artworkUrl100) { return artwork }
        }
        return nil
    }

    private func searchArtwork(_ track: AppleMusic.Track) async -> Artwork? {
        guard !track.name.isEmpty, !track.artist.isEmpty, !track.album.isEmpty else { return nil }
        let name = Self.normalized(track.name), artist = Self.normalized(track.artist), album = Self.normalized(track.album)
        for country in storefronts {
            let results = await results(at: "search", query: [
                "term": "\(track.artist) \(track.name)", "entity": "song", "limit": "25", "country": country,
            ])
            let matches = results.filter {
                guard $0.trackId != nil, Self.normalized($0.trackName) == name,
                      Self.normalized($0.artistName) == artist, Self.normalized($0.collectionName) == album else { return false }
                guard let duration = track.durationMS, duration > 0 else { return true }
                guard let result = $0.trackTimeMillis else { return false }
                return abs(Double(result) - Double(duration)) <= 2_000
            }
            guard Set(matches.compactMap(\.trackId)).count <= 1 else { return nil }
            if let artwork = await download(matches.first?.artworkUrl100) { return artwork }
        }
        return nil
    }

    private static func normalized(_ string: String?) -> String? {
        guard let string else { return nil }
        let simplified = string.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? string
        return simplified.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func results(at path: String, query: [String: String]) async -> [Response.Result] {
        guard !Task.isCancelled else { return [] }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/" + path
        components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url, let data = await request(url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return response.results
    }

    private func download(_ path: String?) async -> Artwork? {
        guard !Task.isCancelled, let path,
              let url = URL(string: path.replacingOccurrences(of: "100x100", with: "300x300")),
              let data = await request(url), !Task.isCancelled else { return nil }
        return Artwork(image: data)
    }

    private nonisolated static func fetch(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 5)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
        return data
    }
}
