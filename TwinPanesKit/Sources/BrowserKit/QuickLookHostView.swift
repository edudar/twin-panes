import AppKit
import QuickLookUI
import Synchronization
import TwinPanesCore

/// Abstraction over a Quick Look preview view so `QuickLookHostView` can be tested
/// without launching Quick Look XPC services.
@MainActor
protocol QuickLookViewing: AnyObject {
    var view: NSView { get }
    func show(_ url: URL?)
    func refresh()
    func close()
}

extension QuickLookViewing {
    func refresh() {}
}

/// Wraps `QLPreviewView` with explicit lifecycle management (`shouldCloseWithWindow = false`)
/// and an idempotent `close()` guard.
@MainActor
final class QLPreviewViewAdapter: QuickLookViewing {
    private let previewView: QLPreviewView
    private var isClosed = false

    var view: NSView { previewView }

    init(style: QLPreviewViewStyle = .normal) {
        previewView = QLPreviewView(frame: .zero, style: style)
        previewView.shouldCloseWithWindow = false
        previewView.autostarts = false
    }

    func show(_ url: URL?) {
        guard !isClosed else { return }
        previewView.previewItem = url as NSURL?
    }

    func refresh() {
        guard !isClosed, previewView.previewItem != nil else { return }
        previewView.refreshPreviewItem()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        previewView.close()
    }
}

/// Hosts a `QuickLookViewing` inside Auto Layout bounds and retains the active
/// `SecurityScope` until retargeted, cleared, or closed.
@MainActor
final class QuickLookHostView: NSView {
    private let viewer: QuickLookViewing
    private let resizeDebounce: Duration
    private var scope: SecurityScope?
    private var hasItem = false
    private var isClosed = false
    private var lastLaidOutSize: CGSize = .zero
    private let refreshTask = Mutex<Task<Void, Never>?>(nil)

    init(viewer: QuickLookViewing, resizeDebounce: Duration = .milliseconds(60)) {
        self.viewer = viewer
        self.resizeDebounce = resizeDebounce
        super.init(frame: .zero)
        clipsToBounds = true
        embedViewer()
    }

    deinit {
        refreshTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    convenience init(style: QLPreviewViewStyle = .normal) {
        self.init(viewer: QLPreviewViewAdapter(style: style))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ url: URL?, scope: SecurityScope?) {
        cancelRefresh()
        guard !isClosed else {
            self.scope = nil
            hasItem = false
            return
        }
        hasItem = url != nil
        self.scope = hasItem ? scope : nil
        lastLaidOutSize = bounds.size
        viewer.show(url)
    }

    func close() {
        cancelRefresh()
        guard !isClosed else { return }
        isClosed = true
        hasItem = false
        scope = nil
        viewer.close()
    }

    override func layout() {
        super.layout()
        if viewer.view.frame != bounds {
            viewer.view.frame = bounds
        }
        let size = bounds.size
        guard hasItem, !isClosed, size.width > 0, size.height > 0 else { return }
        guard size != lastLaidOutSize else { return }
        lastLaidOutSize = size
        scheduleRefresh()
    }

    private func cancelRefresh() {
        refreshTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private func scheduleRefresh() {
        cancelRefresh()
        let delay = resizeDebounce
        let task = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) } else { await Task.yield() }
            guard let self, !Task.isCancelled, !self.isClosed, self.hasItem else { return }
            self.refreshTask.withLock { $0 = nil }
            self.viewer.refresh()
        }
        refreshTask.withLock { $0 = task }
    }

    private func embedViewer() {
        // QLPreviewView is an XPC remote-view host that mis-centers under Auto Layout
        // resizing; keep it frame-sized to this host's bounds.
        let content = viewer.view
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = bounds
        addSubview(content)
    }
}
