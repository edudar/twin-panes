import AppKit
import HexViewKit
import TwinPanesCore
import WorkspaceKit

/// Action selectors of the hex editor, so menus and the command catalog can name them.
@objc public protocol HexEditorActions {
    @objc optional func goToOffset(_ sender: Any?)
    @objc optional func copyAsHex(_ sender: Any?)
    @objc optional func copyAsText(_ sender: Any?)
    @objc optional func saveSelection(_ sender: Any?)
    @objc optional func toggleInspector(_ sender: Any?)
    /// View options; the menu item's `representedObject` carries the value.
    @objc optional func setBytesPerRow(_ sender: Any?)
    @objc optional func setGrouping(_ sender: Any?)
    @objc optional func setOffsetBase(_ sender: Any?)
    @objc optional func setTextEncoding(_ sender: Any?)
}

@MainActor
final class HexEditorViewController: NSViewController, CommandScopeProviding, HexViewDelegate {
    unowned let item: HexEditorItem
    let hexView = HexView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let inspector = InspectorView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
    private let divider = NSBox()
    /// Switched by `applyVisibility()` as the inspector comes and goes.
    private var hexToEdge: NSLayoutConstraint?
    private var hexToInspector: NSLayoutConstraint?

    init(item: HexEditorItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var commandScopes: [BindingScope] { [.item(.editor)] }

    override func loadView() {
        hexView.delegate = self
        hexView.dataSource = item
        hexView.setAccessibilityIdentifier("hexView")
        divider.boxType = .separator

        // Plain constraints: the hex view has no intrinsic size, so it takes whatever
        // the inspector (right) leaves.
        let root = NSView()
        for child in [hexView, divider, inspector] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        hexToEdge = hexView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        hexToInspector = hexView.trailingAnchor.constraint(equalTo: divider.leadingAnchor)
        NSLayoutConstraint.activate([
            hexView.topAnchor.constraint(equalTo: root.topAnchor),
            hexView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hexView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.topAnchor.constraint(equalTo: hexView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.topAnchor.constraint(equalTo: hexView.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 280),
        ])
        view = root
        applyVisibility()
    }

    /// Puts the hex view left of the inspector when it shows.
    func applyVisibility() {
        divider.isHidden = inspector.isHidden
        let pairs = [
            (hexToEdge, hexToInspector, inspector.isHidden)
        ]
        for (whenHidden, whenShown, hidden) in pairs {
            (hidden ? whenShown : whenHidden)?.isActive = false
            (hidden ? whenHidden : whenShown)?.isActive = true
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        item.updateStatus()
        updateInspector()
    }

    // MARK: HexViewDelegate

    func hexViewSelectionDidChange(_ view: HexView) {
        item.updateStatus()
        updateInspector()
    }

    /// Shows the bytes at the cursor; waits for the page if it isn't cached yet.
    func updateInspector() {
        guard !inspector.isHidden else { return }
        let cursor = hexView.selection.cursor
        let range = cursor..<min(item.length, cursor + UInt64(Inspector.byteCount))
        if let bytes = item.cachedBytes(range) { return inspector.show(bytes) }
        item.prefetch(range) { [weak self] in
            guard let self, self.hexView.selection.cursor == cursor else { return }
            self.inspector.show(self.item.cachedBytes(range) ?? Data())
        }
    }

    @objc func toggleInspector(_ sender: Any?) {
        inspector.isHidden.toggle()
        applyVisibility()
        updateInspector()
    }

    func hexView(_ view: HexView, selectionTooLargeToCopy range: Range<UInt64>) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "The selection is too large to copy"
        alert.informativeText =
            "\(range.count.formatted()) bytes selected; copying is limited to "
            + "\(HexCopy.maxBytes.formatted()) bytes. Save the selection to a file instead?"
        alert.addButton(withTitle: "Save Selection…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.saveSelection(nil) }
        }
    }

    // MARK: Commands

    @objc func goToOffset(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Offset"
        alert.informativeText =
            "Decimal (4096), hex (0x1000, 1000h, $1000), or relative to the cursor (+0x10, -64)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "0x0"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if let offset = HexOffsetParser.parse(
                field.stringValue, current: self.hexView.selection.cursor),
                offset < max(self.item.length, 1)
            {
                self.hexView.go(to: offset)
            } else {
                NSSound.beep()
                self.item.host?.showStatus("“\(field.stringValue)” isn't an offset in this file")
            }
        }
    }

    @objc func copyAsHex(_ sender: Any?) { hexView.copySelection(as: .hex) }

    @objc func copyAsText(_ sender: Any?) {
        hexView.copySelection(as: .text(hexView.options.textEncoding))
    }

    @objc func saveSelection(_ sender: Any?) {
        guard let window = view.window else { return }
        let range = hexView.selection.range
        guard !range.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            item.url.deletingPathExtension().lastPathComponent
            + "-\(range.lowerBound)-\(range.count).bin"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.item.host?.showStatus("Saving \(range.count.formatted()) bytes…")
            let source = self.item.source
            Task.detached(priority: .userInitiated) {
                let error = Self.write(source, range: range, to: destination)
                await MainActor.run { [weak self] in
                    self?.item.host?.showStatus(
                        error.map { "Saving failed: \($0.localizedDescription)" }
                            ?? "Saved \(range.count.formatted()) bytes to \(destination.lastPathComponent)"
                    )
                }
            }
        }
    }

    /// Streams `range` to `destination` in 1 MB chunks through the uncached path.
    nonisolated static func write(
        _ source: ByteSource, range: Range<UInt64>, to destination: URL
    )
        -> Error?
    {
        do {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var offset = range.lowerBound
            while offset < range.upperBound {
                let end = min(range.upperBound, offset + 1 << 20)
                try handle.write(contentsOf: try source.readSequential(offset..<end))
                offset = end
            }
            return nil
        } catch {
            return error
        }
    }
}
