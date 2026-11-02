import TVServices

/**
 * The page's `watch-next` list, what Android TV puts in its Watch Next row:
 * the home page's resume points and next episodes, newest first, or none
 * once signed out. Saved where the Top Shelf extension reads it, and tvOS
 * told to ask the extension again.
 */
enum TopShelf {
    /// The last list the page sent, and when, for the app menu.
    private static var received: (date: Date, count: Int, saved: Bool)?

    static func publish(_ message: Message) {
        let items = (message["items"] as? [Message] ?? []).compactMap(item)
        if items == TopShelfStore.load(), received?.saved == true {
            received = (Date(), items.count, true)
            return
        }
        let saved = TopShelfStore.save(items)
        received = (Date(), items.count, saved)
        if saved {
            TVTopShelfContentProvider.topShelfContentDidChange()
        } else {
            NSLog("[top-shelf] no App Group container took the list; groups: %@", TopShelfStore.entitled.joined(separator: ", "))
        }
    }

    private static func item(_ entry: Message) -> TopShelfItem? {
        guard let id = entry.text("id"), let title = entry.text("title"), let link = entry.text("link") else { return nil }
        return TopShelfItem(
            id: id,
            episode: entry.text("kind") == "episode",
            title: title,
            episodeTitle: entry.text("episodeTitle"),
            season: entry.number("season").map { Int($0) },
            number: entry.number("episode").map { Int($0) },
            image: entry.text("image").map(TopShelfStore.sized),
            positionMs: entry.number("positionMs") ?? 0,
            durationMs: entry.number("durationMs"),
            link: link
        )
    }

    /**
     * Where the Top Shelf breaks down, for the app menu and the diagnostics:
     * the App Group the signing kept, the extension in the app, the page's
     * list, and whether tvOS has asked the extension for it.
     */
    static var report: [String] {
        let groups = TopShelfStore.entitled.count
        let containers = TopShelfStore.folders.count
        let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("AIOStreamsTopShelf.appex")
        let bundled = appex.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let ids = appex.map { identity(of: $0) } ?? "-"
        let extensionGroups: String
        if let appex, let profile = provisionedGroups(in: appex) {
            let shared = Set(profile).intersection(TopShelfStore.entitled).count
            extensionGroups = "its profile has \(profile.count) App Groups, \(shared) shared with the app"
                + (profile.isEmpty ? "" : " (\(profile.map(shortGroup).joined(separator: " ")))")
        } else {
            extensionGroups = bundled ? "no profile in it" : "-"
        }
        let appProfile = provisionedGroups(in: Bundle.main.bundleURL)
            .map { "\($0.count) App Groups, \(Set($0).intersection(TopShelfStore.entitled).count) of the app's" }
            ?? "none"
        let time = { (date: Date) in DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium) }
        let page = received.map {
            "\($0.count) titles at \(time($0.date))\($0.saved ? "" : ", not saved")"
        } ?? "nothing yet"
        let asked = TopShelfStore.lastAsked().map {
            "\(DateFormatter.localizedString(from: $0.date, dateStyle: .short, timeStyle: .medium)), showed \($0.shown)"
        } ?? "never"
        // Short lines: the app menu cuts off what doesn't fit.
        return [
            "Top Shelf: app has \(groups) App Groups (\(TopShelfStore.entitled.map(shortGroup).joined(separator: " "))), \(containers) containers",
            "Top Shelf extension: \(bundled ? "in the app" : "missing"); \(extensionGroups)",
            "Top Shelf IDs: \(ids)",
            "Top Shelf asked: \(asked)",
            "Top Shelf list: \(page); saved \(TopShelfStore.load().count)",
            "App's profile: \(appProfile); last save: \(TopShelfStore.lastWrite.settings) settings, \(TopShelfStore.lastWrite.files) folders"
                + (TopShelfStore.lastError.map { "; folder error \($0)" } ?? ""),
        ]
    }

    /// The end of a group's name, which is what differs: `group.43bbbe81cd2851c0.1` is `…c0.1`.
    private static func shortGroup(_ group: String) -> String {
        group.count > 6 ? "…" + String(group.suffix(4)) : group
    }

    /**
     * The App Groups in a bundle's `embedded.mobileprovision`, which the
     * signing tool puts there: what tvOS lets that bundle use. The profile is
     * a signed message wrapping a plist, which is read straight out of it.
     */
    private static func provisionedGroups(in bundle: URL) -> [String]? {
        guard let plist = profile(in: bundle) else { return nil }
        let entitlements = plist["Entitlements"] as? [String: Any]
        return entitlements?["com.apple.security.application-groups"] as? [String] ?? []
    }

    /**
     * The app's and the extension's bundle IDs, and the App ID the extension's
     * profile is for. tvOS only runs the extension if its ID starts with the
     * app's and the profile's App ID covers it (exactly, or by a `*`).
     */
    private static func identity(of appex: URL) -> String {
        let app = Bundle.main.bundleIdentifier ?? "?"
        let ext = Bundle(url: appex)?.bundleIdentifier ?? "?"
        guard let plist = profile(in: appex) else { return "app \(app), extension \(ext), no profile" }
        let entitlements = plist["Entitlements"] as? [String: Any]
        let appID = entitlements?["application-identifier"] as? String ?? "?"
        // Without the team prefix, which is what the bundle ID is matched against.
        let pattern = appID.split(separator: ".", maxSplits: 1).last.map(String.init) ?? appID
        let covered = pattern.hasSuffix("*") ? ext.hasPrefix(String(pattern.dropLast())) : ext == pattern
        let platforms = (plist["Platform"] as? [String])?.joined(separator: "/") ?? "?"
        return "app \(app), extension \(ext)\(ext.hasPrefix(app + ".") ? "" : " (not under the app's)"); "
            + "its profile is for \(pattern) on \(platforms)\(covered ? "" : ", which doesn't cover it")"
    }

    /// A bundle's `embedded.mobileprovision`, as its plist.
    private static func profile(in bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("embedded.mobileprovision")),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any]
        else { return nil }
        return plist
    }
}
