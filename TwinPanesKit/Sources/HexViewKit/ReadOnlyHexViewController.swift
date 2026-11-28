import AppKit
import Synchronization
import TwinPanesCore
import WorkspaceKit

/// Strictly read-only `HexView` host (`docs/plans/M7.md`, D-b). Never creates an
/// `EditorSession`; observes any matching live session weakly, checks `CloudDownloads`
/// before touching disk on a serial generation-guarded queue, and displays inline
/// placeholders instead of modal alerts.
@MainActor
public final class ReadOnlyHexViewController: NSViewController, HexPreviewing, HexViewDataSource,
    HexViewDelegate
{
    private static let datalessMessage = "This file is in iCloud and not downloaded."
    nonisolated private static let byteSourcePageCapacity = 32
    private static let asyncCopyThreshold = 256 * 1024

    public let hexView = HexView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    public var viewController: NSViewController { self }
    /// Whether the displayed bytes reflect unsaved edits in an open `EditorSession`.
    public private(set) var showsUnsavedEdits = false
    /// Called on the main actor when `showsUnsavedEdits`, the displayed source, or the
    /// placeholder state changes.
    public var onStateChange: (() -> Void)?

    private let sessions: SessionRegistry
    private let cloudDownloads: any CloudDownloads
    let preferences: HexViewPreferences?
    nonisolated private let generation = Mutex<UInt64>(0)
    private let ioQueue = DispatchQueue(
        label: "TwinPanes.ReadOnlyHexViewController.io", qos: .userInitiated)
    private let copyQueue = DispatchQueue(
        label: "TwinPanes.ReadOnlyHexViewController.copy", qos: .userInitiated)
    private let placeholderStack: NSStackView
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let downloadButton: NSButton
    private var currentURL: URL?
    private var scope: SecurityScope?
    private var byteSource: ByteSource?
    private var snapshot: EditSnapshot?
    private weak var observedSession: EditorSession?
    private var sessionObservation: ObservationToken?

    public init(
        style: HexViewerStyle,
        sessions: SessionRegistry,
        cloudDownloads: any CloudDownloads = RealCloudDownloads(),
        preferences: HexViewPreferences? = nil
    ) {
        self.sessions = sessions
        self.cloudDownloads = cloudDownloads
        self.preferences = preferences
        self.downloadButton = NSButton(title: "Download", target: nil, action: nil)
        self.placeholderStack = NSStackView(views: [placeholderLabel, downloadButton])
        super.init(nibName: nil, bundle: nil)
        hexView.options = preferences?.options ?? HexViewOptions()
        hexView.font = .monospacedSystemFont(ofSize: style == .regular ? 13 : 11, weight: .regular)
        hexView.delegate = self
        hexView.dataSource = self
        hexView.setAccessibilityIdentifier("readOnlyHexView")
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.setAccessibilityIdentifier("hexPlaceholder")
        downloadButton.target = self
        downloadButton.action = #selector(downloadPressed(_:))
        downloadButton.setAccessibilityIdentifier("hexDownloadButton")
        downloadButton.isHidden = true
        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 12
        placeholderStack.isHidden = true
        sessions.observe(self) { [weak self] session in self?.sessionDidRegister(session) }
        preferences?.observe(self) { [weak self] options in self?.hexView.options = options }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func loadView() {
        let root = NSView()
        for child in [hexView, placeholderStack] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            hexView.topAnchor.constraint(equalTo: root.topAnchor),
            hexView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hexView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hexView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholderStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            placeholderStack.widthAnchor.constraint(
                lessThanOrEqualTo: root.widthAnchor, constant: -32),
        ])
        view = root
    }

    /// Retargets the viewer to `url` with `scope`, or clears the view when `url` is nil.
    public func show(_ url: URL?, scope: SecurityScope?) {
        let requestGeneration = nextGeneration()
        detachSession()
        byteSource = nil
        currentURL = url
        self.scope = url == nil ? nil : scope
        if let url, let session = sessions.session(for: url) {
            attach(to: session)
            onStateChange?()
            return
        }
        let hadUnsavedEdits = showsUnsavedEdits
        showsUnsavedEdits = false
        if let url {
            if hadUnsavedEdits { onStateChange?() }
            startDiskLoad(for: url, scope: scope, generation: requestGeneration)
        } else {
            presentHexView()
            onStateChange?()
        }
    }

    @discardableResult
    private func nextGeneration() -> UInt64 {
        generation.withLock {
            $0 &+= 1
            return $0
        }
    }

    // MARK: Session sync

    private func sessionDidRegister(_ session: EditorSession) {
        guard let currentURL, observedSession !== session,
            matches(session: session, url: currentURL)
        else { return }
        nextGeneration()
        attach(to: session)
        onStateChange?()
    }

    private func attach(to session: EditorSession) {
        let previousLength = hexView.layout.length
        let wasShowingHex = !hexView.isHidden && (byteSource != nil || snapshot != nil)
        detachSession()
        observedSession = session
        byteSource = nil
        snapshot = session.snapshot
        let token = ObservationToken()
        sessionObservation = token
        session.observe(token) { [weak self, weak session] change in
            guard let self, let session, self.observedSession === session else { return }
            self.handleSessionChange(change, session: session)
        }
        showsUnsavedEdits = session.isDirty
        if wasShowingHex {
            refreshHexView(previousLength: previousLength)
        } else {
            presentHexView()
        }
    }

    private func detachSession() {
        observedSession = nil
        sessionObservation = nil
        snapshot = nil
    }

    private func handleSessionChange(_ change: EditorSession.Change, session: EditorSession) {
        switch change {
        case .saved where currentURL.map { !matches(session: session, url: $0) } ?? false, .closed:
            let requestGeneration = nextGeneration()
            detachSession()
            showsUnsavedEdits = false
            presentHexView()
            onStateChange?()
            if let currentURL {
                startDiskLoad(for: currentURL, scope: scope, generation: requestGeneration)
            }
        case .edited, .saved:
            let previousLength = hexView.layout.length
            snapshot = session.snapshot
            showsUnsavedEdits = session.isDirty
            refreshHexView(previousLength: previousLength)
            onStateChange?()
        case .saving, .fileChanged:
            break
        }
    }

    private func matches(session: EditorSession, url: URL) -> Bool {
        let currentKey = byteSource?.identity.key ?? (try? FileIdentity(url: url).key)
        if let currentKey, currentKey == session.identity.key { return true }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
            == session.url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Async disk loading

    private func startDiskLoad(
        for url: URL, scope: SecurityScope?, generation requestGeneration: UInt64
    ) {
        let cloud = cloudDownloads
        runOnIOQueue(generation: requestGeneration, scope: scope) {
            if cloud.isDataless(url) { return LoadOutcome.dataless }
            do {
                return .loaded(try ByteSource(url: url, pageCapacity: Self.byteSourcePageCapacity))
            } catch {
                return .failed("\(error)")
            }
        } completion: { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .dataless: self.presentDatalessPlaceholder()
            case .loaded(let source):
                self.byteSource = source
                self.presentHexView()
            case .failed(let message): self.presentPlaceholder(message: message)
            }
            self.onStateChange?()
        }
    }

    @objc private func downloadPressed(_ sender: Any?) {
        guard let url = currentURL else { return }
        downloadButton.isEnabled = false
        let cloud = cloudDownloads
        let requestGeneration = generation.withLock { $0 }
        runOnIOQueue(generation: requestGeneration, scope: scope) {
            do {
                try cloud.startDownload(url)
                return nil as String?
            } catch {
                return (error as? ByteSourceError)?.description ?? error.localizedDescription
            }
        } completion: { [weak self] failureMessage in
            guard let self else { return }
            if let failureMessage {
                self.presentDownloadPlaceholder(message: failureMessage)
            } else {
                self.presentPlaceholder(message: "Downloading from iCloud…")
            }
            self.onStateChange?()
        }
    }

    private func runOnIOQueue<Result: Sendable>(
        generation requestGeneration: UInt64,
        scope: SecurityScope?,
        work: @escaping @Sendable () -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard self?.generation.withLock({ $0 }) == requestGeneration else { return }
            let result = withExtendedLifetime(scope) { work() }
            guard self?.generation.withLock({ $0 }) == requestGeneration else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation.withLock({ $0 }) == requestGeneration else {
                    return
                }
                completion(result)
            }
        }
    }

    // MARK: View state

    private func presentDatalessPlaceholder() {
        presentDownloadPlaceholder(message: Self.datalessMessage)
    }

    private func presentDownloadPlaceholder(message: String) {
        presentPlaceholder(message: message)
        downloadButton.isHidden = false
        downloadButton.isEnabled = true
    }

    private func presentPlaceholder(message: String) {
        byteSource = nil
        hexView.isHidden = true
        hexView.reloadData()
        placeholderLabel.stringValue = message
        downloadButton.isHidden = true
        downloadButton.isEnabled = false
        placeholderStack.isHidden = false
    }

    private func presentHexView() {
        placeholderStack.isHidden = true
        downloadButton.isHidden = true
        hexView.isHidden = false
        hexView.reloadData()
    }

    private func refreshHexView(previousLength: UInt64) {
        placeholderStack.isHidden = true
        downloadButton.isHidden = true
        hexView.isHidden = false
        if previousLength != length {
            hexView.contentLengthDidChange()
        } else {
            hexView.needsDisplay = true
        }
    }
    // MARK: HexViewDataSource & HexViewDelegate
    public var length: UInt64 { snapshot?.length ?? byteSource?.length ?? 0 }
    public func cachedBytes(_ range: Range<UInt64>) -> Data? {
        snapshot?.cachedBytes(range) ?? byteSource?.cachedBytes(range)
    }

    public func prefetch(
        _ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void
    ) {
        if let snapshot {
            snapshot.prefetch(range) { completion($0) }
        } else if let byteSource {
            byteSource.prefetch(range) { completion($0) }
        } else {
            completion(nil)
        }
    }

    public func read(_ range: Range<UInt64>) throws -> Data {
        if let snapshot { return try snapshot.read(range) }
        if let byteSource { return try byteSource.read(range) }
        return Data()
    }

    public func readForCopy(
        _ range: Range<UInt64>, completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        guard let source: any ByteReading = snapshot ?? byteSource else {
            return completion(.success(Data()))
        }
        let readExact: @Sendable () -> Result<Data, Error> = {
            Result {
                let data = try source.readSequential(range)
                guard UInt64(data.count) == range.count else {
                    let avail = range.lowerBound + UInt64(data.count)
                    throw ByteSourceError.truncated(expected: range.upperBound, available: avail)
                }
                return data
            }
        }
        if range.count <= Self.asyncCopyThreshold { return completion(readExact()) }
        let scope = self.scope ?? observedSession?.scope
        copyQueue.async {
            let result = withExtendedLifetime(scope) { readExact() }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    public func modifiedRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
        snapshot?.modifiedRanges(in: range) ?? []
    }

    public func hexViewSelectionDidChange(_ view: HexView) {}
    public func hexView(_ view: HexView, selectionTooLargeToCopy range: Range<UInt64>) {}
    public func hexViewWillBeginEdit(_ view: HexView) -> Bool { false }

    public func hexView(_ view: HexView, didFailToRead error: Error) {
        guard observedSession == nil else { return }
        presentPlaceholder(message: "\(error)")
        onStateChange?()
    }
}
private final class ObservationToken {}
private enum LoadOutcome: Sendable { case dataless, loaded(ByteSource), failed(String) }
