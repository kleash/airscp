import AirSCPCore
import SwiftUI
import UIKit

/// The shown shell's screen (Core's `TerminalScreen`), drawn cell by cell as the Mac's TerminalView draws it: colours,
/// bold, the cursor. Typing goes to the shell (UIKeyInput), and so do a hardware keyboard's arrows, Escape, Tab and
/// Control keys. A drag goes through the scrollback (full-screen programs get arrow keys), a pinch changes the size, and
/// the shell's terminal gets the columns and rows that fit.
final class TerminalView: UIView, UIKeyInput {
    /// The Mac's key codes that `TerminalSession.keys` takes; `anyKey` is none of them: the characters count.
    static let returnKey: UInt16 = 36, anyKey = UInt16.max
    static let fontSizeKey = "terminalFontSize"

    private weak var terminals: Terminals?
    var session: TerminalSession? {
        didSet {
            showLive()
            resizeShell()  // a shell kept its size while another was shown
        }
    }
    private var font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var cellWidth: CGFloat = 8, cellHeight: CGFloat = 17
    private let inset: CGFloat = 6
    /// Lines up from the bottom of the scrollback that the view shows (0: the live screen).
    private var scrollOffset = 0
    /// The scrollback's length when output last came: lines that come while scrolled back keep what is read in place.
    private var scrollbackSeen = 0
    /// Where a drag or a pinch started: the offset, the arrow keys sent for it, the font size.
    private var dragStart = (offset: 0, sent: 0), pinchStart: CGFloat = 13

