import AppKit
import HexViewKit
import TwinPanesCore

/// Find in the hex editor (PLAN.md §4.5, §4.10): next/previous with wrap-around and
/// Find All, run by `Searcher` off the main thread with progress and cancel.
extension HexEditorViewController {
    func configureFindBar() {
        findBar.onFind = { [weak self] direction in self?.find(direction) }
        findBar.onFindAll = { [weak self] in self?.findAll() }
        findBar.onPatternChange = { [weak self] in self?.patternChanged() }
        findBar.onDone = { [weak self] in self?.editorCloseFind(nil) }
    }

    var isSearching: Bool { searchTask != nil }

    // MARK: Commands

    @objc func editorFind(_ sender: Any?) {
        findBar.isHidden = false
        applyVisibility()
        view.window?.makeFirstResponder(findBar.field)
        findBar.field.currentEditor()?.selectAll(nil)
    }

    @objc func editorFindNext(_ sender: Any?) { find(.forward) }
    @objc func editorFindPrevious(_ sender: Any?) { find(.backward) }
    @objc func editorFindAll(_ sender: Any?) { findAll() }

    /// Puts the selected bytes in the find bar as hex.
    @objc func editorUseSelectionForFind(_ sender: Any?) {
        let range = hexView.selection.range
        let limit = range.lowerBound + UInt64(SearchPattern.maxLength)
        let capped = range.lowerBound..<min(range.upperBound, limit)
        guard let item, let bytes = try? item.read(capped) else { return NSSound.beep() }
        findBar.kind = .hex
        findBar.field.stringValue = HexCopy.string(bytes, as: .hex)
        patternChanged()
        findBar.isHidden = false
        applyVisibility()
    }

    /// Esc in the find bar: stops a running search, else closes the bar.
    @objc func editorCloseFind(_ sender: Any?) {
        if isSearching { return cancelSearch() }
        findBar.isHidden = true
        applyVisibility()
        hexView.highlights = []
        allMatches = nil
        view.window?.makeFirstResponder(hexView)
    }

    // MARK: Searching

    private func currentPattern() -> SearchPattern? {
        do {
            return try findBar.pattern()
        } catch {
            findBar.show("\(error)", isError: true)
            NSSound.beep()
            return nil
        }
    }

    func find(_ direction: Searcher.Direction) {
        guard !findBar.field.stringValue.isEmpty else { return editorFind(nil) }
        guard let pattern = currentPattern() else { return }
        let selected = hexView.selection.range
        if let all = allMatches, all.pattern == pattern, !all.result.isTruncated {
            return step(through: all.result.ranges, direction, from: selected)
        }
        let from = FindStepper.searchStart(direction, selected: selected, lastMatch: lastMatch)
        guard let source = searchSource else { return }
        let searcher = Searcher(source: source)
        run { token, progress in
            try searcher.next(
                pattern, from: from, direction: direction, cancellation: token, progress: progress)
        } done: { [weak self] match in
            guard let self else { return }
            guard let match else {
                self.reportFind("Not found")
                return NSSound.beep()
            }
            self.select(match.range)
            let wrap = direction == .forward ? " (wrapped to the start)" : " (wrapped to the end)"
            self.reportFind(
                "Found at \(HexEditorItem.hex(match.range.lowerBound))\(match.wrapped ? wrap : "")")
        }
    }

    func findAll() {
        guard !findBar.field.stringValue.isEmpty else { return editorFind(nil) }
        if findBar.isHidden {
            findBar.isHidden = false
            applyVisibility()
        }
        guard let pattern = currentPattern(), let source = searchSource else { return }
        let searcher = Searcher(source: source)
        run { token, progress in
            try searcher.all(pattern, cancellation: token, progress: progress)
        } done: { [weak self] result in
            guard let self else { return }
            self.allMatches = (pattern, result)
            self.hexView.highlights = result.ranges
            guard !result.ranges.isEmpty else {
                self.findBar.show("Not found")
                return NSSound.beep()
            }
            if result.isTruncated {
                self.findBar.show(
                    "More than \(result.ranges.count.formatted()) matches; "
                        + "the first \(result.ranges.count.formatted()) are highlighted")
            }
            let cursor = self.hexView.selection.range.lowerBound
            self.step(
                through: result.ranges, .forward, from: cursor..<cursor, quiet: result.isTruncated)
        }
    }

    private func reportFind(_ message: String) {
        findBar.show(message)
        if findBar.isHidden { item?.host?.showStatus(message) }
    }

    /// Moves to the next or previous range in `ranges` (sorted) relative to `selected`.
    private func step(
        through ranges: [Range<UInt64>], _ direction: Searcher.Direction,
        from selected: Range<UInt64>, quiet: Bool = false
    ) {
        guard
            let index = FindStepper.index(
                in: ranges, direction, selected: selected, lastMatch: lastMatch)
        else {
            findBar.show("Not found")
            return NSSound.beep()
        }
        select(ranges[index])
        if !quiet { findBar.show("\((index + 1).formatted()) of \(ranges.count.formatted())") }
    }

    private func select(_ range: Range<UInt64>) {
        lastMatch = range
        hexView.select(range)
    }

    private func patternChanged() {
        cancelSearch()
        allMatches = nil
        lastMatch = nil
        hexView.highlights = []
        findBar.show("")
    }

    func cancelSearch() {
        guard let task = searchTask else { return }
        task.cancel()
        searchTask = nil
        searchGeneration += 1
        findBar.setProgress(nil)
        findBar.show("Cancelled")
    }

    /// Runs `work` on the search queue, showing progress in the bar, then calls `done`
    /// on the main actor unless the search was cancelled or replaced meanwhile.
    private func run<T: Sendable>(
        _ work: @escaping @Sendable (SearchCancellation, @escaping Searcher.Progress) throws -> T,
        done: @escaping @MainActor (T) -> Void
    ) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let version = item?.buffer.tree
        findBar.show("Searching…")
        findBar.setProgress(0)
        let progress: Searcher.Progress = { [weak self] scanned, total in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.searchGeneration == generation, self.isSearching else {
                        return
                    }
                    self.findBar.setProgress(Double(scanned) / Double(max(total, 1)))
                }
            }
        }
        searchTask = Task { [weak self] in
            let result: Result<T, any Error>
            do {
                result = .success(try await Searcher.run { token in try work(token, progress) })
            } catch {
                result = .failure(error)
            }
            guard let self, self.searchGeneration == generation else { return }
            self.searchTask = nil
            self.findBar.setProgress(nil)
            switch result {
            case .success(let value):
                done(value)
                if let version, self.item?.buffer.tree.isSameVersion(as: version) == false {
                    self.item?.host?.showStatus(
                        "The file was edited during the search; the results are from before")
                }
            case .failure(is CancellationError): self.findBar.show("Cancelled")
            case .failure(let error): self.findBar.show("Search failed: \(error)", isError: true)
            }
        }
    }
}
