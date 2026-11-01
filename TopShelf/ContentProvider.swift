import TVServices

/**
 * The Top Shelf over AIOStreams' icon on the home screen: Continue Watching
 * and Next Up, from the list the app saved when the page last sent it.
 * Selecting a title opens its page in the app; Play plays it from where it
 * stopped. With nothing to show, tvOS shows the app's Top Shelf image.
 */
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let items = TopShelfStore.load()
        let sections = [
            section("Continue Watching", items.filter(\.resumes)),
            section("Next Up", items.filter { !$0.resumes }),
        ].compactMap { $0 }
        TopShelfStore.noteAsked(shown: sections.reduce(0) { $0 + $1.items.count })
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
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
