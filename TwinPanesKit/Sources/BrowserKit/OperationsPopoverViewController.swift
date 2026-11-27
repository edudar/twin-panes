import AppKit
import Synchronization
import TwinPanesCore
import enum WorkspaceKit.OperationsIndicatorState

/// The file operations' activity popover: newest operations at the top, up to 4 rows
/// visible at once, scrolling through the last 20 retained operations while discarding
/// older finished ones. Auto-opens on start and auto-hides after all operations succeed
/// unless a failure occurred or the user opened the popover manually.
@MainActor
public final class OperationsPopoverViewController: NSViewController {
    public static let maxVisibleRows = 4
    public static let maxRetainedOperations = 20

    private static let popoverWidth: CGFloat = 350
    private static let headerHeight: CGFloat = 34
    private static let emptyBodyHeight: CGFloat = 72
    private static let rowHeight: CGFloat = 52

    private let queue: FileOperationQueue
    private let linger: Duration
    private let shows: (QueuedOperation) -> Bool
    private let onDiscard: ((QueuedOperation.ID) -> Void)?

    /// Called when a new operation starts and the popover should open.
    public var onRequestShow: (() -> Void)?
    /// Called after the linger period once all operations succeed.
    public var onRequestHide: (() -> Void)?
    /// Called whenever the toolbar indicator's state changes.
    public var onIndicatorChange: ((OperationsIndicatorState) -> Void)?
    /// Supplies the owning main window for failure detail sheets.
    public var hostWindow: (() -> NSWindow?)?

    private let headerTitle = NSTextField(labelWithString: "Activity")
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No Recent Activity")
    private let scrollView = NSScrollView()
    private let documentView = FlippedContainerView()
    private let stack = NSStackView()

    private var rows: [QueuedOperation.ID: OperationActivityRow] = [:]
    private var orderedIDs: [QueuedOperation.ID] = []
    /// Operations this popover has already observed (to detect newly started ones).
    private var seenIDs: Set<QueuedOperation.ID> = []
    /// Finished operations cleared by the user or evicted past the 20-item limit.
    private var discardedIDs: Set<QueuedOperation.ID> = []
    private var hadActiveOperations = false
    private var openedManually = false
    private var lastIndicatorState: OperationsIndicatorState?
    private let autoHideTask = Mutex<Task<Void, Never>?>(nil)
    private var token: ObservationToken?

