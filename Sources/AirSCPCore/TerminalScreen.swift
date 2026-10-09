import Foundation

/// The screen of AirSCP's own terminal (PLAN.md W): an xterm-compatible emulator of the parts that shells and
/// full-screen programs (less, vim, top, htop, nano, tmux) use: UTF-8 text, cursor movement, erasing, scroll regions,
/// inserting and deleting lines and characters, colours (16, 256 and 24-bit), bold, italic, underline, inverse, the
/// alternate screen, bracketed paste and application cursor keys. It also reads what the shell says about itself: the
/// window title (OSC 0/2), the current folder (OSC 7) and the shell's process id (AirSCP's own OSC 1337;AirSCPPid, sent
/// before the shell starts), and answers the cursor-position and device-attribute questions. Lines that scroll off the
/// top are kept as scrollback. Not thread-safe: one queue feeds and reads it.
public final class TerminalScreen {
    public enum Color: Equatable {
        case standard
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    public struct Attributes: Equatable {
        public var foreground = Color.standard
        public var background = Color.standard
        public var bold = false, dim = false, italic = false, underline = false, inverse = false
        public init() {}
    }

    public struct Cell: Equatable {
        public var character: Character = " "
        public var attributes = Attributes()
        /// The right half of a wide character (CJK, emoji): drawn by the cell before it.
        public var continuation = false
        public init(character: Character = " ", attributes: Attributes = Attributes()) {
            self.character = character
            self.attributes = attributes
        }
    }

    public struct Line: Equatable {
        public var cells: [Cell]
        /// The text goes on in the next line: it was wrapped, not broken by a line feed.
        public var wrapped = false
        init(columns: Int, attributes: Attributes = Attributes()) {
            cells = Array(repeating: Cell(attributes: Attributes.erased(attributes)), count: columns)
        }
        /// The line's text, trailing blanks left out.
        public var text: String {
            var text = String(cells.filter { !$0.continuation }.map(\.character))
            while text.last == " " { text.removeLast() }
            return text
        }
    }

    public private(set) var columns: Int
    public private(set) var rows: Int
    /// The lines on screen, top first.
    public private(set) var lines: [Line]
    /// Lines that scrolled off the top of the main screen, oldest first (the alternate screen keeps none).
    public private(set) var scrollback: [Line] = []
    public var scrollbackLimit = 10_000
    public private(set) var cursorX = 0, cursorY = 0
    public private(set) var cursorVisible = true
    /// Arrow keys send ESC O A… instead of ESC [ A… (DECCKM).
    public private(set) var applicationCursorKeys = false
    /// Pasted text goes between ESC [200~ and ESC [201~.
    public private(set) var bracketedPaste = false
    public private(set) var alternateScreen = false
    public private(set) var title = ""
    /// The shell's current folder, as OSC 7 last said ("file://host/path").
    public private(set) var directory: String?
    /// The shell's process id on the server, from AirSCP's start-up line.
    public private(set) var shellPID: Int?
    /// Answers to the program's questions (cursor position, device attributes), to write back to it.
    public var respond: (Data) -> Void = { _ in }
    /// Increments on every change, for a view to know when to draw again.
    public private(set) var generation = 0

    private var attributes = Attributes()
    private var autowrap = true, insertMode = false, originMode = false
    private var wrapPending = false
    private var top = 0, bottom: Int
    private var saved: (x: Int, y: Int, attributes: Attributes, origin: Bool)?
    private var mainScreen: (lines: [Line], x: Int, y: Int)?
    private var tabStops: Set<Int>

    // Parser state.
    private enum State { case ground, escape, escapeIntermediate, csi, osc, oscEscape, string, stringEscape }
    private var state = State.ground
    private var parameters = "", intermediates = "", osc = ""
    private var utf8: [UInt8] = [], utf8Needed = 0

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = max(columns, 2)
        self.rows = max(rows, 2)
        bottom = self.rows - 1
        lines = Array(repeating: Line(columns: self.columns), count: self.rows)
        tabStops = Set(stride(from: 8, to: self.columns, by: 8))
    }

    // MARK: Input

    public func feed(_ data: Data) {
        for byte in data { feed(byte) }
        generation &+= 1
    }

