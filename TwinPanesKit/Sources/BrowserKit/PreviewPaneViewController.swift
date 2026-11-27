import AppKit
import QuickLookUI
import TwinPanesCore

/// Collapsible trailing preview pane showing a compact Quick Look preview above O(1) file metadata
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

    private let debounce: Duration
    private let makeQuickLook: () -> QuickLookHostView
    private let readMetadata: @Sendable (URL) throws -> FileMetadata
    private let metadataQueue = DispatchQueue(
        label: "com.twinpanes.previewPane.metadata", qos: .userInitiated)

    let metadataView = PreviewMetadataView()
    let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    let previewContainer = NSView()
    private let splitView = NSSplitView()
    private var hasPlacedDivider = false
    private var quickLookHost: QuickLookHostView?

    private var isActive = true
    private var isTornDown = false
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var latestTarget: Target = .none
    private var displayedTarget: Target = .none
    private var currentScope: SecurityScope?
    var onLoadFinished: (() -> Void)?

    /// Creates a Finder-style preview pane showing Quick Look above O(1) file metadata.
    public convenience init(debounce: Duration = .milliseconds(40)) {
        self.init(
            debounce: debounce, makeQuickLook: { QuickLookHostView(style: .compact) })
    }

    init(
        debounce: Duration = .milliseconds(40), makeQuickLook: @escaping () -> QuickLookHostView,
        readMetadata: @escaping @Sendable (URL) throws -> FileMetadata = {
            try FileMetadata.read(url: $0)
        }
    ) {
        self.debounce = debounce
        self.makeQuickLook = makeQuickLook
        self.readMetadata = readMetadata
        super.init(nibName: nil, bundle: nil)
        placeholderLabel.alignment = .center
        placeholderLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.stringValue = "No Selection"
        metadataView.showMessage("No Selection")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("previewPane")

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(placeholderLabel)
        let minPreviewHeight = previewContainer.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 120)
        minPreviewHeight.priority = .defaultHigh
        let minMetadataHeight = metadataView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 120)
        minMetadataHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            placeholderLabel.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: previewContainer.leadingAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(
                equalTo: previewContainer.trailingAnchor, constant: -12),
            minPreviewHeight,
            minMetadataHeight,
        ])

        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(previewContainer)
        splitView.addArrangedSubview(metadataView)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        root.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        if !hasPlacedDivider, splitView.bounds.height >= 240 {
            hasPlacedDivider = true
            splitView.setPosition(round(splitView.bounds.height * 0.45), ofDividerAt: 0)
        }
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
            return clearDisplayedContent()
        }
        loadNow(latestTarget)
    }

    /// Releases Quick Look XPC resources and pending background tasks.
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
            currentScope = scope
            metadataView.show(metadata)
            if metadata.isDataless {
                quickLookHost?.isHidden = true
                quickLookHost?.show(nil, scope: nil)
                placeholderLabel.stringValue = "In iCloud — not downloaded"
                placeholderLabel.isHidden = false
            } else {
                placeholderLabel.isHidden = true
                let host = ensureQuickLookHost()
                host.isHidden = false
                host.show(metadata.url, scope: currentScope)
            }
        }
        onLoadFinished?()
    }

    private func clearDisplayedContent(placeholder: String? = nil) {
        currentScope = nil
        quickLookHost?.isHidden = true
        quickLookHost?.show(nil, scope: nil)
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
        host.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            host.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])
        quickLookHost = host
        return host
    }
}
