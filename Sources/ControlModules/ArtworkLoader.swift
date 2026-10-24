import DockCore
import Foundation
import os

private let log = Logger(subsystem: "StreamDock", category: "Music")

/// Album artwork → LED palette, cached per album.
///
/// 1. Music's own artwork (library tracks).
/// 2. iTunes lookup by catalog ID from Music's store link — exact edition, any storefront.
/// 3. iTunes search by name, preferring an exact album-name match.
/// Steps 2–3 send the album ID or the artist and album name to Apple.
@MainActor
final class ArtworkLoader {
    private var cache: [String: [RGB]] = [:]

    /// Storefronts to try: the user's own first, then large catalogs. There is no iTunes
    /// Store in China, so CN rarely answers.
    private nonisolated static var storefronts: [String] {
        var list = [Locale.current.region?.identifier ?? "US"]
        for country in ["US", "JP", "HK", "TW", "GB"] where !list.contains(country) { list.append(country) }
        return list
    }

    func palette(for track: AppleMusic.Track, from music: AppleMusic) async -> [RGB] {
        let key = "\(track.artist)\u{1F}\(track.album)"
        if let cached = cache[key] { return cached }

        var data: Data?
        let local = await music.currentArtwork()
        if let artwork = local.data {
            log.notice("Artwork from Music for \(track.album, privacy: .public)")
            data = artwork
        } else {
            log.notice("Music has no artwork for \(track.album, privacy: .public) (AppleScript error \(local.error ?? 0)), store ID \(music.storeID ?? "none", privacy: .public)")
            if let id = music.storeID { data = await Self.lookupArtwork(id: id) }
            if data == nil { data = await Self.searchArtwork(artist: track.artist, album: track.album) }
        }
        guard let data else {
            // Not cached: the next play of this album tries again.
            return ArtworkPalette.fallback
        }
        let palette = ArtworkPalette.colors(from: data)
        cache[key] = palette
        return palette
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            let collectionName: String?
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    private nonisolated static func lookupArtwork(id: String) async -> Data? {
        for country in storefronts {
            let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)&country=\(country)")!
            guard let response = await fetch(url), let artwork = response.results.first?.artworkUrl100 else { continue }
            log.notice("Artwork by ID \(id, privacy: .public) from iTunes (\(country, privacy: .public))")
            return await download(artwork)
        }
        log.notice("iTunes lookup found nothing for ID \(id, privacy: .public)")
        return nil
    }

    private nonisolated static func searchArtwork(artist: String, album: String) async -> Data? {
        guard !album.isEmpty else { return nil }
        // "Patient Zero - Single" searches better as "Patient Zero"; editions like
        // "(Deluxe Version)" stay in the term so the right cover wins when it exists.
        let term = album.replacingOccurrences(of: #"\s+-\s+(Single|EP)$"#, with: "", options: .regularExpression)
        var fallback: String?
        for country in storefronts {
            var components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [
                URLQueryItem(name: "term", value: "\(artist) \(term)"),
                URLQueryItem(name: "entity", value: "album"),
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "country", value: country),
            ]
            guard let url = components.url, let response = await fetch(url) else { continue }
            if let exact = response.results.first(where: { $0.collectionName?.caseInsensitiveCompare(album) == .orderedSame || $0.collectionName?.caseInsensitiveCompare(term) == .orderedSame }),
               let artwork = exact.artworkUrl100 {
                log.notice("Artwork by exact name from iTunes (\(country, privacy: .public)) for \(album, privacy: .public)")
                return await download(artwork)
            }
            fallback = fallback ?? response.results.first?.artworkUrl100
        }
        guard let fallback else {
            log.notice("iTunes search found nothing for \(artist, privacy: .public) – \(album, privacy: .public)")
            return nil
        }
        log.notice("No exact match for \(album, privacy: .public); using the closest iTunes result")
        return await download(fallback)
    }

    private nonisolated static func fetch(_ url: URL) async -> Response? {
        do {
            let (json, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(Response.self, from: json)
            return response.results.isEmpty ? nil : response
        } catch {
            log.error("iTunes request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func download(_ small: String) async -> Data? {
        guard let url = URL(string: small.replacingOccurrences(of: "100x100", with: "300x300")) else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }
}
