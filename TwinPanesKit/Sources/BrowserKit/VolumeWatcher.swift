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
    private var observers: [NSObjectProtocol] = []
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
    }

    private func readAgain() {
        readsRequested += 1
        let (ticket, read) = (readsRequested, read)
        Task { [weak self] in
            let volumes = await Task.detached { read() }.value
            guard let self else { return }
            guard ticket == readsRequested else {
                didDropRead?()
                return
            }
            onChange(volumes)
        }
    }
}
