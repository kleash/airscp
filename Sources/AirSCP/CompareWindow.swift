import AirSCPCore
import AppKit

/// Compare's window: two files side by side, line by line (`TextDiff`), or by their SHA-256 checksums when either isn't
/// text it can show (not UTF-8, with NUL bytes, or larger than the editor's limit). Differences can be stepped through
/// and copied from one side to the other, and either side saved back where it came from (this Mac or a server).
@MainActor
final class CompareWindow: NSWindowController, NSWindowDelegate {
    /// One of the two files.
    struct Side {
        let id = UUID()
        let name: String
        let path: String
        /// nil: this Mac.
        let session: Session?
        let size: Int64
        /// What is shown now (with what was copied to it, or prettified).
        var text = ""
        /// "a.txt — lab"
        var title: String { name + " — " + (session?.host.displayName ?? "This Mac") }
    }

    /// After a side was saved (the panes showing its folder list again).
    var onSaved: ((Side) -> Void)?
    var onClose: (() -> Void)?

    private var sides: [Side]
    /// The sides before Prettify (nil: not prettified).
    private var original: [Side]?
    /// What each file holds, as far as this window knows (read, or saved since).
    private var saved: [UUID: String] = [:]
    private var options = TextDiff.Options()
    private var diff: TextDiff?
    /// The difference gone to (an index of `diff.blocks`).
    private var current: Int?
    /// The sides prettified, or why they can't be.
    private var pretty: (texts: [String]?, problem: String) = (nil, "")
    private var generation = 0
    private var hashing: Task<Void, Never>?

    private let views = [CompareTextView(), CompareTextView()]
    private let scrolls = [NSScrollView(), NSScrollView()]
    private let headers = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    private let saveButtons = [NSButton(), NSButton()]
    private let map = DifferenceMap()
    private let previous = NSButton(), next = NSButton(), position = NSTextField(labelWithString: "")
    private let copyRight = NSButton(), copyLeft = NSButton()
    private let ignore = NSPopUpButton(frame: .zero, pullsDown: true)
    private let prettify = NSButton(), sync = NSButton(checkboxWithTitle: "Sync Scrolling", target: nil, action: nil)
    private let swap = NSButton(), reload = NSButton(), find = NSButton()
    private var syncing = false

    /// `texts`: each file's text, or nil when it isn't text to compare line by line (`read`).
    init(_ sides: [Side], texts: [String?]) {
        self.sides = sides
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 720, height: 320)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = sides[0].name + " ↔ " + sides[1].name
        super.init(window: window)
        window.delegate = self
        window.open(size: NSSize(width: 1000, height: 640))
        load(texts)  // after: the checksums' layout makes the window smaller
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Reading

