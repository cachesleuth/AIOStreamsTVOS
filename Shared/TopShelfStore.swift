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
 * Where the app leaves the Top Shelf's list for the extension: a folder in
 * each App Group this process is signed with. Sideloading tools rename the
 * groups when they re-sign, some to a handful of generic ones
 * (`group.<hash>.1` to `.5`) in no set order, so neither side can tell which
 * one the other picked. The app writes to all of them, and each side reads
 * the newest copy it finds in any.
 */
enum TopShelfStore {
    static let declaredGroup = "group.io.github.aiostreams.tvos"

    /// The Top Shelf's artwork width, in pixels: 548 points at 2x.
    static let imageWidth = 1096

    /// The App Groups this process was signed with.
    static let entitled = entitledGroups()

    /// A TopShelf folder in each group's container that tvOS gave this process.
    static let folders: [URL] = {
        let groups = entitled.isEmpty ? [declaredGroup] : entitled
        return groups.compactMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)?
                .appendingPathComponent("TopShelf", isDirectory: true)
        }
    }()

    private static let listName = "items.json"
    private static let askedName = "asked.txt"

    /// The most recently written copy of a file, across the groups.
    private static func newest(_ name: String) -> URL? {
        folders
            .map { $0.appendingPathComponent(name) }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Into every group; true if at least one took it.
    private static func write(_ data: Data, as name: String) -> Bool {
        var wrote = false
        for folder in folders {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                wrote = true
            } catch {
                NSLog("[top-shelf] writing %@ to %@: %@", name, folder.path, error.localizedDescription)
            }
        }
        return wrote
    }

    static func load() -> [TopShelfItem] {
        guard let file = newest(listName), let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([TopShelfItem].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ items: [TopShelfItem]) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        return write(data, as: listName)
    }

    /// The extension notes when tvOS asked it for the Top Shelf, and what it showed.
    static func noteAsked(shown: Int) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(shown)"
        _ = write(Data(line.utf8), as: askedName)
    }

    /// When tvOS last asked the extension, and how many titles it showed then.
    static func lastAsked() -> (date: Date, shown: Int)? {
        guard let file = newest(askedName), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let date = ISO8601DateFormatter().date(from: String(parts[0])),
              let shown = Int(parts[1]) else { return nil }
        return (date, shown)
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
