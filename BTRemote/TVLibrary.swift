import Foundation

// MARK: - Kind

enum TVLibraryKind: String, Codable, CaseIterable, Sendable {
    case app
    case bookmark
}

// MARK: - Launch target (pure model; no network / no app-open)

struct TVLaunchTarget: Equatable, Sendable {
    let wireLink: String
    let expectedPackage: String?

    /// Parse a raw target value. For `.app`, a bare Android package is tried
    /// first and converted to `market://launch?id=<package>` (see
    /// tronikos/androidtvremote2 @ c5d729e); otherwise a URI is parsed.
    /// `.bookmark` never accepts a bare package.
    static func parse(_ value: String, kind: TVLibraryKind) throws -> TVLaunchTarget {
        guard value.utf8.count <= 8192, !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw TVLibraryError(description: "Target is too long or contains control characters.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TVLibraryError(description: "Target cannot be empty. Enter a URL or, for an app, its package name.")
        }
        if kind == .app, let pkg = normalizedPackage(trimmed) {
            var c = URLComponents()
            c.scheme = "market"
            c.host = "launch"
            c.queryItems = [URLQueryItem(name: "id", value: pkg)]
            guard let url = c.url else {
                throw TVLibraryError(description: "Could not build a launch URL for that app package. Check the package name.")
            }
            return TVLaunchTarget(wireLink: url.absoluteString, expectedPackage: pkg)
        }
        return try parseURI(trimmed, requirePackageFromMarket: kind == .app)
    }

    /// Build a YouTube web-search target from a free-text query. Does not hit
    /// the network or open anything; it only produces the canonical URL.
    static func youtubeSearch(_ query: String) throws -> TVLaunchTarget {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            throw TVLibraryError(description: "Search text cannot be empty. Enter what you want to find.")
        }
        guard q.count <= 512, q.utf8.count <= 2048,
              !q.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw TVLibraryError(description: "Search text is too long. Use 512 characters or fewer.")
        }
        var c = URLComponents()
        c.scheme = "https"
        c.host = "www.youtube.com"
        c.path = "/results"
        c.queryItems = [URLQueryItem(name: "search_query", value: q)]
        guard let url = c.url else {
            throw TVLibraryError(description: "Could not build the search URL. Check the search text for invalid characters.")
        }
        return try parse(url.absoluteString, kind: .bookmark)
    }

    // Returns the normalized package only when `value` is a valid bare Android
    // package (>=2 ASCII segments; each starts with a letter; remaining chars
    // are letters/digits/underscore). Rejects whitespace, control chars, query
    // injection, and any non-ASCII content.
    private static func normalizedPackage(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 255 else { return nil }
        // Shortest valid bare package is "a.b" (2 single-letter segments).
        guard value.unicodeScalars.count >= 3 else { return nil }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        for segment in segments {
            guard let first = segment.unicodeScalars.first, isASCIILetter(first) else { return nil }
            for sc in segment.unicodeScalars.dropFirst() {
                let ok = sc == "_"
                    || isASCIILetter(sc)
                    || (sc.value >= 0x30 && sc.value <= 0x39) // 0-9
                guard ok else { return nil }
            }
        }
        return value
    }

    private static func isASCIILetter(_ sc: Unicode.Scalar) -> Bool {
        return (sc.value >= 0x41 && sc.value <= 0x5A) || (sc.value >= 0x61 && sc.value <= 0x7A)
    }

    // Accepts http/https with a valid host, or a safe app scheme (unknown
    // non-blocked scheme passes for installed-app handling). Rejects control
    // characters, scheme-relative URLs, missing scheme, and the unsafe scheme
    // blocklist. Canonicalizes via URLComponents/URL to preserve Unicode,
    // percent-escaping, query and fragments.
    private static func parseURI(_ value: String, requirePackageFromMarket: Bool) throws -> TVLaunchTarget {
        for sc in value.unicodeScalars {
            if sc.value < 0x20 || sc.value == 0x7F {
                throw TVLibraryError(description: "That target contains control characters. Remove them and try again.")
            }
        }
        guard let comps = URLComponents(string: value), let scheme = comps.scheme, !scheme.isEmpty else {
            throw TVLibraryError(description: "That target is not a valid URL. Use an http(s) URL or a valid app package.")
        }
        let lower = scheme.lowercased()
        let blocked: Set<String> = [
            "javascript", "data", "file", "content", "intent",
            "mailto", "tel", "sms", "blob", "vbscript",
        ]
        if blocked.contains(lower) {
            throw TVLibraryError(description: "That URL scheme is not allowed. Use an http(s) URL or a valid app package.")
        }
        if lower == "http" || lower == "https" {
            guard let host = comps.host, !host.isEmpty,
                  !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                throw TVLibraryError(description: "That URL has no host. Check the address and try again.")
            }
        }
        guard let url = comps.url else {
            throw TVLibraryError(description: "Could not understand that URL. Check it and try again.")
        }
        guard url.absoluteString.utf8.count <= 8192 else {
            throw TVLibraryError(description: "Encoded target is too long. Use a shorter link.")
        }
        var expected: String?
        if requirePackageFromMarket && lower == "market" && comps.host == "launch" {
            if let idValue = comps.queryItems?.first(where: { $0.name == "id" })?.value,
               let pkg = normalizedPackage(idValue) {
                expected = pkg
            }
        }
        return TVLaunchTarget(wireLink: url.absoluteString, expectedPackage: expected)
    }
}

