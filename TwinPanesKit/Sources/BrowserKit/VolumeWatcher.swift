import AppKit
import TwinPanesCore

/// Keeps the sidebar's volume list current (docs/plans/M5.md, D-d): it reads the list
/// off the main actor when started and again after every mount, unmount and rename
/// NSWorkspace announces. A read that finishes after a newer one is dropped.
@MainActor
public final class VolumeWatcher {
    private let center: NotificationCenter
    private let read: @Sendable () -> [Volume]
    private let onChange: ([Volume]) -> Void
    private let queue = DispatchQueue(label: "VolumeWatcher", qos: .userInitiated)
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var isReading = false
    private var needsAnotherRead = false
    /// Reads started; only the newest one's result is shown.
    private(set) var readsRequested = 0
    /// Called when a read's result is dropped for a newer one; for tests.
    var didDropRead: (() -> Void)?

    /// `onChange` gets each new list on the main actor.
    public init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        read: @escaping @Sendable () -> [Volume] = MountedVolumes.current,
        onChange: @escaping ([Volume]) -> Void
    ) {
        self.center = center
        self.read = read
        self.onChange = onChange
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    /// Reads the list now, and starts listening for changes.
    public func start() {
        guard observers.isEmpty else { return }
        let changes = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        observers = changes.map { change in
            center.addObserver(forName: change, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readAgain() }
            }
        }
        readAgain()
    }

    public func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers = []
        readsRequested += 1
        needsAnotherRead = false
    }

    private func readAgain() {
        readsRequested += 1
        if isReading {
            needsAnotherRead = true
            return
        }
        startRead()
    }

    private func startRead() {
        isReading = true
        needsAnotherRead = false
        let (ticket, read) = (readsRequested, read)
        queue.async { [weak self] in
            let volumes = read()
            Task { @MainActor [weak self] in
                self?.finishRead(volumes, ticket: ticket)
            }
        }
    }

    private func finishRead(_ volumes: [Volume], ticket: Int) {
        isReading = false
        let shouldContinue = needsAnotherRead && !observers.isEmpty
        if ticket != readsRequested {
            didDropRead?()
        } else {
            onChange(volumes)
        }
        if shouldContinue { startRead() }
    }
}
