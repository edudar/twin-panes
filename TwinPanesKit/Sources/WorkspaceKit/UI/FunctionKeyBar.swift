import AppKit

/// The function-key bar along the bottom of the main window (docs/plans/M6.md, D-b): F1
/// to F10, each labelled with the command that key runs for what has focus. Labels come
/// from the command registry; a key's button sends that command through the responder
/// chain and is enabled by the same validation as the menu (PLAN.md §4.11).
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
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = number
            button.setAccessibilityIdentifier("functionKey\(number)")
            return button
        }
        super.init(frame: .zero)
        let stack = NSStackView(views: buttons)
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    /// Labels and enables each key for what has focus in `window`.
    public func update(for window: NSWindow?) {
        let chain = FocusChain.scopes(in: window)
        for (index, button) in buttons.enumerated() {
            let candidates = dispatcher.registry.candidates(
                for: .function(index + 1), chain: chain)
            let handled = candidates.first {
                CommandDispatcher.target(for: $0.action, in: window) != nil
            }
            commands[index] = handled
            let title = handled.map { "F\(index + 1) \($0.title)" } ?? "F\(index + 1)"
            if button.title != title { button.title = title }
            let enabled =
                handled.flatMap { command in
                    CommandDispatcher.target(for: command.action, in: window).map {
                        CommandDispatcher.isEnabled(command.action, target: $0)
                    }
                } ?? false
            if button.isEnabled != enabled { button.isEnabled = enabled }
        }
    }

    /// The label shown for F`number`: its command's title, or "" when it runs nothing
    /// from the current focus.
    func title(ofKey number: Int) -> String { commands[number - 1]?.title ?? "" }

    func isEnabled(key number: Int) -> Bool { buttons[number - 1].isEnabled }

    /// Clicks F`number`'s button.
    func press(key number: Int) { buttons[number - 1].performClick(nil) }

    @objc private func keyClicked(_ sender: NSButton) {
        guard let command = commands[sender.tag - 1] else { return NSSound.beep() }
        if !dispatcher.perform(command, in: window) { NSSound.beep() }
    }
}