    init(terminals: Terminals) {
        self.terminals = terminals
        super.init(frame: .zero)
        let size = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        setFontSize(size > 0 ? size : 13)
        backgroundColor = Self.ground
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityHint = "Tap to type in the shell; drag to scroll back, pinch to change the text size"
        accessibilityIdentifier = "terminal"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1  // two are a pinch
        addGestureRecognizer(drag)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var accessibilityValue: String? {
        get { session?.screen.text }
        set {}
    }

    /// Columns and rows that fit (80 × 24 before the view has a size).
    var gridSize: (columns: Int, rows: Int) {
        guard bounds.width > 0, bounds.height > 0 else { return (80, 24) }
        return (max(Int((bounds.width - 2 * inset) / cellWidth), 20), max(Int((bounds.height - 2 * inset) / cellHeight), 5))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resizeShell()
    }

    private func resizeShell() {
        guard let session, bounds.width > 0 else { return }
        let size = gridSize
        if size.columns != session.screen.columns || size.rows != session.screen.rows {
            session.resize(columns: size.columns, rows: size.rows)
        }
        setNeedsDisplay()
    }

    private func setFontSize(_ size: CGFloat) {
        font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        // The font's own advance, not rounded: a run of text is drawn as one string, and the cursor must stay under it.
        cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        cellHeight = ceil(font.lineHeight) + 2
        resizeShell()
    }

    /// New output: drawn; while scrolled back, what is read stays in place and the lines that came are counted.
    func screenChanged() {
        if let screen = session?.screen {
            let grown = screen.scrollback.count - scrollbackSeen
            scrollbackSeen = screen.scrollback.count
            if scrollOffset > 0 && grown < 0 { return showLive() }  // the scrollback was cleared
            if scrollOffset > 0 && grown > 0 {
                scrollOffset = min(scrollOffset + grown, screen.scrollback.count)
                terminals?.newLines += grown
            }
        }
        setNeedsDisplay()
    }

    /// The live screen again.
    func showLive() {
        scrollOffset = 0
        scrollbackSeen = session?.screen.scrollback.count ?? 0
        if terminals?.newLines != 0 { terminals?.newLines = 0 }
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        Self.ground.setFill()
        UIRectFill(bounds)
        guard let screen = session?.screen else { return }
        // The lines shown: the screen's last `rows` of the scrollback and the screen, `scrollOffset` up from the end.
        let back = screen.scrollback.count, total = back + screen.lines.count
        let last = max(total - scrollOffset, 0), first = max(last - screen.rows, 0)
        let cursorLine = back + screen.cursorY
        for (row, index) in (first..<last).enumerated() {
            let line = index < back ? screen.scrollback[index] : screen.lines[index - back]
            let y = inset + CGFloat(row) * cellHeight
            var x = 0
            while x < line.cells.count {
                // A run of cells that look alike, drawn as one string (the font is monospaced).
                let cell = line.cells[x]
                var run = String(cell.character), end = x + 1
                let ascii = cell.character.isASCII
                while ascii, end < line.cells.count, line.cells[end].attributes == cell.attributes,
                      line.cells[end].character.isASCII, !line.cells[end].continuation {
                    run.append(line.cells[end].character)
                    end += 1
                }
                if end < line.cells.count && line.cells[end].continuation { end += 1 }  // a wide character's right half
                draw(run, attributes: cell.attributes, in: CGRect(x: inset + CGFloat(x) * cellWidth, y: y,
                                                                  width: CGFloat(end - x) * cellWidth, height: cellHeight))
                x = end
            }
            // The cursor: a block while the terminal has the keyboard, an outline otherwise.
            if index == cursorLine, screen.cursorVisible {
                let cursor = CGRect(x: inset + CGFloat(screen.cursorX) * cellWidth, y: y, width: cellWidth, height: cellHeight)
                tintColor.withAlphaComponent(0.8).set()
                if isFirstResponder { UIRectFillUsingBlendMode(cursor, .normal) } else { UIRectFrame(cursor) }
            }
        }
    }

    private func draw(_ text: String, attributes: TerminalScreen.Attributes, in rect: CGRect) {
        var foreground = Self.color(attributes.foreground, foreground: true, bold: attributes.bold)
        var background = attributes.background == .standard ? nil : Self.color(attributes.background, foreground: false, bold: false)
        if attributes.inverse {
            let swapped = background ?? Self.ground
            background = foreground
            foreground = swapped
        }
        if let background {
            background.setFill()
            UIRectFill(rect)
        }
        if attributes.dim { foreground = foreground.withAlphaComponent(0.6) }
        guard text.contains(where: { $0 != " " }) || attributes.underline else { return }
        var drawn = attributes.bold ? boldFont : font
        if attributes.italic, let italic = drawn.fontDescriptor.withSymbolicTraits(.traitItalic) {
            drawn = UIFont(descriptor: italic, size: drawn.pointSize)
        }
        var drawing: [NSAttributedString.Key: Any] = [.font: drawn, .foregroundColor: foreground]
        if attributes.underline { drawing[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        (text as NSString).draw(at: CGPoint(x: rect.minX, y: rect.minY + 1), withAttributes: drawing)
    }

    /// The Mac's terminal ground: near black in dark mode, near white in light.
    static let ground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 1) : UIColor(white: 0.99, alpha: 1) }

    /// The 16 colours as the Mac's terminal has them (Terminal.app's Basic profile, lighter in dark mode), then xterm's
    /// cube and greys.
    static func color(_ color: TerminalScreen.Color, foreground: Bool, bold: Bool) -> UIColor {
        switch color {
        case .standard: return foreground ? .label : ground
        case .rgb(let r, let g, let b):
            return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .indexed(let index):
            let index = Int(index)
            if index < 16 {
                let palette: [UIColor] = [.black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple,
                                          .systemCyan, UIColor(white: 0.75, alpha: 1), .systemGray, .systemRed, .systemGreen,
                                          .systemYellow, .systemBlue, .systemPink, .systemTeal, .white]
                let chosen = palette[bold && index < 8 ? index + 8 : index]
                // Black and white text stay readable on the other appearance's ground.
                if index == 0 || index == 15 || index == 7 {
                    return UIColor { traits in
                        let dark = traits.userInterfaceStyle == .dark
                        if index == 0 { return dark ? UIColor(white: 0.35, alpha: 1) : .black }
                        return dark ? chosen : UIColor(white: index == 15 ? 0.2 : 0.35, alpha: 1)
                    }
                }
                return chosen
            }
            if index < 232 {
                let cube = index - 16, levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
                return UIColor(red: levels[cube / 36] / 255, green: levels[cube / 6 % 6] / 255, blue: levels[cube % 6] / 255,
                               alpha: 1)
            }
            return UIColor(white: (8 + CGFloat(index - 232) * 10) / 255, alpha: 1)
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { terminals?.typing = true }
        setNeedsDisplay()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { terminals?.typing = false }
        setNeedsDisplay()
        return resigned
    }

    var hasText: Bool { true }  // Delete always goes to the shell, which knows what is typed
    var autocapitalizationType = UITextAutocapitalizationType.none
    var autocorrectionType = UITextAutocorrectionType.no
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var inlinePredictionType = UITextInlinePredictionType.no

    func insertText(_ text: String) {
        guard let session else { return }
        guard session.running else {
            if text == "\n", let terminal = terminals?.shown { terminals?.restart(terminal) }  // Return: a new shell
            return
        }
        var keys = text.replacingOccurrences(of: "\n", with: "\r")
        if terminals?.ctrl == true, let first = keys.first {
            terminals?.ctrl = false
            keys = (TerminalSession.keys(keyCode: Self.anyKey, characters: String(first), control: true, option: false,
                                         shift: false, applicationCursor: false) ?? String(first)) + keys.dropFirst()
        }
        showLive()
        session.send(keys)
    }

    func deleteBackward() {
        guard let session, session.running else { return }
        showLive()
        session.send("\u{7F}")
    }

    /// A hardware keyboard: the keys typing doesn't bring (arrows, Escape, Tab, Home…, Control combinations) go to the
    /// shell here; the rest goes on to `insertText` and ⌘ shortcuts.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let session, session.running else { return super.pressesBegan(presses, with: event) }
        var others = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let keys = Self.keys(for: key, applicationCursor: session.screen.applicationCursorKeys)
            else {
                others.insert(press)
                continue
            }
            showLive()
            session.send(keys)
        }
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    /// What a hardware key sends, for the keys `pressesBegan` takes; nil for the others.
    static func keys(for key: UIKey, applicationCursor: Bool) -> String? {
        let flags = key.modifierFlags
        guard !flags.contains(.command) else { return nil }
        // The Mac's key codes, which `TerminalSession.keys` takes.
        let codes: [UIKeyboardHIDUsage: UInt16] = [
            .keyboardUpArrow: 126, .keyboardDownArrow: 125, .keyboardRightArrow: 124, .keyboardLeftArrow: 123,
            .keyboardReturnOrEnter: returnKey, .keypadEnter: 76, .keyboardTab: 48, .keyboardDeleteOrBackspace: 51,
            .keyboardEscape: 53, .keyboardDeleteForward: 117, .keyboardHome: 115, .keyboardEnd: 119, .keyboardPageUp: 116,
            .keyboardPageDown: 121, .keyboardF1: 122, .keyboardF2: 120, .keyboardF3: 99, .keyboardF4: 118, .keyboardF5: 96,
            .keyboardF6: 97, .keyboardF7: 98, .keyboardF8: 100, .keyboardF9: 101, .keyboardF10: 109, .keyboardF11: 103,
            .keyboardF12: 111,
        ]
        let code = codes[key.keyCode]
        guard code != nil || flags.contains(.control) else { return nil }
        return TerminalSession.keys(keyCode: code ?? anyKey, characters: key.charactersIgnoringModifiers,
                                    control: flags.contains(.control), option: flags.contains(.alternate),
                                    shift: flags.contains(.shift), applicationCursor: applicationCursor)
    }

    /// ⌘V on a hardware keyboard.
    override func paste(_ sender: Any?) {
        guard let session, session.running, let text = UIPasteboard.general.string else { return }
        showLive()
        session.paste(text)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) ? session?.running == true && UIPasteboard.general.hasStrings
            : super.canPerformAction(action, withSender: sender)
    }