    public func feed(_ text: String) { feed(Data(text.utf8)) }

    private func feed(_ byte: UInt8) {
        // UTF-8 in text; control bytes and escape sequences are ASCII.
        if utf8Needed > 0 {
            if byte & 0xC0 == 0x80 {
                utf8.append(byte)
                utf8Needed -= 1
                if utf8Needed == 0 {
                    let scalar = String(decoding: utf8, as: UTF8.self)
                    utf8 = []
                    text(scalar)
                }
                return
            }
            utf8 = []
            utf8Needed = 0
            text("\u{FFFD}")
        }
        switch state {
        case .ground:
            if byte >= 0xC0 && byte < 0xF8 {
                utf8 = [byte]
                utf8Needed = byte >= 0xF0 ? 3 : byte >= 0xE0 ? 2 : 1
            } else if byte >= 0x80 {
                text("\u{FFFD}")
            } else if byte < 0x20 || byte == 0x7F {
                control(byte)
            } else {
                text(String(UnicodeScalar(byte)))
            }
        case .escape:
            escape(byte)
        case .escapeIntermediate:
            // ESC ( B and the like (character sets): nothing to do but take the final byte.
            if byte >= 0x30 { state = .ground }
        case .csi:
            if byte >= 0x30 && byte <= 0x3F {
                parameters.append(Character(UnicodeScalar(byte)))
            } else if byte >= 0x20 && byte <= 0x2F {
                intermediates.append(Character(UnicodeScalar(byte)))
            } else if byte >= 0x40 && byte <= 0x7E {
                state = .ground
                csi(Character(UnicodeScalar(byte)))
            } else if byte == 0x1B {
                state = .escape
            } else if byte < 0x20 {
                control(byte)  // as xterm does: a control byte in a sequence acts at once
            } else {
                state = .ground
            }
        case .osc:
            if byte == 0x07 {
                state = .ground
                operatingSystemCommand()
            } else if byte == 0x1B {
                state = .oscEscape
            } else if osc.utf8.count < 4096 {
                osc.unicodeScalars.append(UnicodeScalar(byte))
            }
        case .oscEscape:
            state = .ground
            if byte == 0x5C { operatingSystemCommand() }  // ESC \ (ST)
        case .string:
            if byte == 0x1B { state = .stringEscape } else if byte == 0x07 { state = .ground }
        case .stringEscape:
            state = byte == 0x5C ? .ground : .string
        }
    }

    private func control(_ byte: UInt8) {
        switch byte {
        case 0x07: break  // bell
        case 0x08:
            wrapPending = false
            cursorX = max(cursorX - 1, 0)
        case 0x09:
            cursorX = tabStops.filter { $0 > cursorX }.min() ?? columns - 1
        case 0x0A, 0x0B, 0x0C: index()
        case 0x0D:
            wrapPending = false
            cursorX = 0
        case 0x1B:
            state = .escape
            parameters = ""
            intermediates = ""
        default: break
        }
    }

