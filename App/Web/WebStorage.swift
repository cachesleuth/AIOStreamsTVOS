import Foundation

/**
 * The app's copy of the page's localStorage, by origin, in the user defaults.
 * tvOS may drop a web view's data between launches, and the bridge script
 * puts back what is missing as the page starts. tvOS keeps an app's settings
 * well under a megabyte, so the copy stays small. As the working
 * aiostreams-tvos project keeps it.
 */
final class WebStorage {
    private static let key = "aiostreams.webStorageByOrigin"
    /// The UIWebView build's copy, which nothing reads any more.
    private static let oldKeys = ["aiostreams.webStorage", "aiostreams.clearWebStorage"]
    private static let maxChars = 350_000
    private static let maxValue = 100_000

    private var items: [String: [String: String]] = [:]

    init() {
        for old in Self.oldKeys { UserDefaults.standard.removeObject(forKey: old) }
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
        for (origin, value) in saved {
            guard let entries = value as? [String: Any] else { continue }
            items[origin] = entries.compactMapValues { $0 as? String }
        }
    }

    /// For the bridge script's `__STORAGE__`.
    var json: String {
        JSON.string(items) ?? "null"
    }

    var keyCount: Int {
        items.values.reduce(0) { $0 + $1.count }
    }

    private var size: Int {
        items.values.reduce(0) { total, entries in
            entries.reduce(total) { $0 + $1.key.count + $1.value.count }
        }
    }

    /// A `tvos-storage` message from the page.
    func apply(_ message: Message) {
        guard let origin = message.text("origin"), !origin.isEmpty else { return }
        var entries = items[origin] ?? [:]
        if message.flag("clear") == true {
            entries.removeAll()
        } else {
            guard let key = message.text("key") else { return }
            entries.removeValue(forKey: key)
            items[origin] = entries
            if let value = message.text("value"), value.count <= Self.maxValue,
               size + key.count + value.count <= Self.maxChars {
                entries[key] = value
            }
        }
        items[origin] = entries
        scheduleSave()
    }

    private var pendingSave: DispatchWorkItem?

    /// Once a burst of changes settles.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        UserDefaults.standard.set(items, forKey: Self.key)
    }

    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        items.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