    // MARK: Gestures

    @objc private func tapped() {
        if !isFirstResponder { _ = becomeFirstResponder() }
    }

    @objc private func dragged(_ drag: UIPanGestureRecognizer) {
        guard let session else { return }
        let screen = session.screen
        let lines = Int(drag.translation(in: self).y / cellHeight)
        if drag.state == .began { dragStart = (scrollOffset, 0) }
        if screen.alternateScreen {
            // Full-screen programs (less, vim) take it as arrow keys, as the Mac's scroll wheel.
            let step = lines - dragStart.sent
            guard step != 0, session.running else { return }
            dragStart.sent = lines
            let arrow = TerminalSession.keys(keyCode: step > 0 ? 126 : 125, characters: nil, control: false, option: false,
                                             shift: false, applicationCursor: screen.applicationCursorKeys) ?? ""
            session.send(String(repeating: arrow, count: abs(step)))
        } else {
            scrollOffset = min(max(dragStart.offset + lines, 0), screen.scrollback.count)
            if scrollOffset == 0 { showLive() } else { setNeedsDisplay() }
        }
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        if pinch.state == .began { pinchStart = font.pointSize }
        let size = min(max((pinchStart * pinch.scale * 2).rounded() / 2, 8), 28)
        if size != font.pointSize { setFontSize(size) }
        if pinch.state == .ended { UserDefaults.standard.set(Double(size), forKey: Self.fontSizeKey) }
    }
}

/// The terminal in SwiftUI: the view shows `shell` (the shown terminal's).
struct TerminalScreenView: UIViewRepresentable {
    let terminals: Terminals
    let shell: TerminalSession?

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(terminals: terminals)
        terminals.view = view
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if view.session !== shell { view.session = shell }
    }
}
