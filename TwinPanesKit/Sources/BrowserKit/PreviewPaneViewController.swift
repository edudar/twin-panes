import AppKit
import QuickLookUI
import TwinPanesCore
import UniformTypeIdentifiers
import WorkspaceKit

/// Collapsible trailing preview pane showing Quick Look or read-only hex above O(1) file metadata
/// (`docs/plans/M7.md`, D-d).
@MainActor
public final class PreviewPaneViewController: NSViewController {
    private enum Target {
        case none, single(URL, SecurityScope?), multiple(Int, UInt64)
        var key: String {
            switch self {
            case .none: ""
            case .single(let url, _): "s:\(url.standardizedFileURL.path)"
            case .multiple(let count, let bytes): "m:\(count):\(bytes)"
            }
        }
        var withoutScope: Target {
            if case .single(let url, _) = self { .single(url, nil) } else { self }
        }
    }

    private let viewerFactory: any HexViewerFactory
    private weak var sessions: SessionRegistry?
    private let debounce: Duration
    private let makeQuickLook: () -> QuickLookHostView
    private let readMetadata: @Sendable (URL) throws -> FileMetadata
    private let metadataQueue = DispatchQueue(
        label: "com.twinpanes.previewPane.metadata", qos: .userInitiated)

    let modeControl = NSSegmentedControl(
        labels: ["Quick Look", "Hex"], trackingMode: .selectOne, target: nil, action: nil)
    let metadataView = PreviewMetadataView()
    let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let previewContainer = NSView()
    private var quickLookHost: QuickLookHostView?
    private var hexViewer: (any HexPreviewing)?

    public private(set) var activeMode: PreviewMode = .quickLook
    private var isActive = true
    private var isTornDown = false
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var latestTarget: Target = .none
    private var displayedTarget: Target = .none
    private var displayedMetadata: FileMetadata?
    private var currentScope: SecurityScope?
    private var userModeOverride: PreviewMode?
    var onLoadFinished: (() -> Void)?

    /// Creates a preview pane using `viewerFactory` for compact hex previews and `sessions` for
    /// live dirty-session tracking.
    public convenience init(
        viewerFactory: any HexViewerFactory, sessions: SessionRegistry? = nil,
        debounce: Duration = .milliseconds(40)
    ) {
        self.init(
            viewerFactory: viewerFactory, sessions: sessions, debounce: debounce,
            makeQuickLook: { QuickLookHostView(style: .compact) })
    }

