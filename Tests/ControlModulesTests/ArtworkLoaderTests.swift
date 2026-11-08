import Foundation
import Testing
import DockCore
@testable import ControlModules

@MainActor
struct ArtworkLoaderTests {
    @Test func storeLinkKeepsTheSongIDAndOverridesSearch() async throws {
        let event = try #require(AppleMusic.playerInfo([
            "Player State": "Playing", "Name": "Title", "Artist": "Artist", "Album": "Album",
            "Store URL": "https://music.apple.com/hk/album/album/42?i=81",
        ]))
        let track = try #require(event.track)
        #expect(track.catalog?.kind == .song)
        #expect(track.catalog?.id == 81)
        #expect(AppleMusic.CatalogID(storeURL: "itms://itunes.com/album?p=42&i=81")?.id == 81)
        #expect(AppleMusic.CatalogID(storeURL: "itms://itunes.com/album?p=42")?.kind == .album)

        let cover = try #require(KeyRenderer.jpeg(for: KeyFace(title: "Exact", tone: .on)))
        let lookup = Data("""
        {"results": [
          {"trackId": 80, "collectionId": 42, "artworkUrl100": "https://example.test/wrong.jpg"},
          {"trackId": 81, "collectionId": 42, "artworkUrl100": "https://example.test/right.jpg"}
        ]}
        """.utf8)
        var requests: [URL] = []
        let loader = ArtworkLoader(storefronts: ["US"]) { url in
            requests.append(url)
            switch url.path {
            case "/lookup": return lookup
            case "/right.jpg": return cover
            default: return nil
            }
        }
        let result = await loader.load(for: track) { nil }
        #expect(requests.map(\.path) == ["/lookup", "/right.jpg"])
        let query = requests.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        #expect(query.contains(URLQueryItem(name: "id", value: "81")))
        #expect(query.contains(URLQueryItem(name: "country", value: "HK")))
        #expect(result?.image == cover)
        #expect(result?.palette == ArtworkPalette.colors(from: cover))
    }

    @Test func searchUsesTheSongArtistAlbumAndDurationAndRejectsAmbiguity() async throws {
        let search = Data("""
        {"results": [
          {"trackId": 10, "trackName": "剛剛好", "artistName": "另一位藝人", "collectionName": "初學者", "artworkUrl100": "https://example.test/wrong.jpg"},
          {"trackId": 11, "trackName": "剛剛好", "artistName": "薛之謙", "collectionName": "初學者 - Single", "artworkUrl100": "https://example.test/wrong.jpg"},
          {"trackId": 12, "trackName": "剛剛好 (Live)", "artistName": "薛之謙", "collectionName": "初學者", "artworkUrl100": "https://example.test/wrong.jpg"},
          {"trackId": 13, "trackName": "剛剛好", "artistName": "薛之謙", "collectionName": "初學者", "trackTimeMillis": 240000, "artworkUrl100": "https://example.test/wrong.jpg"},
          {"trackId": 14, "trackName": "剛剛好", "artistName": "薛之謙", "collectionName": "初學者", "trackTimeMillis": 250500, "artworkUrl100": "https://example.test/right.jpg"}
        ]}
        """.utf8)
        let cover = try #require(KeyRenderer.jpeg(for: KeyFace(title: "Exact", tone: .alert)))
        var requests: [String] = []
        let loader = ArtworkLoader(storefronts: ["HK"]) { url in
            requests.append(url.path)
            switch url.path {
            case "/search": return search
            case "/right.jpg": return cover
            default: return nil
            }
        }
        var track = AppleMusic.Track(name: "刚刚好", artist: "薛之谦", album: "初学者", durationMS: 250_482)
        #expect(await loader.load(for: track) { Data([0, 1]) }?.image == cover)
        #expect(requests == ["/search", "/right.jpg"])

        requests.removeAll()
        track.durationMS = nil
        #expect(await loader.load(for: track) { nil } == nil)
        let otherAlbum = AppleMusic.Track(name: track.name, artist: track.artist, album: "Greatest Hits")
        #expect(await loader.load(for: otherAlbum) { nil } == nil)
        #expect(requests == ["/search", "/search"])
    }

    @Test func verifiedLibraryCoverSuppliesBothImageAndPalette() async throws {
        let cover = try #require(KeyRenderer.jpeg(for: KeyFace(title: "Custom", tone: .on)))
        let track = AppleMusic.Track(name: "Title", artist: "Artist", album: "Album")
        let loader = ArtworkLoader { _ in
            Issue.record("A verified library cover should not trigger a network request")
            return nil
        }
        let result = await loader.load(for: track) { cover }
        #expect(result?.image == cover)
        #expect(result?.palette == ArtworkPalette.colors(from: cover))
    }
}