    public init(
        queue: FileOperationQueue,
        linger: Duration = .seconds(3),
        shows: @escaping (QueuedOperation) -> Bool,
        onDiscard: ((QueuedOperation.ID) -> Void)? = nil
    ) {
        self.queue = queue
        self.linger = linger
        self.shows = shows
        self.onDiscard = onDiscard
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        autoHideTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    public override func loadView() {
        let root = NSView(
            frame: NSRect(
                x: 0, y: 0, width: Self.popoverWidth,
                height: Self.headerHeight + Self.emptyBodyHeight))
        root.setAccessibilityIdentifier("operationsPopover")

        let header = makeHeader()
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView

        root.addSubview(header)
        root.addSubview(divider)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        view = root
        token = queue.observe { [weak self] in self?.refresh() }
        refresh()
    }

    private func makeHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        headerTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        headerTitle.textColor = .labelColor
        headerTitle.translatesAutoresizingMaskIntoConstraints = false

        clearButton.bezelStyle = .accessoryBarAction
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(headerTitle)
        header.addSubview(clearButton)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    /// Marks the current popover session as manually opened, cancelling any pending auto-hide.
    public func noteUserOpened() {
        openedManually = true
        cancelAutoHide()
    }

    /// Resets manual-open state when the popover closes.
    public func noteClosed() {
        openedManually = false
        cancelAutoHide()
    }

    /// Removes all finished operations from this popover's history.
    public func clearFinished() {
        let finishedIDs = orderedIDs.filter { id in
            queue.operations.first(where: { $0.id == id })?.result != nil
        }
        guard !finishedIDs.isEmpty else { return }
        for id in finishedIDs { discard(id) }
        refresh()
    }

    /// Reconciles the popover rows, size, indicator state, and auto-show/auto-hide timers
    /// with the operation queue.
    public func refresh() {
        let eligible = queue.operations.filter { shows($0) && !discardedIDs.contains($0.id) }
        var kept: [QueuedOperation] = []
        for operation in eligible {
            if operation.result?.refusal != nil {
                discard(operation.id)
                continue
            }
            kept.append(operation)
        }

        // Newest operations appear at the top; cap total retained entries at 20 while
        // keeping every still-running operation.
        let newestFirst = Array(kept.reversed())
        let activeCount = newestFirst.count(where: { $0.result == nil })
        let finishedBudget = max(0, Self.maxRetainedOperations - activeCount)
        var finishedKept = 0
        var retained: [QueuedOperation] = []
        for operation in newestFirst {
            if operation.result == nil {
                retained.append(operation)
            } else if finishedKept < finishedBudget {
                retained.append(operation)
                finishedKept += 1
            } else {
                discard(operation.id)
            }
        }

        var sawNewOperation = false
        for operation in retained where seenIDs.insert(operation.id).inserted {
            sawNewOperation = true
        }

        syncRows(with: retained)
        updateLayout(rowCount: retained.count, hasFinished: finishedKept > 0)
        updateIndicator(for: retained)
        updateAutoVisibility(retained: retained, sawNewOperation: sawNewOperation)
    }

    // MARK: Testing seams

    var shownOperations: [QueuedOperation] {
        orderedIDs.compactMap { id in queue.operations.first { $0.id == id } }
    }

    var isAutoHideScheduled: Bool { autoHideTask.withLock { $0 != nil } }

    func status(of operation: QueuedOperation) -> OperationStatus? {
        rows[operation.id]?.displayedStatus
    }

    func texts(of operation: QueuedOperation) -> (title: String, detail: String?)? {
        rows[operation.id].map {
            ($0.title.stringValue, $0.detail.isHidden ? nil : $0.detail.stringValue)
        }
    }

    func clickPause(of operation: QueuedOperation) { rows[operation.id]?.pause.performClick(nil) }
    func clickCancel(of operation: QueuedOperation) { rows[operation.id]?.cancel.performClick(nil) }
    func clickShow(of operation: QueuedOperation) {
        rows[operation.id]?.showFailures.performClick(nil)
    }
    func clickClear() { clearButton.performClick(nil) }

    func failureList(of operation: QueuedOperation) -> String? {
        guard let failures = operation.result?.failures, !failures.isEmpty else { return nil }
        let limit = 20
        let lines = failures.prefix(limit).map(\.description).joined(separator: "\n")
        let remaining = failures.count - limit
        return remaining > 0 ? "\(lines)\n…and \(remaining) more" : lines
    }

    // MARK: Internals

    private func syncRows(with retained: [QueuedOperation]) {
        let retainedIDs = Set(retained.map(\.id))
        for (id, row) in rows where !retainedIDs.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }

        let newOrder = retained.map(\.id)
        let orderChanged = newOrder != orderedIDs
        for operation in retained {
            let row = rows[operation.id] ?? makeRow(for: operation)
            row.show(operation)
        }

        if orderChanged {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view) }
            for (index, operation) in retained.enumerated() {
                guard let row = rows[operation.id] else { continue }
                row.showsSeparator = index < retained.count - 1
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            orderedIDs = newOrder
        } else {
            for (index, id) in orderedIDs.enumerated() {
                rows[id]?.showsSeparator = index < orderedIDs.count - 1
            }
        }
    }

    private func makeRow(for operation: QueuedOperation) -> OperationActivityRow {
        let row = OperationActivityRow()
        row.onPause = { [weak operation, weak row] in
            guard let operation, let row else { return }
            if operation.isPaused { operation.resume() } else { operation.pause() }
            row.show(operation)
        }
        row.onCancel = { [weak operation] in operation?.cancel() }
        row.onShow = { [weak self, weak operation] in
            guard let self, let operation else { return }
            self.showFailures(of: operation)
        }
        rows[operation.id] = row
        return row
    }

    private func updateLayout(rowCount: Int, hasFinished: Bool) {
        clearButton.isHidden = !hasFinished
        emptyLabel.isHidden = rowCount > 0
        scrollView.isHidden = rowCount == 0

        let visibleRows = min(rowCount, Self.maxVisibleRows)
        let bodyHeight =
            visibleRows > 0 ? CGFloat(visibleRows) * Self.rowHeight : Self.emptyBodyHeight
        preferredContentSize = NSSize(
            width: Self.popoverWidth, height: Self.headerHeight + bodyHeight)
    }

    private func updateIndicator(for retained: [QueuedOperation]) {
        let active = retained.filter { $0.result == nil }
        let state: OperationsIndicatorState
        if !active.isEmpty {
            let bytesTotal = active.reduce(UInt64(0)) { $0 + $1.progress.bytesTotal }
            let bytesDone = active.reduce(UInt64(0)) { $0 + $1.progress.bytesDone }
            let itemsTotal = active.reduce(0) { $0 + $1.progress.itemsTotal }
            let itemsDone = active.reduce(0) { $0 + $1.progress.itemsDone }
            let progress: Double?
            if bytesTotal > 0 {
                progress = Double(bytesDone) / Double(bytesTotal)
            } else if itemsTotal > 0 {
                progress = Double(itemsDone) / Double(itemsTotal)
            } else {
                progress = nil
            }
            state = .running(progress: progress)
        } else if retained.contains(where: { !($0.result?.failures.isEmpty ?? true) }) {
            state = .failed
        } else {
            state = .idle
        }
        if state != lastIndicatorState {
            lastIndicatorState = state
            onIndicatorChange?(state)
        }
    }

    private func updateAutoVisibility(retained: [QueuedOperation], sawNewOperation: Bool) {
        let hasActive = retained.contains { $0.result == nil }
        if sawNewOperation {
            cancelAutoHide()
            openedManually = false
            onRequestShow?()
        }
        if hasActive {
            hadActiveOperations = true
            cancelAutoHide()
            return
        }
        guard hadActiveOperations || sawNewOperation else { return }
        hadActiveOperations = false
        let hasFailures = retained.contains { !($0.result?.failures.isEmpty ?? true) }
        guard !openedManually, !hasFailures else {
            cancelAutoHide()
            return
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        if linger <= .zero {
            cancelAutoHide()
            onRequestHide?()
            return
        }
        let alreadyScheduled = autoHideTask.withLock { $0 != nil }
        guard !alreadyScheduled else { return }
        let delay = linger
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.finishAutoHide()
        }
        autoHideTask.withLock { $0 = task }
    }

    private func finishAutoHide() {
        autoHideTask.withLock { $0 = nil }
        guard !openedManually else { return }
        let hasActive = shownOperations.contains { $0.result == nil }
        guard !hasActive else { return }
        onRequestHide?()
    }

    private func cancelAutoHide() {
        autoHideTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private func discard(_ id: QueuedOperation.ID) {
        guard discardedIDs.insert(id).inserted else { return }
        rows[id]?.removeFromSuperview()
        rows[id] = nil
        onDiscard?(id)
    }

    @objc private func clearClicked() { clearFinished() }

    private func showFailures(of operation: QueuedOperation) {
        guard let window = hostWindow?() ?? view.window else { return }
        let alert = NSAlert()
        alert.messageText = OperationTexts.title(of: operation)
        alert.informativeText = failureList(of: operation) ?? ""
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }
}

