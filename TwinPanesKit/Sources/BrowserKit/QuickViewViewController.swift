import AppKit
import TwinPanesCore
import WorkspaceKit

/// View controller for `QuickViewItem` (`docs/plans/M7.md`, D-e).
@MainActor
final class QuickViewViewController: NSViewController, CommandScopeProviding, NSMenuItemValidation {
    weak var item: QuickViewItem?

    private let titleLabel = NSTextField(labelWithString: "Quick View")
    private let unsavedBadge = NSBox()
    private let modeControl = NSSegmentedControl()
    private let formatButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var shownModes: [PreviewMode] = []
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let pinButton = NSButton(title: "Keep", target: nil, action: nil)
    private let bodyContainer = NSView()
    private let placeholderStack = NSStackView()
    private let placeholderIcon = NSImageView()
    private let placeholderTitle = NSTextField(labelWithString: "")
    private let placeholderSubtitle = NSTextField(labelWithString: "")

    private var quickLookHost: QuickLookHostView?
    private(set) var structuredController: StructuredTextViewController?
    private var hexViewer: (any HexPreviewing)?

    var commandScopes: [BindingScope] { [.item(.quickView)] }
    var hexShowsUnsavedEdits: Bool { hexViewer?.showsUnsavedEdits ?? false }

    var preferredResponder: NSView? {
        guard let viewIfLoaded else { return nil }
        if item?.activeMode == .hex,
            let hexView = hexViewer?.viewController.view,
            !hexView.isHidden
        {
            if hexView.acceptsFirstResponder { return hexView }
            if let sub = hexView.subviews.first(where: { !$0.isHidden && $0.acceptsFirstResponder })
            {
                return sub
            }
        }
        if let mode = item?.activeMode, mode == .pretty || mode == .text,
            let structured = structuredController, !structured.view.isHidden
        {
            return structured.textView
        }
        if item?.activeMode != .hex,
            let ql = quickLookHost,
            !ql.isHidden,
            ql.acceptsFirstResponder
        {
            return ql
        }
        return viewIfLoaded
    }

    init(item: QuickViewItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = QuickViewRootView()
        root.setAccessibilityIdentifier("quickView")
        view = root

        configureHeaderControls()
        configurePlaceholder()

        let header = NSStackView(views: [
            titleLabel, unsavedBadge, formatButton, modeControl, editButton, pinButton,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox(frame: NSRect(x: 0, y: 0, width: 100, height: 1))
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(divider)
        root.addSubview(bodyContainer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            bodyContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        syncPinButton()
        syncView()
    }

    private func configureHeaderControls() {
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let badgeLabel = NSTextField(labelWithString: "Includes unsaved edits")
        badgeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        badgeLabel.textColor = .labelColor
        badgeLabel.lineBreakMode = .byTruncatingTail
        badgeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        unsavedBadge.boxType = .custom
        unsavedBadge.borderWidth = 0
        unsavedBadge.cornerRadius = 8
        unsavedBadge.fillColor = NSColor.systemOrange.withAlphaComponent(0.2)
        unsavedBadge.contentViewMargins = .zero
        unsavedBadge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        unsavedBadge.setAccessibilityIdentifier("quickViewUnsavedBadge")
        unsavedBadge.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: unsavedBadge.topAnchor, constant: 2),
            badgeLabel.bottomAnchor.constraint(equalTo: unsavedBadge.bottomAnchor, constant: -2),
            badgeLabel.leadingAnchor.constraint(equalTo: unsavedBadge.leadingAnchor, constant: 7),
            badgeLabel.trailingAnchor.constraint(
                equalTo: unsavedBadge.trailingAnchor, constant: -7),
        ])

        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.setAccessibilityIdentifier("quickViewModeControl")

        formatButton.controlSize = .small
        formatButton.bezelStyle = .roundRect
        formatButton.menu?.autoenablesItems = false
        formatButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        formatButton.setAccessibilityIdentifier("quickViewFormatButton")

        editButton.controlSize = .small
        editButton.bezelStyle = .push
        editButton.target = self
        editButton.action = #selector(browserEdit(_:))
        editButton.setAccessibilityIdentifier("quickViewEditButton")

        pinButton.controlSize = .small
        pinButton.bezelStyle = .push
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.target = self
        pinButton.action = #selector(pinClicked(_:))
        pinButton.setAccessibilityIdentifier("quickViewPinButton")
        pinButton.isHidden = !(item?.isFollowing ?? true)
    }

