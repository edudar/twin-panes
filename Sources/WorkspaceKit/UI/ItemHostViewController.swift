import AppKit

/// Shows one item's view controller at a time. Used for each slot's content and for
/// the zoom overlay. Attaching an item that another host is showing moves it here
/// without recreating it (re-parenting, PLAN.md §4.8).
@MainActor
final class ItemHostViewController: NSViewController {
    private(set) var current: (any WorkspaceItem)?

    override func loadView() {
        view = NSView()
    }

    func display(_ item: (any WorkspaceItem)?) {
        if let current, current.id == item?.id, current.viewController.parent === self {
            return
        }
        if let current, current.viewController.parent === self {
            current.viewController.view.removeFromSuperview()
            current.viewController.removeFromParent()
        }
        current = item
        guard let item else { return }
        let child = item.viewController
        child.removeFromParent()
        addChild(child)
        let childView = child.view
        childView.removeFromSuperview()
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Releases the item if this host still shows it.
    func release() { display(nil) }
}
