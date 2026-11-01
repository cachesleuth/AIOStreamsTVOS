import UIKit

/**
 * tvOS's own search keyboard, shown over the page for one of the page's text
 * fields. Each change goes straight into the page's field, so a search's
 * results update while typing. Menu, or moving down off the keyboard, closes
 * it and hands the remote back to the page.
 */
final class SearchKeyboard: NSObject, UISearchResultsUpdating, UISearchBarDelegate {
    /// What to present.
    let controller: UIViewController
    private let search: UISearchController
    private var text: String
    private var submitted = false
    private var closed = false
    private let onChange: (String) -> Void
    private let onClose: (_ submit: Bool) -> Void

    init(
        text: String,
        prompt: String,
        keyboardType: UIKeyboardType,
        onChange: @escaping (String) -> Void,
        onClose: @escaping (_ submit: Bool) -> Void
    ) {
        self.text = text
        self.onChange = onChange
        self.onClose = onClose
        let below = BelowKeyboard()
        search = UISearchController(searchResultsController: below)
        let container = Container(searchController: search)
        controller = container
        super.init()

        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        let bar = search.searchBar
        bar.delegate = self
        bar.text = text
        bar.placeholder = prompt
        bar.keyboardType = keyboardType
        bar.autocorrectionType = .no
        bar.autocapitalizationType = .none

        // Over the page, which shows through below the keyboard.
        container.modalPresentationStyle = .overFullScreen
        container.view.backgroundColor = .clear
        search.view.backgroundColor = .clear
        below.leave = { [weak container] in container?.dismiss(animated: true) }
        below.moved = { [weak container] in container?.view.setNeedsLayout() }
        container.disappeared = { [weak self] in self?.close() }
    }

    // MARK: UISearchResultsUpdating

    func updateSearchResults(for searchController: UISearchController) {
        let now = searchController.searchBar.text ?? ""
        guard now != text else { return }
        text = now
        onChange(now)
    }

    // MARK: UISearchBarDelegate

    /// A keyboard's return key, where there is one.
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        submitted = true
        controller.dismiss(animated: true)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        onClose(submitted)
    }
}

/**
 * Reports when it goes, however it was closed: Menu, moving off the keyboard,
 * or return. Draws a solid backdrop behind the keyboard, so the page doesn't
 * show through its keys; the page still shows below it, where the results are.
 */
private final class Container: UISearchContainerViewController {
    var disappeared: () -> Void = {}
    private let backdrop = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.backgroundColor = .systemBackground
        backdrop.isUserInteractionEnabled = false
        view.insertSubview(backdrop, at: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.sendSubviewToBack(backdrop)
        // Down to where the space below the keyboard starts; the whole screen until tvOS shows it.
        var bottom = view.bounds.maxY
        if let below = searchController.searchResultsController?.view, below.window != nil, !below.isHidden, below.alpha > 0 {
            let top = below.convert(below.bounds, to: view).minY
            if top > 0, top < view.bounds.maxY { bottom = top }
        }
        backdrop.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: bottom)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        disappeared()
    }
}

/**
 * The space below the keyboard: see-through, so the page's results show,
 * and one focus target across it. Moving down onto it leaves the keyboard
 * for the page, as moving to the results does in tvOS's own search.
 */
private final class BelowKeyboard: UIViewController {
    var leave: () -> Void = {}
    private let trap = FocusTrap()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        trap.frame = view.bounds
        trap.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        trap.reached = { [weak self] in self?.leave() }
        view.addSubview(trap)
    }

    /// Where it sits changed, so the backdrop above it follows.
    var moved: () -> Void = {}

    private var placed: CGRect?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Only when it really moved, so the two layouts can't keep starting each other.
        let now = view.convert(view.bounds, to: nil)
        guard now != placed else { return }
        placed = now
        moved()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        placed = nil
        moved()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        moved()
        // Only once the keyboard has taken focus, so it can't land here as the keyboard opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.trap.armed = true }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        trap.armed = false
    }
}

private final class FocusTrap: UIView {
    var reached: () -> Void = {}
    var armed = false

    override var canBecomeFocused: Bool { armed }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self { reached() }
    }
}
