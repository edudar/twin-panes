import AppKit
import TwinPanesCore

/// The file operations' progress strip (docs/plans/M6.md, D-e): one row per operation
/// started from this window, with what it does, a progress bar, bytes and items done,
/// Pause and Cancel. A finished operation's row stays a few seconds; one with failures
/// stays with a Show button that lists them. Empty, the strip takes no room.
@MainActor
public final class OperationsStripViewController: NSViewController {
    private let queue: FileOperationQueue
    private let linger: Duration
    private let shows: (QueuedOperation) -> Bool
    private let stack = NSStackView()
    private var rows: [QueuedOperation.ID: OperationRow] = [:]
    /// Rows the user or the linger time dismissed; their operations stay in the queue.
    private var dismissed: Set<QueuedOperation.ID> = []
    private var token: ObservationToken?

    /// `shows` picks this window's operations; `linger` is how long a finished row stays.
    public init(
        queue: FileOperationQueue, linger: Duration = .seconds(3),
        shows: @escaping (QueuedOperation) -> Bool
    ) {
        self.queue = queue
        self.linger = linger
        self.shows = shows
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.setAccessibilityIdentifier("operationsStrip")
        // As tall as its rows and no taller; with none, no height at all.
        stack.setHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        view = stack
        token = queue.observe { [weak self] in self?.refresh() }
        refresh()
    }

    var shownOperations: [QueuedOperation] {
        queue.operations.filter { rows[$0.id] != nil }
    }

    func texts(of operation: QueuedOperation) -> (title: String, detail: String)? {
        rows[operation.id].map { ($0.title.stringValue, $0.detail.stringValue) }
    }

    func clickPause(of operation: QueuedOperation) { rows[operation.id]?.pause.performClick(nil) }
    func clickCancel(of operation: QueuedOperation) { rows[operation.id]?.cancel.performClick(nil) }

    func failureList(of operation: QueuedOperation) -> String? {
        guard let failures = operation.result?.failures, !failures.isEmpty else { return nil }
        return failures.map(\.description).joined(separator: "\n")
    }

    private func refresh() {
        let wanted = queue.operations.filter { shows($0) && !dismissed.contains($0.id) }
        for (id, row) in rows where !wanted.contains(where: { $0.id == id }) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for operation in wanted {
            let row = rows[operation.id] ?? makeRow(for: operation)
            row.show(operation)
            if let result = operation.result, result.failures.isEmpty { dismissLater(operation) }
        }
    }

    private func makeRow(for operation: QueuedOperation) -> OperationRow {
        let row = OperationRow()
        row.onPause = { [weak operation] in
            guard let operation else { return }
            if operation.isPaused { operation.resume() } else { operation.pause() }
            row.show(operation)
        }
        row.onCancel = { [weak operation] in operation?.cancel() }
        row.onShow = { [weak self, weak operation] in
            guard let self, let operation else { return }
            self.showFailures(of: operation)
        }
        rows[operation.id] = row
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        return row
    }

    private func dismissLater(_ operation: QueuedOperation) {
        let id = operation.id
        guard linger > .zero else { return dismiss(id) }
        Task { [weak self] in
            try? await Task.sleep(for: self?.linger ?? .zero)
            self?.dismiss(id)
        }
    }

    private func dismiss(_ id: QueuedOperation.ID) {
        dismissed.insert(id)
        rows[id]?.removeFromSuperview()
        rows[id] = nil
    }

    private func showFailures(of operation: QueuedOperation) {
        let alert = NSAlert()
        alert.messageText = OperationTexts.title(of: operation)
        alert.informativeText = failureList(of: operation) ?? ""
        alert.addButton(withTitle: "OK")
        let id = operation.id
        guard let window = view.window else { return dismiss(id) }
        alert.beginSheetModal(for: window) { [weak self] _ in self?.dismiss(id) }
    }
}

/// One operation's row.
@MainActor
private final class OperationRow: NSStackView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let pause = NSButton(title: "Pause", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let showFailures = NSButton(title: "Show", target: nil, action: nil)
    var onPause: (() -> Void)?
    var onCancel: (() -> Void)?
    var onShow: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        // As tall as its contents: with a weaker hug a row stretched to take the panels'
        // room (458 pt in the app, beside a sidebar).
        setHuggingPriority(.required, for: .vertical)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        for (button, action) in [
            (pause, #selector(pauseClicked)), (cancel, #selector(cancelClicked)),
            (showFailures, #selector(showClicked)),
        ] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        texts.setHuggingPriority(.required, for: .vertical)
        setViews([texts, bar, pause, cancel, showFailures], in: .leading)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ operation: QueuedOperation) {
        title.stringValue = OperationTexts.title(of: operation)
        detail.stringValue = OperationTexts.detail(of: operation)
        let progress = operation.progress
        bar.maxValue = Double(max(progress.bytesTotal, UInt64(progress.itemsTotal), 1))
        bar.doubleValue = Double(
            progress.bytesTotal > 0 ? progress.bytesDone : UInt64(progress.itemsDone))
        let isRunning = operation.result == nil
        bar.isHidden = !isRunning
        pause.isHidden = !isRunning
        cancel.isHidden = !isRunning
        pause.title = operation.isPaused ? "Resume" : "Pause"
        showFailures.isHidden = operation.result?.failures.isEmpty ?? true
    }

    @objc private func pauseClicked() { onPause?() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func showClicked() { onShow?() }
}
