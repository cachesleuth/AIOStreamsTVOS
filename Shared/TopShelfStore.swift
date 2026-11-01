import Foundation

/// A title on the Top Shelf: one of the page's `watch-next` items.
struct TopShelfItem: Codable, Equatable {
    var id: String
    var episode: Bool
    /// The show's, for an episode.
    var title: String
    var episodeTitle: String?
    var season: Int?
    var number: Int?
    /// The page's landscape artwork, at the size the Top Shelf draws.
    var image: String?
    var positionMs: Double
    var durationMs: Double?
    /// `aiostreams://play/<id>?server=…&start=…`
    var link: String

    var resumes: Bool { positionMs > 0 }

    /// "Show · S1 E3", or the film's name.
    var label: String {
        guard episode else { return title }
        var parts = [title]
        switch (season, number) {
        case let (s?, n?): parts.append("S\(s) E\(n)")
        case let (nil, n?): parts.append("E\(n)")
        default: if let episodeTitle { parts.append(episodeTitle) }
        }
        return parts.joined(separator: " · ")
    }

    var progress: Double? {
        guard resumes, let durationMs, durationMs > 0 else { return nil }
        return min(max(positionMs / durationMs, 0), 1)
    }

    var playURL: URL? { URL(string: link) }

    /// The item's page rather than playing it: `aiostreams://item/<id>?server=…`.
    var detailsURL: URL? {
        guard var parts = URLComponents(string: link) else { return nil }
        parts.host = "item"
        // As the page encoded it.
        parts.percentEncodedQueryItems = parts.percentEncodedQueryItems?.filter { $0.name == "server" }
        return parts.url
    }
}

/**
 * Where the app leaves the Top Shelf's list for the extension:
 * a folder in the App Group both are entitled to. Sideloading tools may
 * rename the group when they re-sign, so the group is read from this
 * process's own entitlements, falling back to the one the project declares.
 */
enum TopShelfStore {
    static let declaredGroup = "group.io.github.aiostreams.tvos"

    /// The Top Shelf's artwork width, in pixels: 548 points at 2x.
    static let imageWidth = 1096

    static let group: String = {
        let groups = entitledGroups()
        return groups.first { $0.lowercased().contains("aiostreams") } ?? groups.first ?? declaredGroup
    }()

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("TopShelf", isDirectory: true)
    }

    private static var listFile: URL? { folder?.appendingPathComponent("items.json") }

    static func load() -> [TopShelfItem] {
        guard let file = listFile, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([TopShelfItem].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ items: [TopShelfItem]) -> Bool {
        guard let folder, let file = listFile, let data = try? JSONEncoder().encode(items) else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            NSLog("[top-shelf] saving the list: %@", error.localizedDescription)
            return false
        }
    }

    /// The page asks Jellyfin for artwork 400 wide, for its own row; the Top Shelf draws it wider.
    static func sized(_ url: String) -> String {
        guard var parts = URLComponents(string: url) else { return url }
        // The rest as the page encoded it.
        var query = (parts.percentEncodedQueryItems ?? []).filter { $0.name.lowercased() != "maxwidth" }
        query.append(URLQueryItem(name: "maxWidth", value: String(imageWidth)))
        parts.percentEncodedQueryItems = query
        return parts.string ?? url
    }

    /**
     * This process's `com.apple.security.application-groups`. Security.framework
     * has the calls on tvOS but leaves them out of the SDK's headers.
     */
    private static func entitledGroups() -> [String] {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias Copy = @convention(c) (AnyObject, CFString, UnsafeMutableRawPointer?) -> Unmanaged<AnyObject>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let createSymbol = dlsym(security, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(security, "SecTaskCopyValueForEntitlement")
        else { return [] }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        let copy = unsafeBitCast(copySymbol, to: Copy.self)
        guard let task = create(nil)?.takeRetainedValue(),
              let value = copy(task, "com.apple.security.application-groups" as CFString, nil)?.takeRetainedValue()
        else { return [] }
        return (value as? [String]) ?? []
    }
}