    private func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case 0x5B:  // [
            state = .csi
            parameters = ""
            intermediates = ""
        case 0x5D:  // ]
            state = .osc
            osc = ""
        case 0x50, 0x58, 0x5E, 0x5F:  // DCS, SOS, PM, APC: skipped up to ST
            state = .string
        case 0x28, 0x29, 0x2A, 0x2B, 0x23, 0x25, 0x20:  // ( ) * + # % space: one more byte
            state = .escapeIntermediate
        case 0x37: saveCursor()  // 7
        case 0x38: restoreCursor()  // 8
        case 0x44: index()  // D
        case 0x45:  // E
            index()
            cursorX = 0
        case 0x48: tabStops.insert(cursorX)  // H
        case 0x4D: reverseIndex()  // M
        case 0x63: reset()  // c
        default: break  // = > (keypad) and others: nothing to draw
        }
    }

    // MARK: Text

    private func text(_ string: String) {
        for character in string {
            put(character)
        }
    }

    private func put(_ character: Character) {
        let width = Self.width(of: character)
        guard width > 0 else {
            // A combining mark: onto the character before it.
            let x = wrapPending ? cursorX : cursorX - 1
            if x >= 0 {
                let previous = lines[cursorY].cells[x].character
                lines[cursorY].cells[x].character = Character(String(previous) + String(character))
            }
            return
        }
        if wrapPending || cursorX + width > columns {
            if autowrap {
                lines[cursorY].wrapped = true
                index()
                cursorX = 0
            } else {
                cursorX = columns - width
            }
            wrapPending = false
        }
        if insertMode {
            var cells = lines[cursorY].cells
            cells.insert(contentsOf: Array(repeating: Cell(attributes: Attributes.erased(attributes)), count: width), at: cursorX)
            lines[cursorY].cells = Array(cells.prefix(columns))
        }
        lines[cursorY].cells[cursorX] = Cell(character: character, attributes: attributes)
        if width == 2 {
            var right = Cell(character: " ", attributes: attributes)
            right.continuation = true
            lines[cursorY].cells[cursorX + 1] = right
        }
        if cursorX + width >= columns {
            cursorX = columns - 1
            wrapPending = true
        } else {
            cursorX += width
        }
    }

    /// Columns a character takes: 2 for East Asian wide characters and emoji, 0 for combining marks.
    public static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        let value = scalar.value
        if character.unicodeScalars.count == 1, scalar.properties.generalCategory == .nonspacingMark
            || scalar.properties.generalCategory == .enclosingMark || value == 0x200B {
            return 0
        }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    // MARK: Scrolling

    /// Down one line, scrolling the region at its bottom.
    private func index() {
        wrapPending = false
        if cursorY == bottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        wrapPending = false
        if cursorY == top {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    private func blank() -> Line { Line(columns: columns, attributes: attributes) }

    private func scrollUp(_ count: Int) {
        let count = min(count, bottom - top + 1)
        for _ in 0..<count {
            let gone = lines.remove(at: top)
            if top == 0 && !alternateScreen {
                scrollback.append(gone)
                if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
            }
            lines.insert(blank(), at: bottom)
        }
    }

    private func scrollDown(_ count: Int) {
        let count = min(count, bottom - top + 1)
        for _ in 0..<count {
            lines.remove(at: bottom)
            lines.insert(blank(), at: top)
        }
    }

    // MARK: Control sequences

    private func numbers() -> [Int] {
        parameters.split(separator: ";", omittingEmptySubsequences: false).map { part in
            Int(part.split(separator: ":").first ?? "") ?? 0
        }
    }

    private func csi(_ final: Character) {
        let isPrivate = parameters.hasPrefix("?"), isSecondary = parameters.hasPrefix(">")
        if isPrivate || isSecondary || parameters.hasPrefix("=") { parameters.removeFirst() }
        let values = numbers()
        func value(_ index: Int, _ fallback: Int = 1) -> Int {
            index < values.count && values[index] != 0 ? values[index] : fallback
        }
        guard intermediates.isEmpty else { return }  // DECSCUSR (cursor style) and others: nothing to draw
        if final != "m" && final != "c" && final != "n" { wrapPending = false }
        switch final {
        case "@":
            let count = min(value(0), columns - cursorX)
            var cells = lines[cursorY].cells
            cells.insert(contentsOf: Array(repeating: Cell(attributes: Attributes.erased(attributes)), count: count), at: cursorX)
            lines[cursorY].cells = Array(cells.prefix(columns))
        case "A": cursorY = max(cursorY - value(0), cursorY >= top ? top : 0)
        case "B", "e": cursorY = min(cursorY + value(0), cursorY <= bottom ? bottom : rows - 1)
        case "C", "a": cursorX = min(cursorX + value(0), columns - 1)
        case "D": cursorX = max(cursorX - value(0), 0)
        case "E":
            cursorY = min(cursorY + value(0), bottom)
            cursorX = 0
        case "F":
            cursorY = max(cursorY - value(0), top)
            cursorX = 0
        case "G", "`": cursorX = min(max(value(0) - 1, 0), columns - 1)
        case "H", "f":
            let origin = originMode ? top : 0
            cursorY = min(max(origin + value(0) - 1, 0), originMode ? bottom : rows - 1)
            cursorX = min(max(value(1) - 1, 0), columns - 1)
        case "I":
            for _ in 0..<value(0) { cursorX = tabStops.filter { $0 > cursorX }.min() ?? columns - 1 }
        case "J": eraseDisplay(values.first ?? 0)
        case "K": eraseLine(values.first ?? 0)
        case "L":
            guard cursorY >= top && cursorY <= bottom else { break }
            for _ in 0..<min(value(0), bottom - cursorY + 1) {
                lines.remove(at: bottom)
                lines.insert(blank(), at: cursorY)
            }
            cursorX = 0
        case "M":
            guard cursorY >= top && cursorY <= bottom else { break }
            for _ in 0..<min(value(0), bottom - cursorY + 1) {
                lines.remove(at: cursorY)
                lines.insert(blank(), at: bottom)
            }
            cursorX = 0
        case "P":
            let count = min(value(0), columns - cursorX)
            var cells = lines[cursorY].cells
            cells.removeSubrange(cursorX..<(cursorX + count))
            cells += Array(repeating: Cell(attributes: Attributes.erased(attributes)), count: count)
            lines[cursorY].cells = cells
        case "S": scrollUp(value(0))
        case "T": if !isPrivate && values.count <= 1 { scrollDown(value(0)) }
        case "X":
            for x in cursorX..<min(cursorX + value(0), columns) {
                lines[cursorY].cells[x] = Cell(attributes: Attributes.erased(attributes))
            }
        case "Z":
            for _ in 0..<value(0) { cursorX = tabStops.filter { $0 < cursorX }.max() ?? 0 }
        case "b":
            // Repeats the character before the cursor.
            let x = max(cursorX - 1, 0)
            let character = lines[cursorY].cells[x].character
            for _ in 0..<min(value(0), columns * rows) { put(character) }
        case "c":
            // VT220 with colour; a secondary question (">") is told an xterm-like version.
            if values.first ?? 0 == 0, !isPrivate { respond(Data((isSecondary ? "\u{1B}[>1;10;0c" : "\u{1B}[?62;22c").utf8)) }
        case "d": cursorY = min(max(value(0) - 1, 0), rows - 1)
        case "g":
            if values.first ?? 0 == 3 { tabStops = [] } else { tabStops.remove(cursorX) }
        case "h", "l": setModes(values, private: isPrivate, on: final == "h")
        case "m": selectGraphicRendition(values)
        case "n":
            if values.first == 6 {
                respond(Data("\u{1B}[\(cursorY - (originMode ? top : 0) + 1);\(cursorX + 1)R".utf8))
            } else if values.first == 5 {
                respond(Data("\u{1B}[0n".utf8))
            }
        case "r":
            guard !isPrivate else { break }
            let newTop = value(0) - 1, newBottom = min(value(1, rows), rows) - 1
            if newTop < newBottom {
                top = newTop
                bottom = newBottom
                cursorX = 0
                cursorY = originMode ? top : 0
            }
        case "s": if !isPrivate { saveCursor() }
        case "u": if !isPrivate { restoreCursor() }
        default: break
        }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for y in (cursorY + 1)..<rows { lines[y] = blank() }
        case 1:
            eraseLine(1)
            for y in 0..<cursorY { lines[y] = blank() }
        case 2:
            for y in 0..<rows { lines[y] = blank() }
        case 3:
            scrollback = []
        default: break
        }
    }

    private func eraseLine(_ mode: Int) {
        let range: Range<Int>
        switch mode {
        case 0: range = cursorX..<columns
        case 1: range = 0..<min(cursorX + 1, columns)
        default: range = 0..<columns
        }
        for x in range { lines[cursorY].cells[x] = Cell(attributes: Attributes.erased(attributes)) }
        if mode != 1 { lines[cursorY].wrapped = false }
    }

    private func setModes(_ values: [Int], private isPrivate: Bool, on: Bool) {
        for mode in values {
            switch (isPrivate, mode) {
            case (false, 4): insertMode = on
            case (true, 1): applicationCursorKeys = on
            case (true, 6):
                originMode = on
                cursorX = 0
                cursorY = on ? top : 0
            case (true, 7): autowrap = on
            case (true, 25): cursorVisible = on
            case (true, 47), (true, 1047): switchScreen(alternate: on, saveCursor: false)
            case (true, 1049): switchScreen(alternate: on, saveCursor: true)
            case (true, 2004): bracketedPaste = on
            default: break
            }
        }
    }

    private func switchScreen(alternate: Bool, saveCursor keep: Bool) {
        guard alternate != alternateScreen else { return }
        if alternate {
            mainScreen = (lines, cursorX, cursorY)
            lines = Array(repeating: Line(columns: columns), count: rows)
            alternateScreen = true
        } else if let main = mainScreen {
            lines = main.lines
            if keep {
                cursorX = min(main.x, columns - 1)
                cursorY = min(main.y, rows - 1)
            }
            mainScreen = nil
            alternateScreen = false
        }
        top = 0
        bottom = rows - 1
        wrapPending = false
    }

    private func selectGraphicRendition(_ values: [Int]) {
        var index = 0
        let values = values.isEmpty ? [0] : values
        func color(_ index: inout Int) -> Color? {
            guard index + 1 < values.count else { return nil }
            if values[index + 1] == 5, index + 2 < values.count {
                index += 2
                return .indexed(UInt8(clamping: values[index]))
            }
            if values[index + 1] == 2, index + 4 < values.count {
                index += 4
                return .rgb(UInt8(clamping: values[index - 2]), UInt8(clamping: values[index - 1]), UInt8(clamping: values[index]))
            }
            return nil
        }
        while index < values.count {
            let code = values[index]
            switch code {
            case 0: attributes = Attributes()
            case 1: attributes.bold = true
            case 2: attributes.dim = true
            case 3: attributes.italic = true
            case 4: attributes.underline = true
            case 7: attributes.inverse = true
            case 21, 22: attributes.bold = false; attributes.dim = false
            case 23: attributes.italic = false
            case 24: attributes.underline = false
            case 27: attributes.inverse = false
            case 30...37: attributes.foreground = .indexed(UInt8(code - 30))
            case 38: if let color = color(&index) { attributes.foreground = color }
            case 39: attributes.foreground = .standard
            case 40...47: attributes.background = .indexed(UInt8(code - 40))
            case 48: if let color = color(&index) { attributes.background = color }
            case 49: attributes.background = .standard
            case 90...97: attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: attributes.background = .indexed(UInt8(code - 100 + 8))
            default: break
            }
            index += 1
        }
    }

    private func operatingSystemCommand() {
        let parts = osc.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = parts.first else { return }
        let value = parts.count > 1 ? String(parts[1]) : ""
        switch code {
        case "0", "2": title = value
        case "7":
            // file://host/path, the path percent-encoded.
            if let url = URL(string: value), url.scheme == "file" {
                directory = url.path.isEmpty ? "/" : url.path
            } else if value.hasPrefix("/") {
                directory = value
            }
        case "1337":
            if value.hasPrefix("AirSCPPid="), let pid = Int(value.dropFirst("AirSCPPid=".count)) { shellPID = pid }
        default: break
        }
    }

    // MARK: Cursor and reset

    private func saveCursor() { saved = (cursorX, cursorY, attributes, originMode) }

    private func restoreCursor() {
        guard let saved else {
            cursorX = 0
            cursorY = 0
            return
        }
        cursorX = min(saved.x, columns - 1)
        cursorY = min(saved.y, rows - 1)
        attributes = saved.attributes
        originMode = saved.origin
        wrapPending = false
    }

    private func reset() {
        attributes = Attributes()
        lines = Array(repeating: Line(columns: columns), count: rows)
        cursorX = 0
        cursorY = 0
        top = 0
        bottom = rows - 1
        autowrap = true
        insertMode = false
        originMode = false
        cursorVisible = true
        applicationCursorKeys = false
        bracketedPaste = false
        alternateScreen = false
        mainScreen = nil
        wrapPending = false
        tabStops = Set(stride(from: 8, to: columns, by: 8))
    }

    /// A new size: lines are cut or padded (not re-wrapped); a shorter screen sends its top lines to the scrollback,
    /// keeping the cursor's line on screen.
    public func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(newColumns, 2), newRows = max(newRows, 2)
        guard newColumns != columns || newRows != rows else { return }
        func fit(_ line: Line) -> Line {
            var line = line
            if line.cells.count > newColumns {
                line.cells = Array(line.cells.prefix(newColumns))
            } else {
                line.cells += Array(repeating: Cell(), count: newColumns - line.cells.count)
            }
            return line
        }
        lines = lines.map(fit)
        scrollback = scrollback.map(fit)
        if newRows < rows {
            let extra = rows - newRows
            let fromTop = min(extra, max(cursorY - newRows + 1, 0))
            let gone = lines.prefix(fromTop)
            if !alternateScreen { scrollback += gone }
            lines.removeFirst(fromTop)
            lines.removeLast(extra - fromTop)
            cursorY -= fromTop
        } else if newRows > rows {
            // Lines come back from the scrollback first, as a shell's output grows down.
            let back = alternateScreen ? 0 : min(newRows - rows, scrollback.count)
            lines.insert(contentsOf: scrollback.suffix(back), at: 0)
            scrollback.removeLast(back)
            cursorY += back
            lines += Array(repeating: Line(columns: newColumns), count: newRows - rows - back)
        }
        mainScreen = mainScreen.map { (($0.lines.map(fit) + Array(repeating: Line(columns: newColumns), count: max(newRows - $0.lines.count, 0))).prefix(newRows).map { $0 }, min($0.x, newColumns - 1), min($0.y, newRows - 1)) }
        columns = newColumns
        rows = newRows
        cursorX = min(cursorX, columns - 1)
        cursorY = min(max(cursorY, 0), rows - 1)
        top = 0
        bottom = rows - 1
        wrapPending = false
        tabStops = Set(stride(from: 8, to: columns, by: 8))
        generation &+= 1
    }

    // MARK: Reading

    /// Every line, the scrollback's first, then the screen's.
    public var allLines: [Line] { scrollback + lines }

    /// The text of every line (scrollback and screen), wrapped lines joined, trailing blank lines left out.
    public var text: String {
        var result: [String] = [], current = ""
        for line in allLines {
            current += line.wrapped ? String(line.cells.filter { !$0.continuation }.map(\.character)) : line.text
            if !line.wrapped {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    /// The word at a column of a line of `allLines` that looks like a path or a file name, as `ls`, `find`, `grep`
    /// and compilers print them: split at blanks and quotes, without the punctuation around it, and without a
    /// trailing ":12" or ":12:5" (a line and column). nil on a blank.
    public func path(atLine index: Int, column: Int) -> String? {
        let all = allLines
        guard all.indices.contains(index) else { return nil }
        // A wrapped word goes on in the next line.
        var characters: [Character] = [], offset = 0
        var first = index
        while first > 0 && all[first - 1].wrapped { first -= 1 }
        var last = index
        while last < all.count - 1 && all[last].wrapped { last += 1 }
        for line in first...last {
            if line == index { offset = characters.count + all[line].cells.prefix(column).filter { !$0.continuation }.count }
            characters += all[line].cells.filter { !$0.continuation }.map(\.character)
        }
        return Self.path(in: characters, at: offset)
    }

    static func path(in characters: [Character], at offset: Int) -> String? {
        let stops: Set<Character> = [" ", "\t", "\"", "'", "`", "(", ")", "[", "]", "{", "}", "<", ">", "|", ",", ";", "="]
        guard characters.indices.contains(offset), !stops.contains(characters[offset]) else { return nil }
        var start = offset, end = offset
        while start > 0 && !stops.contains(characters[start - 1]) { start -= 1 }
        while end < characters.count - 1 && !stops.contains(characters[end + 1]) { end += 1 }
        var word = String(characters[start...end])
        // "file.c:12:5:" and "path:" (grep -n, compilers, ls -R headers)
        while let range = word.range(of: #":[0-9]*$"#, options: .regularExpression) { word.removeSubrange(range) }
        while let last = word.last, ".:!?".contains(last), word.count > 1 { word.removeLast() }
        guard !word.isEmpty, word != "." || characters[offset] == "." else { return nil }
        return word
    }
}

extension TerminalScreen.Attributes {
    /// What an erased cell keeps: the background colour (as xterm does), nothing else.
    static func erased(_ attributes: Self) -> Self {
        var erased = Self()
        erased.background = attributes.background
        return erased
    }
}