/// Top-left-origin container so scrolled rows start at the top of the popover.
@MainActor
private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// One operation's row inside the activity popover.
@MainActor
private final class OperationActivityRow: NSView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let spinner = NSProgressIndicator()
    let statusIcon = NSImageView()
    let pause = NSButton()
    let cancel = NSButton()
    let showFailures = NSButton()
    private let separator = NSBox()

    var displayedStatus: OperationStatus = .inProgress
    var onPause: (() -> Void)?
    var onCancel: (() -> Void)?
    var onShow: (() -> Void)?

    var showsSeparator = false {
        didSet { separator.isHidden = !showsSeparator }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let statusSlot = NSView()
        statusSlot.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusIcon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false

        statusSlot.addSubview(spinner)
        statusSlot.addSubview(statusIcon)

        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false

        let center = NSStackView(views: [title, bar, detail])
        center.orientation = .vertical
        center.alignment = .leading
        center.spacing = 2
        center.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(
            pause, symbol: "pause.circle", toolTip: "Pause", action: #selector(pauseClicked))
        configureIconButton(
            cancel, symbol: "xmark.circle", toolTip: "Cancel", action: #selector(cancelClicked))
        configureIconButton(
            showFailures, symbol: "info.circle", toolTip: "Show Errors",
            action: #selector(showClicked))

        let controls = NSStackView(views: [pause, cancel, showFailures])
        controls.orientation = .horizontal
        controls.spacing = 4
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setHuggingPriority(.required, for: .horizontal)

        separator.boxType = .separator
        separator.isHidden = true
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusSlot)
        addSubview(center)
        addSubview(controls)
        addSubview(separator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),

            statusSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusSlot.widthAnchor.constraint(equalToConstant: 18),
            statusSlot.heightAnchor.constraint(equalToConstant: 18),

            spinner.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            statusIcon.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),

            center.leadingAnchor.constraint(equalTo: statusSlot.trailingAnchor, constant: 8),
            center.trailingAnchor.constraint(
                lessThanOrEqualTo: controls.leadingAnchor, constant: -8),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalTo: center.widthAnchor),

            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configureIconButton(
        _ button: NSButton, symbol: String, toolTip: String, action: Selector
    ) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func show(_ operation: QueuedOperation) {
        let status = OperationTexts.status(of: operation)
        displayedStatus = status
        title.stringValue = OperationTexts.title(of: operation)

        let detailText = OperationTexts.detail(of: operation)
        detail.stringValue = detailText ?? ""
        detail.isHidden = detailText == nil
        detail.textColor = status == .error ? .systemRed : .secondaryLabelColor

        let progress = operation.progress
        bar.maxValue = Double(max(progress.bytesTotal, UInt64(progress.itemsTotal), 1))
        bar.doubleValue = Double(
            progress.bytesTotal > 0 ? progress.bytesDone : UInt64(progress.itemsDone))

        let isActive = operation.result == nil
        bar.isHidden = !isActive
        pause.isHidden = !isActive
        cancel.isHidden = !isActive
        showFailures.isHidden = operation.result?.failures.isEmpty ?? true

        if operation.isPaused {
            pause.image = NSImage(
                systemSymbolName: "play.circle", accessibilityDescription: "Resume")
            pause.toolTip = "Resume"
        } else {
            pause.image = NSImage(
                systemSymbolName: "pause.circle", accessibilityDescription: "Pause")
            pause.toolTip = "Pause"
        }

        updateStatusIcon(for: status)
    }

    private func updateStatusIcon(for status: OperationStatus) {
        switch status {
        case .inProgress:
            statusIcon.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .paused:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusIcon.isHidden = false
            statusIcon.image = NSImage(
                systemSymbolName: "pause.circle.fill", accessibilityDescription: "Paused")
            statusIcon.contentTintColor = .systemOrange
        case .success:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusIcon.isHidden = false
            statusIcon.image = NSImage(
                systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Succeeded")
            statusIcon.contentTintColor = .systemGreen
        case .error:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusIcon.isHidden = false
            statusIcon.image = NSImage(
                systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Error")
            statusIcon.contentTintColor = .systemRed
        case .cancelled:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusIcon.isHidden = false
            statusIcon.image = NSImage(
                systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancelled")
            statusIcon.contentTintColor = .secondaryLabelColor
        }
    }

    @objc private func pauseClicked() { onPause?() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func showClicked() { onShow?() }
}