    init(
        viewerFactory: any HexViewerFactory, sessions: SessionRegistry? = nil,
        debounce: Duration = .milliseconds(40), makeQuickLook: @escaping () -> QuickLookHostView,
        readMetadata: @escaping @Sendable (URL) throws -> FileMetadata = {
            try FileMetadata.read(url: $0)
        }
    ) {
        self.viewerFactory = viewerFactory
        self.sessions = sessions
        self.debounce = debounce
        self.makeQuickLook = makeQuickLook
        self.readMetadata = readMetadata
        super.init(nibName: nil, bundle: nil)
        configureControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("previewPane")
        let header = NSStackView(views: [modeControl, NSView()])
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: previewContainer.leadingAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(
                equalTo: previewContainer.trailingAnchor, constant: -12),
        ])

        let splitView = NSSplitView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(previewContainer)
        splitView.addArrangedSubview(metadataView)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        let stack = NSStackView(views: [header, splitView])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        pinEdges(stack, in: root)
        view = root
    }

    /// Updates the preview pane for the current browser selection.
    public func show(entries: [DirectoryEntry], scope: SecurityScope?) {
        let valid = entries.filter { $0.name != ".." }
        if valid.isEmpty { return enqueue(.none) }
        if valid.count == 1, let entry = valid.first { return enqueue(.single(entry.url, scope)) }
        enqueue(.multiple(valid.count, valid.reduce(0) { $0 &+ ($1.size ?? 0) }))
    }

    /// Updates the preview pane for a single file URL, or clears it when `url` is `nil`.
    public func show(file url: URL?, scope: SecurityScope?) {
        enqueue(url.map { .single($0, scope) } ?? .none)
    }

    /// Suspends loading and releases preview resources when collapsed (`false`), or resumes and
    /// immediately loads the latest target when shown (`true`).
    public func setActive(_ active: Bool) {
        guard !isTornDown, active != isActive else { return }
        isActive = active
        guard active else {
            cancelPending()
            latestTarget = latestTarget.withoutScope
            displayedTarget = .none
            userModeOverride = nil
            return clearDisplayedContent()
        }
        loadNow(latestTarget)
    }

    /// Releases Quick Look XPC resources, hex viewer state, and pending background tasks.
    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        isActive = false
        cancelPending()
        latestTarget = .none
        displayedTarget = .none
        clearDisplayedContent()
        quickLookHost?.close()
        quickLookHost = nil
        hexViewer = nil
    }

    @objc func modeChanged(_ sender: NSSegmentedControl) {
        guard displayedMetadata != nil else { return }
        userModeOverride = sender.selectedSegment == 1 ? .hex : .quickLook
        renderSingleTarget()
    }

    private func configureControls() {
        modeControl.selectedSegment = 0
        modeControl.controlSize = .small
        modeControl.isEnabled = false
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.setAccessibilityIdentifier("previewModeControl")

        placeholderLabel.alignment = .center
        placeholderLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.stringValue = "No Selection"
        metadataView.showMessage("No Selection")
    }

    private func cancelPending() {
        debounceTask?.cancel()
        debounceTask = nil
        generation += 1
    }

    private func enqueue(_ target: Target) {
        guard !isTornDown else { return }
        guard isActive else { return latestTarget = target.withoutScope }
        latestTarget = target
        cancelPending()
        let expected = generation
        let delay = debounce
        debounceTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) } else { await Task.yield() }
            guard let self, !Task.isCancelled, self.generation == expected, self.isActive
            else { return }
            self.loadNow(target)
        }
    }

    private func loadNow(_ target: Target) {
        if target.key != displayedTarget.key { userModeOverride = nil }
        displayedTarget = target
        switch target {
        case .none:
            clearDisplayedContent(placeholder: "No Selection")
            metadataView.showMessage("No Selection")
            onLoadFinished?()
        case .multiple(let count, let totalBytes):
            let title = count == 1 ? "1 item selected" : "\(count) items selected"
            clearDisplayedContent(placeholder: title)
            metadataView.showMultiSelection(count: count, totalBytes: totalBytes)
            onLoadFinished?()
        case .single(let url, let scope):
            let expected = generation
            currentScope = scope
            metadataQueue.async { [weak self, readMetadata] in
                let result = withExtendedLifetime(scope) { Result { try readMetadata(url) } }
                Task { @MainActor [weak self] in
                    guard let self, !self.isTornDown, self.isActive, self.generation == expected
                    else { return }
                    self.finishLoadingSingle(url: url, scope: scope, result: result)
                }
            }
        }
    }

    private func finishLoadingSingle(
        url: URL, scope: SecurityScope?, result: Result<FileMetadata, Error>
    ) {
        switch result {
        case .failure(let error):
            clearDisplayedContent(placeholder: "Can’t preview “\(url.lastPathComponent)”")
            metadataView.showMessage(error.localizedDescription)
        case .success(let metadata):
            displayedMetadata = metadata
            currentScope = scope
            metadataView.show(metadata)
            renderSingleTarget()
        }
        onLoadFinished?()
    }

    private func renderSingleTarget() {
        guard let metadata = displayedMetadata else { return }
        let utType = UTType(metadata.typeIdentifier) ?? .data
        let canUseHex =
            !metadata.isDirectory && !metadata.isPackage && !metadata.isDataless
            && metadata.size != nil
        let defaultMode = PreviewClassifier.defaultMode(
            for: utType, isDirectory: metadata.isDirectory, isPackage: metadata.isPackage,
            isDataless: metadata.isDataless)
        activeMode = canUseHex ? (userModeOverride ?? defaultMode) : .quickLook
        modeControl.isEnabled = canUseHex
        modeControl.selectedSegment = activeMode == .hex ? 1 : 0
        placeholderLabel.isHidden = true

        let showQL = activeMode == .quickLook
        hexViewer?.viewController.view.isHidden = showQL
        quickLookHost?.isHidden = !showQL
        if showQL {
            hexViewer?.show(nil, scope: nil)
            ensureQuickLookHost().show(metadata.url, scope: currentScope)
        } else {
            quickLookHost?.show(nil, scope: nil)
            ensureHexViewer().show(metadata.url, scope: currentScope)
        }
    }

    private func clearDisplayedContent(placeholder: String? = nil) {
        displayedMetadata = nil
        currentScope = nil
        modeControl.isEnabled = false
        modeControl.selectedSegment = 0
        activeMode = .quickLook
        quickLookHost?.isHidden = true
        hexViewer?.viewController.view.isHidden = true
        quickLookHost?.show(nil, scope: nil)
        hexViewer?.show(nil, scope: nil)
        if let placeholder {
            placeholderLabel.stringValue = placeholder
            placeholderLabel.isHidden = false
        } else {
            placeholderLabel.isHidden = true
            metadataView.clear()
        }
    }

    private func ensureQuickLookHost() -> QuickLookHostView {
        if let quickLookHost { return quickLookHost }
        let host = makeQuickLook()
        pinEdges(host, in: previewContainer)
        quickLookHost = host
        return host
    }

    private func ensureHexViewer() -> any HexPreviewing {
        if let hexViewer { return hexViewer }
        let viewer = viewerFactory.makeHexViewer(style: .compact)
        addChild(viewer.viewController)
        pinEdges(viewer.viewController.view, in: previewContainer)
        hexViewer = viewer
        return viewer
    }

    private func pinEdges(_ child: NSView, in parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}
