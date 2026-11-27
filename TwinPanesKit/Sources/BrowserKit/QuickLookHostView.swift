import AppKit
import QuickLookUI
import TwinPanesCore

/// Abstraction over a Quick Look preview view so `QuickLookHostView` can be tested
/// without launching Quick Look XPC services.
@MainActor
protocol QuickLookViewing: AnyObject {
    var view: NSView { get }
    func show(_ url: URL?)
    func close()
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
    private var scope: SecurityScope?
    private var isClosed = false

    init(viewer: QuickLookViewing) {
        self.viewer = viewer
        super.init(frame: .zero)
        embedViewer()
    }

    convenience init(style: QLPreviewViewStyle = .normal) {
        self.init(viewer: QLPreviewViewAdapter(style: style))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ url: URL?, scope: SecurityScope?) {
        guard !isClosed else {
            self.scope = nil
            return
        }
        self.scope = url == nil ? nil : scope
        viewer.show(url)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        scope = nil
        viewer.close()
    }

    private func embedViewer() {
        let content = viewer.view
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
