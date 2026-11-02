import TVServices

/**
 * The Top Shelf over AIOStreams' icon on the home screen: Continue Watching
 * and Next Up, from the list the app saved when the page last sent it.
 * Selecting a title opens its page in the app; Play plays it from where it
 * stopped. With nothing to show, tvOS shows the app's Top Shelf image.
 */
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        // The app writes a list, even an empty one, whenever the page sends it.
        guard TopShelfStore.hasList else {
            TopShelfStore.noteAsked(shown: 0)
            return completionHandler(notShared())
        }
        let items = TopShelfStore.load()
        let sections = [
            section("Continue Watching", items.filter(\.resumes)),
            section("Next Up", items.filter { !$0.resumes }),
        ].compactMap { $0 }
        TopShelfStore.noteAsked(shown: sections.reduce(0) { $0 + $1.items.count })
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    /**
     * No list where this extension can read it: the signing gave it no App
     * Group the app has, or the app hasn't been opened since it was installed.
     * Shows this extension's groups, to compare with the app menu's.
     */
    private func notShared() -> TVTopShelfContent {
        let groups = TopShelfStore.entitled
        let names = groups.isEmpty ? ["No App Groups in this extension's signature"] : groups
        let open = URL(string: "aiostreams://open")
        let items = names.enumerated().map { index, name -> TVTopShelfSectionedItem in
            let item = TVTopShelfSectionedItem(identifier: "group-\(index)")
            item.title = name
            item.imageShape = .hdtv
            if let open { item.displayAction = TVTopShelfAction(url: open) }
            return item
        }
        let section = TVTopShelfItemCollection(items: items)
        section.title = "No list from the app: open AIOStreams, or compare these groups with its menu"
        return TVTopShelfSectionedContent(sections: [section])
    }

    private func section(_ title: String, _ items: [TopShelfItem]) -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? {
        let shown = items.compactMap(shelfItem)
        guard !shown.isEmpty else { return nil }
        let section = TVTopShelfItemCollection(items: shown)
        section.title = title
        return section
    }

    private func shelfItem(_ item: TopShelfItem) -> TVTopShelfSectionedItem? {
        guard let play = item.playURL else { return nil }
        let shelf = TVTopShelfSectionedItem(identifier: item.id)
        shelf.title = item.label
        shelf.imageShape = .hdtv
        if let image = item.image.flatMap(URL.init(string:)) {
            shelf.setImageURL(image, for: .screenScale1x)
            shelf.setImageURL(image, for: .screenScale2x)
        }
        if let progress = item.progress { shelf.playbackProgress = progress }
        shelf.playAction = TVTopShelfAction(url: play)
        shelf.displayAction = TVTopShelfAction(url: item.detailsURL ?? play)
        return shelf
    }
}
