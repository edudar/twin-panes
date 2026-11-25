import AppKit
import BrowserKit
import TwinPanesCore
import WorkspaceKit

extension SmokeTest {
    /// A 10,000-file tree copied with both panels watching its folders, under the stall
    /// gate: cancelled halfway, with no partial file left, then copied in full and checked
    /// (docs/plans/M6.md, step 19).
    func largeCopy(_ check: (Bool, String) -> Void, in controller: MainWindowController) async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "smoke-large-\(UUID().uuidString)", isDirectory: true)
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        let destination = root.appendingPathComponent("dest", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let made = await Task.detached { Self.makeTree(tree, folders: 100, filesEach: 100) }.value
        guard made,
            (try? fm.createDirectory(at: destination, withIntermediateDirectories: true))
                != nil
        else { return check(false, "make a 10,000-file tree") }
        let layout = controller.layout
        guard let left = layout.selectedItem(in: .leftPanel) as? BrowserItem,
            let right = layout.selectedItem(in: .rightPanel) as? BrowserItem
        else { return check(false, "the window shows two browsers") }
        let (leftFolder, rightFolder) = (left.folder, right.folder)
        left.go(to: root)
        right.go(to: destination)
        await left.listed()
        await right.listed()
        let queue = app.fileOperations.queue
        let stalls = StallGate(smoke: self)

        await stalls.check("copying 10,000 files, cancelled halfway", check) {
            let operation = queue.add(.copy([tree], into: destination), scopes: []) { _, _ in
                ConflictAnswer(.stop)
            }
            for _ in 0..<1_000 where operation.result == nil && operation.progress.itemsDone < 5_000
            {
                await settle(milliseconds: 10)
            }
            operation.cancel()
            let result = await operation.finished()
            check(result.wasCancelled, "a cancelled copy says so")
        }
        let partial = await Task.detached { Self.filesAndSizes(in: destination) }.value
        check(
            partial.files < 10_000 && partial.wrongSize == 0,
            "cancelled halfway, \(partial.files) files copied and none partial")

        try? fm.removeItem(at: destination.appendingPathComponent("tree"))
        await stalls.check("copying 10,000 files with both panels watching", check) {
            let operation = queue.add(.copy([tree], into: destination), scopes: []) { _, _ in
                ConflictAnswer(.stop)
            }
            let result = await operation.finished()
            check(result.failures.isEmpty && !result.wasCancelled, "the full copy succeeds")
        }
        let full = await Task.detached { Self.filesAndSizes(in: destination) }.value
        check(
            full.files == 10_000 && full.wrongSize == 0,
            "all 10,000 files are copied whole: \(full.files), \(full.wrongSize) wrong")

        left.go(to: leftFolder)
        right.go(to: rightFolder)
        await left.listed()
        await right.listed()
        let strip = controller.frameController.bottomAccessory?.view
        for _ in 0..<250 where (strip?.fittingSize.height ?? 0) >= 1 {
            await settle(milliseconds: 20)
        }
    }

    /// `folders` folders of `filesEach` 4 KB files.
    private nonisolated static func makeTree(_ tree: URL, folders: Int, filesEach: Int) -> Bool {
        let bytes = Data(count: 4_096)
        do {
            for folder in 0..<folders {
                let url = tree.appendingPathComponent("folder-\(folder)", isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                for file in 0..<filesEach {
                    try bytes.write(to: url.appendingPathComponent("file-\(file).bin"))
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// How many files are below `folder`, and how many aren't 4 KB.
    private nonisolated static func filesAndSizes(in folder: URL) -> (files: Int, wrongSize: Int) {
        let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var (files, wrong) = (0, 0)
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            if values?.fileSize != 4_096 { wrong += 1 }
        }
        return (files, wrong)
    }
}
