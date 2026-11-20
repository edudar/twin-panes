import AppKit

/// Minimal per-panel tab bar for M0: one button per tab with a dirty dot, a close
/// button, and selection highlight. The real tab bar (drag between panels, overflow)
/// is M5.
@MainActor
final class TabBarView: NSView {
    var onSelect: ((ItemID) -> Void)?
    var onClose: ((ItemID) -> Void)?

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        setAccessibilityRole(.tabGroup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(items: [any WorkspaceItem], selected: ItemID?, isActivePanel: Bool) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for item in items {
            stack.addArrangedSubview(
                tabView(for: item, isSelected: item.id == selected, isActive: isActivePanel))
        }
    }

    private func tabView(
        for item: any WorkspaceItem, isSelected: Bool, isActive: Bool
    )
        -> NSView
    {
        let title = (item.isDirty ? "• " : "") + item.title
        let select = TabButton(title: title, target: self, action: #selector(tabClicked(_:)))
        select.itemID = item.id
        select.bezelStyle = .accessoryBarAction
        select.showsBorderOnlyWhileMouseInside = !isSelected
        select.state = isSelected ? .on : .off
        select.setButtonType(.pushOnPushOff)
        select.font = isSelected && isActive ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        select.setAccessibilityRole(.radioButton)

        let close = TabButton(
            title: "×", target: self, action: #selector(closeClicked(_:)))
        close.itemID = item.id
        close.bezelStyle = .accessoryBarAction
        close.showsBorderOnlyWhileMouseInside = true
        close.setAccessibilityLabel("Close \(item.title)")

        let tab = NSStackView(views: [select, close])
        tab.spacing = 0
        return tab
    }

    @objc private func tabClicked(_ sender: TabButton) {
        if let id = sender.itemID { onSelect?(id) }
    }

    @objc private func closeClicked(_ sender: TabButton) {
        if let id = sender.itemID { onClose?(id) }
    }
}

private final class TabButton: NSButton {
    var itemID: ItemID?
}
