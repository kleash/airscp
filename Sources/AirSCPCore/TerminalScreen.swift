import Foundation

/// The screen of AirSCP's own terminal: an xterm-compatible emulator of the parts that shells and full-screen programs
/// (less, vim, top, htop, nano, tmux) use: UTF-8 text, cursor movement, erasing, scroll regions, inserting and deleting
/// lines and characters, colours (16, 256 and 24-bit), bold, italic, underline, inverse, the alternate screen,
/// bracketed paste and application cursor keys. It also reads what the shell says about itself: the window title
/// (OSC 0/2), the current folder (OSC 7), the shell's process id (AirSCP's own OSC 1337;AirSCPPid, sent before the shell
/// starts) and where each command starts and ends (OSC 133, see `Mark`), and answers the cursor-position and
/// device-attribute questions. Lines that scroll off the top are kept as scrollback. Not thread-safe: one queue feeds
/// and reads it.
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
        /// What the shell marked on this line, in the order it came. Marks travel with their line (into the
        /// scrollback, through a resize) and go when it is erased away.
        public var marks: [Mark] = []
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

    /// A place in `allLines`: a line and a column (a cell).
    public struct Position: Comparable {
        public var line: Int
        public var column: Int
        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
        public static func < (a: Position, b: Position) -> Bool { (a.line, a.column) < (b.line, b.column) }
    }

    /// A shell integration mark (OSC 133, as the shell AirSCP starts sends them): its prompt starts (A), what is typed
    /// starts (B), the command's output starts (C), the command ended (D, with its exit status); and what is typed goes
    /// on after a continuation prompt (B with k=s: bash's PS2, "> "). They count only when signed with `markToken`,
    /// which output that imitates them can't know.
    public struct Mark: Equatable {
        public enum Kind: Equatable { case prompt, command, output, end, continuation }
        public var kind: Kind
        public var column: Int
        public var time: Date
        /// end: the command's exit status.
        public var status: Int32?
        /// output: the command line, as the shell said it or (when it didn't) as the screen showed it then, before
        /// any of the command's own output could draw over it, without its continuation prompts.
        public var command: String?
    }

    /// A command the shell ran, from its marks: where its prompt, its command line, its output and its end are.
    public struct Block: Equatable {
        /// The line of its prompt.
        public var prompt: Int
        /// Where the command was typed.
        public var command: Position?
        /// Where its output starts; nil when the shell doesn't say (bash before 4.4).
        public var output: Position?
        /// Where it ended (the next prompt comes after); nil while it runs.
        public var end: Position?
        /// The command line, as typed (`commandLine`).
        public var text = ""
        public var status: Int32?
        public var started: Date?, ended: Date?
        /// Its last line: the line before the next prompt's, or the cursor's while it runs.
        public var lastLine: Int

        public var running: Bool { end == nil }
        public var duration: TimeInterval? { started.flatMap { start in ended.map { $0.timeIntervalSince(start) } } }
        /// It holds `line`.
        public func contains(_ line: Int) -> Bool { line >= prompt && line <= lastLine }
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
    /// The shell's current folder, as OSC 7 last said ("file://host/path"; signed with `markToken` when there is one).
    public private(set) var directory: String?
    /// The shell's process id on the server, from AirSCP's start-up line.
    public private(set) var shellPID: Int?
    /// The token the shell AirSCP started signs its marks and its folder with (`Mark`, `directory`); nil: no marks are
    /// taken.
    public var markToken: String?
    /// The shell has sent a mark: it marks its prompts and commands.
    public private(set) var marksCommands = false
    /// The shell has marked where a command's output starts: from then on a prompt left without one ran nothing (an
    /// empty line, a line given up with ⌃C).
    public private(set) var marksOutput = false
    /// Answers to the program's questions (cursor position, device attributes), to write back to it.
    public var respond: (Data) -> Void = { _ in }
    /// Each command the shell marked, once it has ended: its line as typed (`Block.text`), for the host's history.
    public var onCommand: (String) -> Void = { _ in }
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
    private var parameters = "", intermediates = ""
    /// An OSC's bytes (UTF-8), and whether some were left out (it was longer than 4096).
    private var osc: [UInt8] = [], oscCut = false
    /// When the bytes being fed came.
    private var arrived = Date()
    private var utf8: [UInt8] = [], utf8Needed = 0

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = max(columns, 2)
        self.rows = max(rows, 2)
        bottom = self.rows - 1
        lines = Array(repeating: Line(columns: self.columns), count: self.rows)
        tabStops = Set(stride(from: 8, to: self.columns, by: 8))
    }

    // MARK: Input

    /// What the program wrote; `arrived`: when it came, the time of the command marks in it (a command's time is
    /// measured from them, whenever the main thread gets to the bytes).
    public func feed(_ data: Data, arrived: Date = Date()) {
        self.arrived = arrived
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
            } else if osc.count < 4096 {
                osc.append(byte)
            } else {
                oscCut = true
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
        case 0x0A, 0x0B, 0x0C:
            // Into a blank line, a line feed ends the line it leaves (moving down a long command line, readline comes
            // into the rest of it). At Return after a command line that ends at the right edge, bash 3.2's readline
            // (with marks in its prompt) goes back up from the blank it wrapped onto and down again without the erase
            // newer ones send: the command's output would read as its line going on.
            if lines[cursorY].wrapped, cursorY + 1 < rows, lines[cursorY + 1].text.isEmpty { lines[cursorY].wrapped = false }
            index()
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
            osc = []
            oscCut = false
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
        let text = String(decoding: osc, as: UTF8.self)
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = parts.first else { return }
        let value = parts.count > 1 ? String(parts[1]) : ""
        switch code {
        case "0", "2": title = value
        case "7":
            // file://host/path, the path percent-encoded (the shell AirSCP starts encodes only "%": spaces and other
            // letters come as they are, which URL(string:) refuses). A path cut short would be another folder. With a
            // `markToken`, only the shell's own word, signed as its marks are: a folder that a program's output names (a
            // file shown, say) would move Follow in Files there.
            var path = Substring(value)
            if let token = markToken {
                guard path.hasSuffix(";airscp=" + token) else { break }
                path = path.dropLast(";airscp=".count + token.count)
            }
            if path.hasPrefix("file://") {
                path = path.dropFirst("file://".count)
                path = path[(path.firstIndex(of: "/") ?? path.endIndex)...]
            }
            if path.hasPrefix("/"), !oscCut { directory = path.removingPercentEncoding ?? String(path) }
        case "133": mark(value)
        case "1337":
            if value.hasPrefix("AirSCPPid="), let pid = Int(value.dropFirst("AirSCPPid=".count)) { shellPID = pid }
        default: break
        }
    }

    /// An OSC 133 mark ("A;airscp=<token>", "B;…", "B;k=s;…", "C;airscp=<token>[;cmdline=<the command line>]",
    /// "D;<status>;…") at the cursor. A prompt drawn again (after a resize, say) takes the place of the one on its line.
    private func mark(_ value: String) {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard let token = markToken, let kind = fields.first else { return }
        var signed = false, continuation = false, status: Int32?, command: String?
        for (index, field) in fields.enumerated().dropFirst() {
            if field.hasPrefix("cmdline=") {
                // The rest, ";" and all; a line break came through the terminal as CR LF. Not when cut short.
                let rest = fields[index...].joined(separator: ";").dropFirst("cmdline=".count)
                if !oscCut { command = rest.replacingOccurrences(of: "\r\n", with: "\n") }
                break
            }
            if field == "airscp=" + token {
                signed = true
            } else if field == "k=s" {
                continuation = true
            } else if kind == "D", index == 1 {
                status = Int32(field)
            }
        }
        let kinds: [Substring: Mark.Kind] = ["A": .prompt, "B": continuation ? .continuation : .command, "C": .output, "D": .end]
        guard signed, let markKind = kinds[kind] else { return }
        var mark = Mark(kind: markKind, column: cursorX + (wrapPending ? 1 : 0), time: arrived, status: status)
        switch markKind {
        case .prompt: lines[cursorY].marks.removeAll { $0.kind == .prompt || $0.kind == .command }
        case .command, .continuation: lines[cursorY].marks.removeAll { $0.kind == markKind }
        case .output:
            // What was typed, as the screen shows it now, when the shell didn't say (bash).
            if command?.isEmpty ?? true { command = typedStart().map { typed(from: $0, to: cursorPosition) } }
            mark.command = command.map(Self.commandLine)
            marksOutput = true
        case .end: break
        }
        lines[cursorY].marks.append(mark)
        marksCommands = true
        // The command this ends, if one ran (a prompt left with an empty line or ⌃C ends none).
        if markKind == .end, let block = blocks.last, block.end == Position(line: scrollback.count + cursorY, column: mark.column) {
            onCommand(block.text)
        }
    }

    /// A command line as typed, without the line breaks around it and the blanks after it. The blanks before it stay: the
    /// shells keep a command typed after a space out of their history, and AirSCP's history does too.
    static func commandLine(_ typed: String) -> String {
        var line = typed.trimmingCharacters(in: .newlines)
        while line.last?.isWhitespace == true { line.removeLast() }
        return line
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

    /// The cursor, as a place in `allLines`.
    public var cursorPosition: Position { Position(line: scrollback.count + cursorY, column: cursorX + (wrapPending ? 1 : 0)) }

    /// The text from `start` up to (not including) `end`: wrapped lines joined, a line break after the others, each
    /// line's trailing blanks left out.
    public func text(from start: Position, to end: Position) -> String {
        let all = allLines
        guard start < end, start.line < all.count else { return "" }
        var text = ""
        for index in start.line...min(end.line, all.count - 1) {
            let cells = all[index].cells
            let low = index == start.line ? start.column : 0, high = index == end.line ? min(end.column, cells.count) : cells.count
            var part = low < high ? String(cells[low..<high].filter { !$0.continuation }.map(\.character)) : ""
            let wrapped = all[index].wrapped && index != end.line
            if !wrapped { while part.last == " " { part.removeLast() } }
            text += part
            if !wrapped && index < end.line && index < all.count - 1 { text += "\n" }
        }
        return text
    }

    /// Where what is typed at the current prompt starts: its command mark, when no other mark came after it (but the
    /// continuation prompts of the lines it goes on in).
    private func typedStart() -> Position? {
        let all = allLines
        for index in stride(from: min(scrollback.count + cursorY, all.count - 1), through: max(0, scrollback.count + cursorY - 500), by: -1) {
            guard let mark = all[index].marks.last(where: { $0.kind != .continuation }) else { continue }
            return mark.kind == .command ? Position(line: index, column: mark.column) : nil
        }
        return nil
    }

    /// What was typed from `start` up to `end`, as `text(from:to:)` reads it, without the continuation prompts of the
    /// lines that have one: a command of several lines as it was typed.
    private func typed(from start: Position, to end: Position) -> String {
        let all = allLines
        var typed = "", from = start
        for index in stride(from: start.line + 1, through: min(end.line, all.count - 1), by: 1) {
            guard let mark = all[index].marks.last(where: { $0.kind == .continuation }) else { continue }
            typed += text(from: from, to: Position(line: index, column: 0))
            from = Position(line: index, column: mark.column)
        }
        return typed + text(from: from, to: end)
    }

    /// The shell waits at its prompt with nothing typed before the cursor (as its marks say): a command typed now
    /// runs in the shell, not in a program.
    public var waitsAtPrompt: Bool {
        guard !alternateScreen, let start = typedStart() else { return false }
        return text(from: start, to: cursorPosition).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What is typed before the cursor: at a prompt the shell marks, from where typing starts; else the cursor's line
    /// (with the lines it wraps on from), prompt and all. A blank just before the cursor is kept: the word there is empty.
    public var typedBeforeCursor: String {
        let all = allLines, cursor = cursorPosition
        var start = Position(line: cursor.line, column: 0)
        if let typed = typedStart() {
            start = typed
        } else {
            while start.line > 0 && all[start.line - 1].wrapped { start.line -= 1 }
        }
        let cells = all[cursor.line].cells
        let blank = cursor.column > 0 && cursor.column <= cells.count && cells[cursor.column - 1].character == " "
        return text(from: start, to: cursor) + (blank ? " " : "")
    }

    /// The commands the shell marked, oldest first, with the one running. A prompt where nothing ran (an empty line, a
    /// line given up) is left out, as are marks left without their prompt (the screen was cleared).
    public var blocks: [Block] {
        let all = allLines, cursor = cursorPosition
        var blocks: [Block] = [], current: Block?
        func close() {
            guard var block = current else { return }
            current = nil
            if block.output == nil, let command = block.command {
                // The shell doesn't mark output (bash before 4.4): the command is its line, and the lines it went on in
                // after a continuation prompt, if it ended.
                guard !marksOutput, let end = block.end else { return }
                let last = (command.line...max(command.line, end.line)).last { all[$0].marks.contains { $0.kind == .continuation } }
                    ?? command.line
                block.text = Self.commandLine(typed(from: command, to: Position(line: lineEnd(last, in: all), column: Int.max)))
            }
            guard block.output != nil || block.command != nil, !block.text.isEmpty else { return }
            if let end = block.end {
                block.lastLine = max(end.column == 0 ? end.line - 1 : end.line, block.command?.line ?? block.prompt)
            } else {
                block.lastLine = max(cursor.line, block.prompt)
            }
            blocks.append(block)
        }
        for (index, line) in all.enumerated() {
            for mark in line.marks {
                let at = Position(line: index, column: mark.column)
                switch mark.kind {
                case .prompt:
                    close()
                    current = Block(prompt: index, lastLine: index)
                case .command:
                    if current == nil || current?.output != nil || current?.command != nil { close() }
                    if current == nil { current = Block(prompt: index, lastLine: index) }
                    current?.command = at
                case .output:
                    if current == nil || current?.output != nil { close() }
                    if current == nil { current = Block(prompt: index, lastLine: index) }
                    current?.output = at
                    current?.started = mark.time
                    current?.text = mark.command ?? ""
                case .end:
                    guard current != nil else { continue }
                    current?.end = at
                    current?.status = mark.status
                    current?.ended = mark.time
                    close()
                case .continuation:
                    continue
                }
            }
        }
        // The one running; a prompt still waiting for a command isn't one.
        if current?.output != nil { close() }
        return blocks
    }

    /// The last line of the wrapped lines that `line` starts or is part of.
    private func lineEnd(_ line: Int, in all: [Line]) -> Int {
        var last = line
        while last < all.count - 1 && all[last].wrapped { last += 1 }
        return last
    }

    /// A block's output (up to the cursor while it runs). Without its output mark: from the line after its command.
    public func output(of block: Block) -> String {
        let all = allLines
        let start = block.output ?? block.command.map { Position(line: lineEnd($0.line, in: all) + 1, column: 0) }
            ?? Position(line: block.prompt + 1, column: 0)
        return text(from: start, to: block.end ?? cursorPosition).trimmingCharacters(in: .newlines)
    }

    /// Where `needle` is in every line (scrollback and screen), ignoring case: each match's first cell and the cell after
    /// its last, oldest first. A match may go on into a wrapped line.
    public func find(_ needle: String) -> [(start: Position, end: Position)] {
        guard !needle.isEmpty else { return [] }
        let all = allLines
        var matches: [(start: Position, end: Position)] = []
        var index = 0
        while index < all.count {
            // A line and the lines it wraps into, as text, with each character's cell (and one past the end).
            var characters: [Character] = [], places: [Position] = []
            let last = lineEnd(index, in: all)
            for line in index...last {
                for (column, cell) in all[line].cells.enumerated() where !cell.continuation {
                    characters.append(cell.character)
                    places.append(Position(line: line, column: column))
                }
            }
            places.append(Position(line: last, column: all[last].cells.count))
            index = last + 1
            // Most lines don't have it: Foundation says so quickly. In those that do, character by character (cells
            // put side by side can join into one character in a String, a flag's two halves, say).
            guard String(characters).range(of: needle, options: .caseInsensitive) != nil else { continue }
            let lowered = characters.map { $0.lowercased() }, wanted = needle.map { $0.lowercased() }
            var start = 0
            while start + wanted.count <= lowered.count {
                if lowered[start..<(start + wanted.count)].elementsEqual(wanted) {
                    matches.append((places[start], places[start + wanted.count]))
                    start += wanted.count
                } else {
                    start += 1
                }
            }
        }
        return matches
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
