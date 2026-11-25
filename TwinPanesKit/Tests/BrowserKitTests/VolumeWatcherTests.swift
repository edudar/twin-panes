import AppKit
import Synchronization
import Testing

@testable import BrowserKit
@testable import TwinPanesCore

/// The sidebar's volume list follows mounts (docs/plans/M5.md, D-d, step 18).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct VolumeWatcherTests {
    /// The lists a watcher reported, waited for one at a time.
    @MainActor final class Reported {
        var lists: [[String]] = []
        private var waiter: CheckedContinuation<Void, Never>?

        func add(_ volumes: [Volume]) {
            lists.append(volumes.map(\.name))
            waiter?.resume()
            waiter = nil
        }

        func wait(for count: Int) async {
            while lists.count < count {
                await withCheckedContinuation { waiter = $0 }
            }
        }
    }

    /// The volume list the watcher reads, changed by the test.
    final class Mounted: Sendable {
        let names = Mutex(["Macintosh HD"])
        func read() -> [Volume] {
            names.withLock { names in
                names.map {
                    Volume(url: URL(fileURLWithPath: "/Volumes/\($0)"), name: $0, isEjectable: true)
                }
            }
        }
    }

    let center = NotificationCenter()
    let mounted = Mounted()
    let reported = Reported()

    func watcher() -> VolumeWatcher {
        let (mounted, reported) = (mounted, reported)
        return VolumeWatcher(center: center, read: { mounted.read() }) { reported.add($0) }
    }

    @Test func startingReportsTheVolumesMountedNow() async {
        let watcher = watcher()
        watcher.start()
        await reported.wait(for: 1)
        #expect(reported.lists == [["Macintosh HD"]])
    }

    @Test(arguments: [
        NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
        NSWorkspace.didRenameVolumeNotification,
    ])
    func aVolumeChangeReadsTheListAgain(change: Notification.Name) async {
        let watcher = watcher()
        watcher.start()
        await reported.wait(for: 1)
        mounted.names.withLock { $0.append("USB") }
        center.post(name: change, object: nil)
        await reported.wait(for: 2)
        #expect(reported.lists.last == ["Macintosh HD", "USB"])
    }

    @Test func aReadThatFinishesAfterANewerOneIsDropped() async {
        let (started, startedCont) = AsyncStream.makeStream(of: Void.self)
        let firstMayFinish = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let watcher = VolumeWatcher(
            center: center,
            read: {
                let call = calls.withLock { calls in
                    calls += 1
                    return calls
                }
                if call == 1 {
                    startedCont.yield()
                    firstMayFinish.wait()
                }
                let name = call == 1 ? "old" : "new"
                return [
                    Volume(
                        url: URL(fileURLWithPath: "/Volumes/\(name)"), name: name,
                        isEjectable: false)
                ]
            }
        ) { [reported] in reported.add($0) }
        let dropped = Reported()
        watcher.didDropRead = { dropped.add([]) }
        watcher.start()
        for await _ in started { break }
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        firstMayFinish.signal()
        await dropped.wait(for: 1)
        await reported.wait(for: 1)
        #expect(reported.lists == [["new"]])
    }

    @Test func aStoppedWatcherIgnoresChanges() async {
        let watcher = watcher()
        watcher.start()
        await reported.wait(for: 1)
        watcher.stop()
        let before = watcher.readsRequested
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        #expect(watcher.readsRequested == before)
    }

    @Test func deallocatingStartedWatcherRemovesObservers() async {
        do {
            let watcher = watcher()
            watcher.start()
            await reported.wait(for: 1)
        }
        mounted.names.withLock { $0.append("USB") }
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        await Task.yield()
        #expect(reported.lists == [["Macintosh HD"]])
    }
}