    /// A file's text, or nil when it isn't text to compare line by line: not UTF-8, with NUL bytes, or larger than
    /// the editor's limit.
    nonisolated static func read(_ side: Side) async throws -> String? {
        let limit = 4 << 20  // RemoteEditor.limit
        if let session = side.session {
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: local) }
            do {
                try await session.fetch(side.path, to: local, limit: Int64(limit))
            } catch let error as AirSCPError where error.kind == .notText {
                return nil  // too large
            }
            return text(try Data(contentsOf: local), limit: limit)
        }
        guard (TransferQueue.localSize(side.path) ?? 0) <= limit else { return nil }
        return text(try Data(contentsOf: URL(fileURLWithPath: side.path)), limit: limit)
    }

    nonisolated static func text(_ data: Data, limit: Int) -> String? {
        guard data.count <= limit, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A file's SHA-256 in lower-case hex: on its server (or from a copy downloaded, without a shell), or on this Mac.
    nonisolated static func sha256(_ side: Side) async throws -> String {
        if let session = side.session { return try await session.checksum(side.path, .sha256) }
        let cancellation = Cancellation(), path = side.path
        return try await withTaskCancellationHandler {
            try await Task.detached { try TransferQueue.sha256(path, cancellation: cancellation) }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Writes `text` over a file on this Mac: next to it first, then in its place (keeping its permissions), so that a
    /// full disk can't leave it half written.
    nonisolated static func writeLocal(_ text: String, to path: String) throws {
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let part = file.deletingLastPathComponent().appendingPathComponent(TransferQueue.partName(UUID()))
        try Data(text.utf8).write(to: part)
        do {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: part)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    /// Shows `texts` side by side, or the checksums when either isn't text.
    private func load(_ texts: [String?]) {
        hashing?.cancel()
        window?.undoManager?.removeAllActions()
        original = nil
        diff = nil
        current = nil
        guard let left = texts[0], let right = texts[1] else { return showChecksums() }
        sides[0].text = left
        sides[1].text = right
        saved = [sides[0].id: left, sides[1].id: right]
        if !(window?.contentView is NSStackView) { window?.contentView = makeTextLayout() }
        recompare()
    }

    // MARK: Side by side

    private func makeTextLayout() -> NSView {
        @discardableResult func button(_ button: NSButton, _ title: String, _ action: Selector, _ id: String, key: String = "",
                    _ modifiers: NSEvent.ModifierFlags = [.command, .option]) -> NSButton {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.keyEquivalent = key
            if !key.isEmpty { button.keyEquivalentModifierMask = modifiers }
            button.setAccessibilityIdentifier(id)
            return button
        }
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let leftKey = String(UnicodeScalar(NSLeftArrowFunctionKey)!), rightKey = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        button(previous, "Previous", #selector(goToPrevious(_:)), "compare.previous", key: up)
        button(next, "Next", #selector(goToNext(_:)), "compare.next", key: down)
        button(copyRight, "Copy →", #selector(copyToRight(_:)), "compare.copyRight", key: rightKey)
        button(copyLeft, "← Copy", #selector(copyToLeft(_:)), "compare.copyLeft", key: leftKey)
        button(prettify, "Prettify", #selector(togglePrettify(_:)), "compare.prettify")
        button(swap, "Swap", #selector(swapSides(_:)), "compare.swap")
        button(reload, "Reload", #selector(reloadFiles(_:)), "compare.reload")
        button(find, "Find", #selector(showFind(_:)), "compare.find", key: "f", .command)
        position.textColor = .secondaryLabelColor
        position.setAccessibilityIdentifier("compare.position")
        position.toolTip = "Which difference is shown, of how many"
        swap.toolTip = "Put the right file on the left and the left one on the right"
        reload.toolTip = "Read both files again and compare them"
        find.toolTip = "Find text in the side clicked last (⌘F)"
        sync.target = self
        sync.action = #selector(toggleSync(_:))
        sync.state = .on
        sync.setAccessibilityIdentifier("compare.sync")
        sync.toolTip = "Scroll both sides together, up and down and sideways"

        ignore.addItem(withTitle: "Ignore")
        for (index, (title, tip)) in [("Whitespace", "Leave out spaces and tabs at the start and end of lines, and take runs of them as one"),
                                      ("Case", "Take capital and small letters as the same"),
                                      ("Blank Lines", "Leave out lines that are empty or only spaces")].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(toggleIgnore(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.toolTip = tip
            ignore.menu?.addItem(item)
        }
        ignore.setAccessibilityIdentifier("compare.ignore")
        ignore.toolTip = "Choose what the comparison leaves out: whitespace, case, blank lines"

        let bar = NSStackView(views: [previous, next, position, NSView(), copyRight, copyLeft, NSView(),
                                      ignore, prettify, sync, swap, reload, find])
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 6, right: 12)
        bar.setHuggingPriority(.defaultHigh, for: .vertical)

        var columns: [NSView] = []
        for index in 0..<2 {
            let view = views[index], scroll = scrolls[index]
            view.setAccessibilityIdentifier(index == 0 ? "compare.left" : "compare.right")
            scroll.documentView = view
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.borderType = .noBorder
            scroll.findBarPosition = .belowContent  // above, it would push this side's rows out of line with the other's
            scroll.verticalRulerView = LineNumbers(scrollView: scroll, orientation: .verticalRuler)
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification,
                                                   object: scroll.contentView)
            let header = headers[index]
            header.lineBreakMode = .byTruncatingMiddle
            header.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let save = button(saveButtons[index], index == 0 ? "Save Left" : "Save Right", #selector(saveSide(_:)),
                              index == 0 ? "compare.saveLeft" : "compare.saveRight")
            save.tag = index
            save.controlSize = .small
            let top = NSStackView(views: [header, NSView(), save])
            top.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 4, right: 8)
            let column = NSStackView(views: [top, scroll])
            column.orientation = .vertical
            column.alignment = .width
            column.spacing = 0
            columns.append(column)
        }
        let pair = NSStackView(views: columns)
        pair.distribution = .fillEqually
        pair.spacing = 1
        map.widthAnchor.constraint(equalToConstant: 12).isActive = true
        map.setAccessibilityIdentifier("compare.map")
        map.toolTip = "Click to go to a difference: red marks lines only on the left, green lines only on the right"
        map.onClick = { [weak self] fraction in self?.goToRow(fraction) }
        let body = NSStackView(views: [pair, map])
        body.spacing = 0
        let stack = NSStackView(views: [bar, FilePane.separator(), body])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        window?.initialFirstResponder = views[0]
        return stack
    }

    /// Compares the sides again (off the main thread), with the options, then shows them.
    private func recompare() {
        generation += 1
        let generation = generation, left = sides[0].text, right = sides[1].text, options = options
        let names = sides.map(\.name), prettified = original != nil
        window?.subtitle = "Comparing…"
        Task {
            let (diff, pretty) = await Task.detached { () -> (TextDiff, ([String]?, String)) in
                (TextDiff(left: left, right: right, options: options),
                 prettified ? (nil, "") : Prettify.both([left, right], names: names))
            }.value
            guard generation == self.generation else { return }
            self.pretty = pretty
            show(diff)
        }
    }

    private func show(_ diff: TextDiff) {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        for index in 0..<2 {
            let lines = index == 0 ? diff.leftLines : diff.rightLines
            var text = "", starts: [Int] = [], numbers: [Int?] = [], tints: [CompareTextView.Tint] = [], marks: [NSRange] = []
            text.reserveCapacity(sides[index].text.utf8.count + diff.rows.count)
            var offset = 0
            for (number, row) in diff.rows.enumerated() {
                let line = (index == 0 ? row.left : row.right).map { TextDiff.shown(lines[$0]) } ?? ""
                if number > 0 { text += "\n"; offset += 1 }
                starts.append(offset)
                text += line
                for range in index == 0 ? row.leftRanges : row.rightRanges {
                    marks.append(NSRange(location: offset + range.lowerBound, length: range.count))
                }
                offset += line.utf16.count
                numbers.append((index == 0 ? row.left : row.right).map { $0 + 1 })
                switch (row.kind, index == 0 ? row.left : row.right) {
                case (_, nil): tints.append(.filler)
                case (.same, _): tints.append(.none)
                case (.changed, _): tints.append(index == 0 ? .changedLeft : .changedRight)
                default: tints.append(index == 0 ? .left : .right)
                }
            }
            let storage = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor,
                                                                               .paragraphStyle: paragraph])
            let strong = (index == 0 ? NSColor.systemRed : .systemGreen).withAlphaComponent(0.35)
            for mark in marks { storage.addAttribute(.backgroundColor, value: strong, range: mark) }
            let view = views[index]
            view.rowHeight = height
            view.tints = tints
            view.textStorage?.setAttributedString(storage)
            (scrolls[index].verticalRulerView as? LineNumbers)?.numbers = numbers
        }
        for scroll in scrolls { (scroll.verticalRulerView as? LineNumbers)?.fit(max(diff.leftLines.count, diff.rightLines.count)) }
        let first = self.diff == nil
        self.diff = diff
        map.rows = diff.rows.count
        map.marks = diff.blocks.map { block in
            let kinds = Set(diff.rows[block.rows].map(\.kind))
            return (block.rows, kinds == [.leftOnly] ? .systemRed : kinds == [.rightOnly] ? .systemGreen : .systemOrange)
        }
        map.needsDisplay = true
        if diff.blocks.isEmpty {
            current = nil
        } else if let current {
            self.current = min(current, diff.blocks.count - 1)
        }
        if let current {
            go(to: current)
        } else if first, !diff.blocks.isEmpty {
            go(to: 0)
        } else {
            markCurrent()
        }
        summarize(diff)
        updateControls()
    }

    private func summarize(_ diff: TextDiff) {
        func count(_ number: Int, _ what: String) -> String { number == 1 ? "1 \(what)" : "\(number.formatted()) \(what)s" }
        let prettified = original == nil ? "" : " (prettified)"
        guard diff.blocks.isEmpty else {
            let rows = diff.rows.map(\.kind)
            let parts = [(rows.filter { $0 == .changed }.count, " changed"),
                         (rows.filter { $0 == .leftOnly }.count, " only on the left"),
                         (rows.filter { $0 == .rightOnly }.count, " only on the right")]
                .filter { $0.0 > 0 }.map { count($0.0, "line") + $0.1 }
            window?.subtitle = count(diff.blocks.count, "difference") + ": " + parts.joined(separator: ", ") + prettified
            return
        }
        if sides[0].text == sides[1].text {
            window?.subtitle = "The files are the same" + prettified
            return
        }
        let ignored = [(options.whitespace, "whitespace"), (options.caseOfLetters, "case"), (options.blankLines, "blank lines")]
            .filter(\.0).map(\.1)
        window?.subtitle = "The files are the same apart from "
            + (ignored.isEmpty ? "their line ends" : ListFormatter.localizedString(byJoining: ignored)) + prettified
    }

    private func updateControls() {
        let count = diff?.blocks.count ?? 0
        position.stringValue = count == 0 ? "No differences" : current.map { "\($0 + 1) of \(count)" } ?? "\(count) differences"
        func set(_ button: NSButton, _ enabled: Bool, _ tip: String, _ why: String) {
            button.isEnabled = enabled
            button.toolTip = enabled ? tip : why
        }
        set(previous, (current ?? count) > 0 && count > 0, "Go to the previous difference (⌥⌘↑)",
            count == 0 ? "No differences to go to" : "This is the first difference")
        set(next, (current.map { $0 + 1 } ?? 0) < count, "Go to the next difference (⌥⌘↓)",
            count == 0 ? "No differences to go to" : "This is the last difference")
        let noCurrent = count == 0 ? "No differences to copy" : "Go to a difference first (Next)"
        set(copyRight, current != nil, "Copy this difference's left lines over the right ones (⌥⌘→)", noCurrent)
        set(copyLeft, current != nil, "Copy this difference's right lines over the left ones (⌥⌘←)", noCurrent)
        prettify.title = original == nil ? "Prettify" : "Original"
        if original == nil {
            set(prettify, pretty.texts != nil, "Format both sides as indented JSON or XML and compare again (⌘Z undoes it)", pretty.problem)
        } else {
            set(prettify, true, "Put the text as it was before Prettify back", "")
        }
        for (index, item) in (ignore.menu?.items.dropFirst() ?? []).enumerated() {
            item.state = [options.whitespace, options.caseOfLetters, options.blankLines][index] ? .on : .off
        }
        for index in 0..<2 {
            let side = sides[index]
            headers[index].stringValue = side.title
            headers[index].toolTip = side.path
            set(saveButtons[index], side.text != saved[side.id], "Write this side's text over “\(side.name)”",
                "Nothing to save: “\(side.name)” has the text shown")
        }
        window?.isDocumentEdited = sides.contains { $0.text != saved[$0.id] }
    }

    // MARK: Going to differences

    private func go(to block: Int) {
        guard let diff, diff.blocks.indices.contains(block) else { return }
        current = block
        let y = CGFloat(diff.blocks[block].rows.lowerBound) * views[0].rowHeight
        syncing = true
        for view in views {
            let height = view.visibleRect.height
            view.scrollToVisible(NSRect(x: 0, y: max(0, y - height / 3), width: 1, height: height))
        }
        syncing = false
        markCurrent()
        updateControls()
    }

    private func markCurrent() {
        let rows = current.flatMap { diff?.blocks[$0].rows }
        for view in views {
            view.current = rows
            view.needsDisplay = true
        }
    }

    @objc func goToNext(_ sender: Any?) { go(to: current.map { $0 + 1 } ?? 0) }

    @objc func goToPrevious(_ sender: Any?) { go(to: (current ?? diff?.blocks.count ?? 0) - 1) }

    /// The overview bar's click: the difference at that height (or the next one below it).
    private func goToRow(_ fraction: Double) {
        guard let diff, !diff.blocks.isEmpty else { return }
        let row = Int(fraction * Double(diff.rows.count))
        go(to: diff.blocks.firstIndex { $0.rows.upperBound > row } ?? diff.blocks.count - 1)
    }

    @objc private func scrolled(_ notification: Notification) {
        guard sync.state == .on, !syncing, let from = notification.object as? NSClipView,
              let other = scrolls.first(where: { $0.contentView !== from }) else { return }
        syncing = true
        let clip = other.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: from.bounds.origin, size: clip.bounds.size)).origin)
        other.reflectScrolledClipView(clip)
        syncing = false
    }

    @objc func toggleSync(_ sender: Any?) {
        guard sync.state == .on else { return }
        scrolled(Notification(name: NSView.boundsDidChangeNotification, object: scrolls[0].contentView))
    }

    // MARK: Changes (undoable)

    /// Shows `new` sides (and `newOriginal`, the sides before Prettify), with Undo putting the ones shown now back.
    private func change(_ name: String, sides new: [Side], original newOriginal: [Side]?) {
        let old = (sides, original)
        window?.undoManager?.registerUndo(withTarget: self) { window in
            MainActor.assumeIsolated { window.change(name, sides: old.0, original: old.1) }
        }
        window?.undoManager?.setActionName(name)
        sides = new
        original = newOriginal
        recompare()
    }

    @objc func copyToRight(_ sender: Any?) { copyBlock(toRight: true) }

    @objc func copyToLeft(_ sender: Any?) { copyBlock(toRight: false) }

    private func copyBlock(toRight: Bool) {
        guard let diff, let current, diff.blocks.indices.contains(current) else { return }
        var new = sides
        new[toRight ? 1 : 0].text = diff.merging(diff.blocks[current], toRight: toRight)
        change(toRight ? "Copy to Right" : "Copy to Left", sides: new, original: original)
    }

    @objc func togglePrettify(_ sender: Any?) {
        if let original { return change("Original", sides: original, original: nil) }
        guard let texts = pretty.texts else { return }
        var new = sides
        new[0].text = texts[0]
        new[1].text = texts[1]
        change("Prettify", sides: new, original: sides)
    }

    @objc func swapSides(_ sender: Any?) {
        change("Swap", sides: sides.reversed(), original: original?.reversed())
        window?.title = sides[0].name + " ↔ " + sides[1].name
    }

    @objc func toggleIgnore(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: options.whitespace.toggle()
        case 1: options.caseOfLetters.toggle()
        default: options.blankLines.toggle()
        }
        recompare()
    }

    @objc func showFind(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        (window?.firstResponder as? CompareTextView ?? views[0]).performTextFinderAction(item)
    }

    @objc func reloadFiles(_ sender: Any?) {
        let read = { [self] in
            window?.subtitle = "Reading the files…"
            let sides = sides
            Task {
                do {
                    var texts: [String?] = []
                    for side in sides { texts.append(try await Self.read(side)) }
                    self.sides = sides
                    load(texts)
                } catch {
                    if let diff { summarize(diff) }
                    showError(error, title: "Can't read the files again", on: window)
                }
            }
        }
        guard window?.isDocumentEdited == true else { return read() }
        confirm("Read both files again?", info: "The changes you haven't saved are lost.", button: "Reload", destructive: true,
                on: window, action: read)
    }

    // MARK: Saving

    @objc func saveSide(_ sender: NSButton) { save(sender.tag) }

    /// Writes side `index`'s text over its file. On a server, unless the file changed since this window read or saved
    /// it (then it asks first); `overwriting` doesn't check.
    private func save(_ index: Int, overwriting: Bool = false, then done: (() -> Void)? = nil) {
        let side = sides[index], text = side.text
        Task {
            do {
                if let session = side.session {
                    if case .changed = try await session.saveText(text, to: side.path, ifUnchangedFrom: overwriting ? nil : saved[side.id]) {
                        confirm("“\(side.name)” was changed on \(session.host.displayName) after Compare read it",
                                       info: "Overwrite replaces those changes with the text here. Cancel, then Reload, to compare "
                                           + "its new version.", button: "Overwrite", destructive: true, on: window) { [self] in
                            save(index, overwriting: true, then: done)
                        }
                        return
                    }
                } else {
                    try Self.writeLocal(text, to: side.path)
                }
                saved[side.id] = text
                updateControls()
                onSaved?(side)
                done?()
            } catch {
                showError(error, title: "Can't save “\(side.name)”", on: window)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let unsaved = sides.indices.filter { sides[$0].text != saved[sides[$0].id] }
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the changes to " + unsaved.map { "“\(sides[$0].name)”" }.joined(separator: " and ") + " before closing?"
        alert.informativeText = "If you don't, your changes are lost."
        alert.addButton(withTitle: "Save").toolTip = "Save the changes, then close"
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        discard.toolTip = "Close and lose the changes"
        alert.addButton(withTitle: "Cancel").toolTip = "Keep comparing"
        alert.beginSheetModal(for: sender) { [self] response in
            switch response {
            case .alertFirstButtonReturn:
                save(unsaved[0]) { [self] in
                    guard unsaved.count == 2 else { return close() }
                    save(unsaved[1]) { [self] in close() }
                }
            case .alertSecondButtonReturn:
                close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        hashing?.cancel()
        generation += 1
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        onClose?()
    }

    // MARK: Checksums

    /// Either file isn't text: each one's name, size and SHA-256, and whether they are the same.
    private func showChecksums() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        let stop = NSButton(title: "Stop", target: nil, action: nil)
        stop.toolTip = "Stop working out the checksums"
        stop.setAccessibilityIdentifier("compare.stop")
        let verdict = NSTextField(labelWithString: "")
        verdict.font = .systemFont(ofSize: 17, weight: .semibold)
        verdict.setAccessibilityIdentifier("compare.hash")
        let note = NSTextField(wrappingLabelWithString: "Compared by SHA-256 checksum: Compare shows files side by side when "
            + "both are plain text (UTF-8) up to \(FileList.size(Int64(RemoteEditor.limit))).")
        note.textColor = .secondaryLabelColor
        var hashes: [NSTextField] = []
        let grid = NSGridView(views: sides.map { side in
            let hash = NSTextField(labelWithString: "…")
            hash.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            hash.isSelectable = true
            hash.toolTip = "The file's SHA-256 checksum"
            hashes.append(hash)
            let name = NSTextField(labelWithString: side.title)
            name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            name.toolTip = side.path
            name.lineBreakMode = .byTruncatingMiddle
            return [name, NSTextField(labelWithString: FileList.size(side.size)), hash]
        })
        grid.columnSpacing = 16
        grid.rowSpacing = 8
        let progress = NSStackView(views: [spinner, status, stop])
        let stack = NSStackView(views: [grid, progress, verdict, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: content.topAnchor),
                                     stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                                     stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor)])
        window?.contentView = content
        window?.setContentSize(NSSize(width: max(720, stack.fittingSize.width), height: max(320, stack.fittingSize.height)))
        window?.subtitle = "Working out checksums…"
        let sides = sides
        hashing = Task { [weak self] in
            var results: [String] = []
            do {
                for (index, side) in sides.enumerated() {
                    status.stringValue = "Working out the SHA-256 of “\(side.name)” (\(index + 1) of 2)…"
                    results.append(try await Self.sha256(side))
                    hashes[index].stringValue = results[index]
                }
                let same = results[0] == results[1]
                verdict.stringValue = same ? "The files are the same" : "The files are different"
                verdict.textColor = same ? .systemGreen : .systemRed
                self?.window?.subtitle = verdict.stringValue + " (SHA-256)"
                progress.isHidden = true
            } catch {
                spinner.stopAnimation(nil)
                stop.isHidden = true
                let message = (error as? AirSCPError)?.kind == .cancelled || Task.isCancelled ? "Stopped"
                    : (error as? AirSCPError)?.message ?? error.localizedDescription
                status.stringValue = message
                self?.window?.subtitle = "Not compared"
            }
        }
        stop.target = self
        stop.action = #selector(stopHashing(_:))
    }

    @objc func stopHashing(_ sender: Any?) { hashing?.cancel() }
}

/// One side's text: no wrapping, rows of one height (so that both sides line up row for row), tinted across the
/// whole width by what they are.
final class CompareTextView: NSTextView {
    enum Tint { case none, left, right, changedLeft, changedRight, filler }

    var tints: [Tint] = []
    var rowHeight: CGFloat = 16
    /// The rows of the difference gone to: marked at the left edge.
    var current: Range<Int>?

    convenience init() {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = false  // estimated places of lines not laid out yet put rows out of line
        self.init(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        isHorizontallyResizable = true
        isVerticallyResizable = true
        autoresizingMask = [.width, .height]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = .zero
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !tints.isEmpty else { return }
        let first = max(0, Int(rect.minY / rowHeight)), last = min(tints.count - 1, Int(rect.maxY / rowHeight))
        guard first <= last else { return }
        for row in first...last {
            let color: NSColor
            switch tints[row] {
            case .none: continue
            case .left: color = NSColor.systemRed.withAlphaComponent(0.16)
            case .right: color = NSColor.systemGreen.withAlphaComponent(0.16)
            case .changedLeft: color = NSColor.systemRed.withAlphaComponent(0.08)
            case .changedRight: color = NSColor.systemGreen.withAlphaComponent(0.08)
            case .filler: color = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
            }
            color.setFill()
            NSRect(x: rect.minX, y: CGFloat(row) * rowHeight, width: rect.width, height: rowHeight).fill()
        }
        if let current {
            NSColor.controlAccentColor.setFill()
            // Right of the line numbers, which lie over the text's left edge.
            let left = visibleRect.minX + (enclosingScrollView?.contentView.contentInsets.left ?? 0)
            NSRect(x: left, y: CGFloat(current.lowerBound) * rowHeight, width: 3,
                   height: CGFloat(max(1, current.count)) * rowHeight).fill()
        }
    }
}

/// The line numbers beside a side's text (none beside a filler row).
final class LineNumbers: NSRulerView {
    var numbers: [Int?] = [] {
        didSet { needsDisplay = true }
    }

    /// Wide enough for `lines` (both sides get the same width, so that they scroll sideways alike).
    func fit(_ lines: Int) {
        ruleThickness = CGFloat(max(String(lines).count, 2)) * 7.5 + 14
    }
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = clientView as? CompareTextView ?? scrollView?.documentView as? CompareTextView else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let visible = view.visibleRect, height = view.rowHeight
        let first = max(0, Int(visible.minY / height)), last = min(numbers.count - 1, Int(visible.maxY / height))
        guard first <= last else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        for row in first...last {
            guard let number = numbers[row] else { continue }
            let label = String(number) as NSString, size = label.size(withAttributes: attributes)
            let y = convert(NSPoint(x: 0, y: CGFloat(row) * height), from: view).y
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (height - size.height) / 2), withAttributes: attributes)
        }
    }
}

/// A thin bar beside the texts with a mark where each difference is; a click goes to it.
final class DifferenceMap: NSView {
    var rows = 0
    var marks: [(Range<Int>, NSColor)] = []
    var onClick: ((Double) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.06).setFill()
        bounds.fill()
        guard rows > 0 else { return }
        let scale = bounds.height / CGFloat(rows)
        for (range, color) in marks {
            color.withAlphaComponent(0.8).setFill()
            NSRect(x: 2, y: CGFloat(range.lowerBound) * scale, width: bounds.width - 4, height: max(2, CGFloat(range.count) * scale)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard bounds.height > 0 else { return }
        onClick?(Double(convert(event.locationInWindow, from: nil).y / bounds.height))
    }
}

/// Prettify: both sides as indented JSON or XML (by what the texts start with, else the file names' extension).
enum Prettify {
    enum Format { case json, xml }

    static func format(_ text: String, name: String) -> Format? {
        switch text.first(where: { !$0.isWhitespace && $0 != "\u{FEFF}" }) {
        case "{", "[": return .json
        case "<": return .xml
        default:
            switch (name as NSString).pathExtension.lowercased() {
            case "json": return .json
            case "xml", "plist", "svg", "xsd", "xsl", "xslt": return .xml
            default: return nil
            }
        }
    }

    /// Both texts prettified, or nil and why not.
    static func both(_ texts: [String], names: [String]) -> ([String]?, String) {
        guard let format = format(texts[0], name: names[0]) ?? format(texts[1], name: names[1]) else {
            return (nil, "Prettify works on JSON and XML files")
        }
        var results: [String] = []
        for (text, name) in zip(texts, names) {
            guard let pretty = format == .json ? json(text) : xml(text) else {
                return (nil, "“\(name)” isn't valid \(format == .json ? "JSON" : "XML"), so it can't be prettified")
            }
            results.append(pretty)
        }
        return (results, "")
    }

    /// Indented, keys sorted. Numbers come back as JSONSerialization writes them (1.0 can become 1, say).
    static func json(_ text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Indented by XMLDocument (macOS only); external entities are never loaded.
    static func xml(_ text: String) -> String? {
        guard let document = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever]) else { return nil }
        return document.xmlString(options: [.nodePrettyPrint, .nodeCompactEmptyElement]) + "\n"
    }
}