    private func configurePlaceholder() {
        placeholderIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 32, weight: .regular)
        placeholderIcon.contentTintColor = .secondaryLabelColor
        placeholderTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        placeholderTitle.textColor = .secondaryLabelColor
        placeholderSubtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        placeholderSubtitle.textColor = .tertiaryLabelColor
        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 6
        placeholderStack.addArrangedSubview(placeholderIcon)
        placeholderStack.addArrangedSubview(placeholderTitle)
        placeholderStack.addArrangedSubview(placeholderSubtitle)
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(placeholderStack)
        NSLayoutConstraint.activate([
            placeholderStack.centerXAnchor.constraint(equalTo: bodyContainer.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: bodyContainer.centerYAnchor),
        ])
    }

    func syncView() {
        guard isViewLoaded, let item else { return }
        syncHeader()

        guard let entry = item.currentEntry else {
            clearViewers()
            showPlaceholder(symbol: "eye", title: "No Selection", subtitle: "")
            return
        }
        if entry.isDirectory {
            clearViewers()
            showPlaceholder(symbol: "folder", title: entry.name, subtitle: "Folder")
            return
        }
        if entry.isPackage {
            clearViewers()
            showPlaceholder(symbol: "shippingbox", title: entry.name, subtitle: "Package")
            return
        }
        if entry.isBrokenSymbolicLink {
            clearViewers()
            showPlaceholder(
                symbol: "exclamationmark.triangle", title: entry.name,
                subtitle: "Broken symbolic link — target not found")
            return
        }

        switch item.activeMode {
        case .pretty, .text:
            placeholderStack.isHidden = true
            hideQuickLook()
            hideHex()
            let structured = ensureStructuredController()
            structured.view.isHidden = false
            structured.show(
                entry.url, format: item.classification.structuredFormat,
                pretty: item.activeMode == .pretty, scope: item.currentScope)
        case .preview:
            if item.isDataless {
                clearViewers()
                showPlaceholder(
                    symbol: "icloud.and.arrow.down", title: entry.name,
                    subtitle: "In iCloud — not downloaded")
                return
            }
            placeholderStack.isHidden = true
            hideStructured()
            hideHex()
            let host = ensureQuickLookHost(for: item)
            host.isHidden = false
            host.show(entry.url, scope: item.currentScope)
        case .hex:
            placeholderStack.isHidden = true
            hideQuickLook()
            hideStructured()
            let viewer = ensureHexViewer(for: item)
            viewer.viewController.view.isHidden = false
            viewer.show(entry.url, scope: item.currentScope)
        }
    }

    func syncHeader() {
        guard isViewLoaded, let item else { return }
        titleLabel.stringValue = item.title
        let isRegularFile =
            item.currentEntry.map { !$0.isDirectory && !$0.isPackage && !$0.isBrokenSymbolicLink }
            ?? false
        unsavedBadge.isHidden = !(isRegularFile && item.showsUnsavedEdits)
        modeControl.isEnabled = isRegularFile
        syncModeControl(item)
        syncFormatButton(item, isRegularFile: isRegularFile)
        editButton.isEnabled = isRegularFile
    }

    private static func label(for mode: PreviewMode) -> String {
        switch mode {
        case .pretty: "Pretty"
        case .text: "Text"
        case .preview: "Preview"
        case .hex: "Hex"
        }
    }

    private func syncModeControl(_ item: QuickViewItem) {
        let modes = item.classification.availableModes
        if modes != shownModes {
            shownModes = modes
            modeControl.segmentCount = modes.count
            for (index, mode) in modes.enumerated() {
                modeControl.setLabel(Self.label(for: mode), forSegment: index)
                modeControl.setWidth(0, forSegment: index)
            }
        }
        modeControl.selectedSegment = modes.firstIndex(of: item.activeMode) ?? -1
        modeControl.isHidden = modes.count <= 1
    }

    private func syncFormatButton(_ item: QuickViewItem, isRegularFile: Bool) {
        formatButton.isHidden = !isRegularFile
        guard isRegularFile else { return }
        let ext = item.currentURL?.pathExtension ?? ""
        let current = item.effectiveOverride
        let currentTitle =
            switch item.activeMode {
            case .pretty: item.classification.structuredFormat.map(Self.title(for:)) ?? "Format"
            default: Self.label(for: item.activeMode)
            }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: currentTitle, action: nil, keyEquivalent: "")
        addFormatItem("Auto", .transient(nil), isOn: current == nil, to: menu)
        let choices: [(String, PreviewFormatOverride)] =
            StructuredFormat.allCases.map { (Self.title(for: $0), .structured($0)) }
            + [("Plain Text", .plainText), ("Preview", .preview), ("Hex", .hex)]
        for (title, override) in choices {
            addFormatItem(title, .transient(override), isOn: current == override, to: menu)
        }
        if !ext.isEmpty {
            menu.addItem(.separator())
            let remember = addFormatItem("Remember for .\(ext)", .remember(current), to: menu)
            remember.isEnabled = current != nil
            addFormatItem("Reset .\(ext) to Auto", .remember(nil), to: menu)
        }
        formatButton.menu = menu
    }

    private static func title(for format: StructuredFormat) -> String {
        switch format {
        case .json: "JSON"
        case .xml: "XML"
        case .plist: "Plist"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .csv: "CSV"
        case .tsv: "TSV"
        case .properties: "Properties"
        }
    }

    @discardableResult
    private func addFormatItem(
        _ title: String, _ action: FormatMenuAction, isOn: Bool = false, to menu: NSMenu
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: title, action: #selector(formatChosen(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = action
        menuItem.state = isOn ? .on : .off
        menu.addItem(menuItem)
        return menuItem
    }

    func syncPinButton() {
        guard isViewLoaded, let item else { return }
        pinButton.isHidden = !item.isFollowing
        pinButton.state = item.isPinned ? .on : .off
        pinButton.toolTip =
            item.isPinned
            ? "Keeping this file — click to follow selection"
            : "Keep this file open (stop following selection)"
    }

    func tearDown() {
        structuredController?.onLoadFinished = nil
        structuredController?.show(nil, format: nil, pretty: false, scope: nil)
        structuredController?.view.removeFromSuperview()
        structuredController?.removeFromParent()
        structuredController = nil
        quickLookHost?.close()
        quickLookHost?.removeFromSuperview()
        quickLookHost = nil
        hexViewer?.onStateChange = nil
        hexViewer?.show(nil, scope: nil)
        hexViewer?.viewController.view.removeFromSuperview()
        hexViewer?.viewController.removeFromParent()
        hexViewer = nil
    }

    private func ensureQuickLookHost(for item: QuickViewItem) -> QuickLookHostView {
        if let quickLookHost { return quickLookHost }
        let host = item.makeQuickLook()
        embedBodyView(host)
        quickLookHost = host
        return host
    }

    private func ensureStructuredController() -> StructuredTextViewController {
        if let structuredController { return structuredController }
        let controller = StructuredTextViewController()
        addChild(controller)
        embedBodyView(controller.view)
        structuredController = controller
        return controller
    }

    private func ensureHexViewer(for item: QuickViewItem) -> any HexPreviewing {
        if let hexViewer { return hexViewer }
        let viewer = item.viewerFactory.makeHexViewer(style: .regular)
        viewer.onStateChange = { [weak self] in self?.item?.hexStateChanged() }
        addChild(viewer.viewController)
        embedBodyView(viewer.viewController.view)
        hexViewer = viewer
        return viewer
    }

    private func embedBodyView(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            subview.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
    }

    private func clearViewers() {
        hideQuickLook()
        hideStructured()
        hideHex()
    }

    private func hideQuickLook() {
        quickLookHost?.isHidden = true
        quickLookHost?.show(nil, scope: nil)
    }

    private func hideStructured() {
        structuredController?.view.isHidden = true
        structuredController?.show(nil, format: nil, pretty: false, scope: nil)
    }

    private func hideHex() {
        hexViewer?.viewController.view.isHidden = true
        hexViewer?.show(nil, scope: nil)
    }

    private func showPlaceholder(symbol: String, title: String, subtitle: String) {
        placeholderIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        placeholderTitle.stringValue = title
        placeholderSubtitle.stringValue = subtitle
        placeholderSubtitle.isHidden = subtitle.isEmpty
        placeholderStack.isHidden = false
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let modes = item?.classification.availableModes ?? []
        guard modes.indices.contains(sender.selectedSegment) else { return }
        item?.selectMode(modes[sender.selectedSegment])
        if let responder = preferredResponder {
            view.window?.makeFirstResponder(responder)
        }
    }

    @objc private func formatChosen(_ sender: NSMenuItem) {
        switch sender.representedObject as? FormatMenuAction {
        case .transient(let override): item?.setTransientOverride(override)
        case .remember(let override): item?.rememberOverrideForCurrentExtension(override)
        case nil: break
        }
    }

    @objc private func pinClicked(_ sender: NSButton) {
        item?.togglePin()
    }

    /// F4 / ⌃⌘E / Edit button: opens the displayed regular file in the editor; beeps on
    /// folders, packages, broken symlinks, or empty selection.
    @objc func browserEdit(_ sender: Any?) {
        guard let item, let entry = item.currentEntry,
            !entry.isDirectory, !entry.isPackage, !entry.isBrokenSymbolicLink
        else {
            NSSound.beep()
            return
        }
        item.onEdit(entry.url, item.currentScope)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(browserEdit(_:)):
            guard let entry = item?.currentEntry else { return false }
            return !entry.isDirectory && !entry.isPackage && !entry.isBrokenSymbolicLink
        default:
            return true
        }
    }
}

private enum FormatMenuAction {
    case transient(PreviewFormatOverride?)
    case remember(PreviewFormatOverride?)
}

private final class QuickViewRootView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