// MARK: - Item

struct TVLibraryItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var kind: TVLibraryKind
    var target: String
    var symbol: String
    var favorite: Bool

    init(id: UUID = UUID(), title: String, kind: TVLibraryKind, target: String,
         symbol: String = "app", favorite: Bool = false) {
        self.id = id
        self.title = title
        self.kind = kind
        self.target = target
        self.symbol = symbol
        self.favorite = favorite
    }
}

// MARK: - Errors

struct TVLibraryError: LocalizedError, Equatable {
    let description: String
    var errorDescription: String? { description }
}

// MARK: - Library

struct TVLibrary: Codable, Equatable, Sendable {
    var version: Int = 1
    private(set) var items: [TVLibraryItem]
    private(set) var recentIDs: [UUID]

    init(items: [TVLibraryItem] = [], recentIDs: [UUID] = []) {
        self.items = items
        self.recentIDs = recentIDs
    }

    // Stable, constant UUIDs (constructed from fixed strings so they never drift).
    private static let youtubeItem = TVLibraryItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        title: "YouTube",
        kind: .app,
        target: "https://www.youtube.com", symbol: "play.rectangle"
    )

    private static let netflixItem = TVLibraryItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        title: "Netflix",
        kind: .app,
        target: "https://www.netflix.com", symbol: "film"
    )

    private static let kodiItem = TVLibraryItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        title: "Kodi",
        kind: .app,
        target: "org.xbmc.kodi"
    )

    private static let spotifyItem = TVLibraryItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        title: "Spotify",
        kind: .app,
        target: "com.spotify.tv.android"
    )

    private static let tivimateItem = TVLibraryItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        title: "TiviMate",
        kind: .app,
        target: "ar.tvplayer.tv"
    )

    private static let smartTubeItem = TVLibraryItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        title: "SmartTube",
        kind: .app,
        target: "com.teamsmart.videomanager.tv"
    )

    /// Suggested items the app knows about. First two (YouTube, Netflix) are
    /// "visible to owner"; the optional source-author (issue 17) apps are
    /// Kodi, Spotify, TiviMate, SmartTube. This is a fixed catalog — the app
    /// does NOT claim to discover installed apps.
    static var catalog: [TVLibraryItem] {
        return [youtubeItem, netflixItem, kodiItem, spotifyItem, tivimateItem, smartTubeItem]
    }

    /// Starting library: begins with the two owner-visible items (YouTube,
    /// Netflix). The optional catalog apps are not pre-added (no claim they are
    /// installed, and no automatic network/replay).
    static var initial: TVLibrary {
        return TVLibrary(items: [youtubeItem, netflixItem])
    }

    var recentItems: [TVLibraryItem] {
        var byID: [UUID: TVLibraryItem] = [:]
        byID.reserveCapacity(items.count)
        for item in items { byID[item.id] = item }
        var result: [TVLibraryItem] = []
        result.reserveCapacity(recentIDs.count)
        for id in recentIDs {
            if let item = byID[id] { result.append(item) }
        }
        return result
    }

    /// Validate a full existing record. Throws on any corrupt/invalid content
    /// (root preserves its old data and does not adopt a record that throws).
    func validated() throws -> TVLibrary {
        guard version == 1 else {
            throw TVLibraryError(description: "Unknown data format version \(version). Expected version 1.")
        }
        guard items.count <= 64 else {
            throw TVLibraryError(description: "Too many items. Maximum is 64.")
        }
        var seenIDs: Set<UUID> = []
        seenIDs.reserveCapacity(items.count)
        for item in items {
            guard !seenIDs.contains(item.id) else {
                throw TVLibraryError(description: "Duplicate item id found. Each entry must have a unique id.")
            }
            seenIDs.insert(item.id)
            try validateItem(item)
        }
        guard recentIDs.count <= 10 else {
            throw TVLibraryError(description: "Too many recent entries. Maximum is 10.")
        }
        var seenRecents: Set<UUID> = []
        seenRecents.reserveCapacity(recentIDs.count)
        let validItemIDs = seenIDs
        for id in recentIDs {
            guard validItemIDs.contains(id) else {
                throw TVLibraryError(description: "A recent entry points to an item that no longer exists.")
            }
            guard !seenRecents.contains(id) else {
                throw TVLibraryError(description: "A recent entry is listed more than once.")
            }
            seenRecents.insert(id)
        }
        return self
    }

    // MARK: Validation helpers

    private func validateItem(_ item: TVLibraryItem) throws {
        let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TVLibraryError(description: "An entry has an empty title. Enter a name for it.")
        }
        guard item.title.count <= 80, !item.title.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw TVLibraryError(description: "An entry title is too long. Use 80 characters or fewer.")
        }
        guard !item.symbol.isEmpty, item.symbol.utf8.count <= 64,
              item.symbol.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46, 45, 95].contains($0) }) else {
            throw TVLibraryError(description: "Shortcut icon name is invalid.")
        }
        guard !item.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TVLibraryError(description: "An entry has an empty target. Enter a URL or app package.")
        }
        // Ensures target parses for its declared kind (bare-package-vs-URI rules).
        _ = try TVLaunchTarget.parse(item.target, kind: item.kind)
        guard item.target.utf8.count <= 8192 else {
            throw TVLibraryError(description: "An entry target is too long. Use 8192 bytes (UTF-8) or fewer.")
        }
    }

    // MARK: Mutations (validate before assignment; stable IDs)

    /// Insert or replace by id. Validates before committing so a failed call
    /// leaves the library unchanged.
    mutating func upsert(_ item: TVLibraryItem) throws {
        guard version == 1 else {
            throw TVLibraryError(description: "Cannot edit: unknown data format version \(version).")
        }
        try validateItem(item)
        var item = item
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.target = item.target.trimmingCharacters(in: .whitespacesAndNewlines)

        var nextItems = items
        var nextRecents = recentIDs
        if let existingIndex = nextItems.firstIndex(where: { $0.id == item.id }) {
            // Edit: keep the stable id, replace the whole record.
            nextItems[existingIndex] = item
        } else {
            guard nextItems.count < 64 else {
                throw TVLibraryError(description: "Cannot add: the library already has the maximum of 64 items.")
            }
            nextItems.append(item)
            // Trim recents if the new item's id was already tracked.
            if let pos = nextRecents.firstIndex(of: item.id) { nextRecents.remove(at: pos) }
            if nextRecents.count > 10 { nextRecents.removeFirst(nextRecents.count - 10) }
        }
        self.items = nextItems
        self.recentIDs = nextRecents
    }

    /// Delete an item; drop it from recents (deduplicate on delete).
    mutating func remove(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: index)
        }
        if let pos = recentIDs.firstIndex(of: id) {
            recentIDs.remove(at: pos)
        }
    }

    /// Toggle favorite; keeps the stable id.
    mutating func toggleFavorite(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].favorite.toggle()
        }
    }

    /// Reorder an item by `offset` positions. Clamped to the valid range so it
    /// cannot crash or move past the ends; keeps the stable id.
    mutating func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let maxIndex = items.count - 1
        let newIndex = index + min(max(offset, -index), maxIndex - index)
        guard newIndex != index else { return }
        let moved = items.remove(at: index)
        items.insert(moved, at: newIndex)
    }

    /// Record a launch: de-duplicate and move the id to the front of recents.
    /// No automatic network / replay.
    mutating func recordLaunch(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        if let pos = recentIDs.firstIndex(of: id) {
            recentIDs.remove(at: pos)
        }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > 10 {
            recentIDs.removeLast(recentIDs.count - 10)
        }
    }
}
