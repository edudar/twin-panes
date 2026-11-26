import AppKit

/// The function-key bar along the bottom of the main window (docs/plans/M6.md, D-b, as
/// restyled in D51): the F-keys that run something for what has focus, each drawn as its
/// key name and the command's title, with no button bezel, so it reads like a toolbar
/// rather than a row of buttons. Labels come from the command registry; a key sends that
/// command through the responder chain and is enabled by the same validation as the
/// menu (PLAN.md §4.11).
@MainActor
public final class FunctionKeyBar: NSView {
    public static let keyCount = 10

    private let dispatcher: CommandDispatcher
    private let buttons: [NSButton]
    /// The command each key runs from the current focus.
    private var commands: [Command?] = Array(repeating: nil, count: keyCount)

    public init(dispatcher: CommandDispatcher) {
        self.dispatcher = dispatcher
        buttons = (1...Self.keyCount).map { number in
            let button = NSButton(title: "", target: nil, action: nil)
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.tag = number
            button.isHidden = true
            button.setAccessibilityIdentifier("functionKey\(number)")
            return button
        }
        super.init(frame: .zero)
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 18
        // A hidden key takes no room, so the keys shown sit together on the left.
        stack.detachesHiddenViews = true
        for view in [separator, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
        for button in buttons {
            button.target = self
            button.action = #selector(keyClicked(_:))
        }
        setAccessibilityIdentifier("functionKeyBar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// AppKit updates each window after every event; the bar follows, so a key's label
    /// and state track focus and selection without each view telling it.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didUpdateNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidUpdate(_:)), name: NSWindow.didUpdateNotification,
            object: window)
        update(for: window)
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        guard !isHidden else { return }
        update(for: notification.object as? NSWindow)
    }

    /// Labels, enables and shows each key for what has focus in `window`.
    public func update(for window: NSWindow?) {
        let chain = FocusChain.scopes(in: window)
        for (index, button) in buttons.enumerated() {
            let candidates = dispatcher.registry.candidates(
                for: .function(index + 1), chain: chain)
            let handled = candidates.first {
                CommandDispatcher.target(for: $0.action, in: window) != nil
            }
            commands[index] = handled
            if button.isHidden != (handled == nil) { button.isHidden = handled == nil }
            guard let handled else { continue }
            let enabled =
                CommandDispatcher.target(for: handled.action, in: window).map {
                    CommandDispatcher.isEnabled(handled.action, target: $0)
                } ?? false
            if button.isEnabled != enabled { button.isEnabled = enabled }
            let title = Self.title(key: index + 1, command: handled.title, isEnabled: enabled)
            if button.attributedTitle != title { button.attributedTitle = title }
        }
    }

    /// "F5 Copy…": the key name in the secondary colour and semibold, then the title.
    /// A borderless button doesn't dim its title when disabled, so the colours do.
    private static func title(
        key number: Int, command: String, isEnabled: Bool
    )
        -> NSAttributedString
    {
        let size = NSFont.smallSystemFontSize
        let title = NSMutableAttributedString(
            string: "F\(number) ",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
                .foregroundColor: isEnabled ? NSColor.secondaryLabelColor : .tertiaryLabelColor,
            ])
        title.append(
            NSAttributedString(
                string: command,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size),
                    .foregroundColor: isEnabled ? NSColor.labelColor : .tertiaryLabelColor,
                ]))
        return title
    }

    /// The label shown for F`number`: its command's title, or "" when it runs nothing
    /// from the current focus.
    func title(ofKey number: Int) -> String { commands[number - 1]?.title ?? "" }

    func isEnabled(key number: Int) -> Bool { buttons[number - 1].isEnabled }

    func isShown(key number: Int) -> Bool { !buttons[number - 1].isHidden }

    /// The colour of F`number`'s command title.
    func labelColor(ofKey number: Int) -> NSColor? {
        let title = buttons[number - 1].attributedTitle
        guard title.length > 0 else { return nil }
        return title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil)
            as? NSColor
    }

    /// Clicks F`number`'s button.
    func press(key number: Int) { buttons[number - 1].performClick(nil) }

    @objc private func keyClicked(_ sender: NSButton) {
        guard let command = commands[sender.tag - 1] else { return NSSound.beep() }
        if !dispatcher.perform(command, in: window) { NSSound.beep() }
    }
}
