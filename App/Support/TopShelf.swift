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
            NSLog("[top-shelf] no App Group container for %@; is the app signed with it?", TopShelfStore.group)
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
        let groups = TopShelfStore.entitled
        let container = TopShelfStore.folder != nil
        let plugins = Bundle.main.builtInPlugInsURL
        let bundled = plugins.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("AIOStreamsTopShelf.appex").path)
        } ?? false
        let time = { (date: Date) in DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium) }
        let page = received.map {
            "\($0.count) titles at \(time($0.date))\($0.saved ? "" : ", not saved")"
        } ?? "nothing yet"
        let asked = TopShelfStore.lastAsked().map {
            "\(DateFormatter.localizedString(from: $0.date, dateStyle: .short, timeStyle: .medium)), showed \($0.shown)"
        } ?? "never"
        return [
            "Top Shelf: App Group \(groups.isEmpty ? "missing from the signature" : groups.joined(separator: ", "))"
                + (container ? "" : " (no container)"),
            "Top Shelf extension: \(bundled ? "in the app" : "missing"); tvOS last asked it: \(asked)",
            "Top Shelf list from the page: \(page); saved: \(TopShelfStore.load().count)",
        ]
    }
}
