import AirSCPCore
import AppKit
import IOSurface

/// The Windows desktop of an RDP session, and the keyboard and mouse for it: keys go to Windows while it has the focus,
/// except ⌘Q (quit AirSCP) and ⌃⌘F (full screen). Dropping Finder files on it hands them to `onDrop` (Upload).
///
/// The desktop is the layer's contents, an IOSurface: Core Animation scales it into the view (keeping its proportions)
/// and matches its colours (sRGB) to the screen on the GPU, so the main thread only copies what changed.
final class RDPDesktopView: NSView {
    var session: RDPSession? {
        didSet {
            pressed = []
            modifiers = []
            cursor = .arrow
            if session == nil {
                surfaces = []
                layer?.contents = nil
            }
            updateBackground()
        }
    }
    /// The desktop's size in pixels; zero while there is none.
    var desktopSize = CGSize.zero {
        didSet {
            guard desktopSize != oldValue else { return }
            updateFilter()
            invalidate(desktop: CGRect(origin: .zero, size: desktopSize))
        }
    }
    /// ⌘ is sent as Ctrl instead of the Windows key.
    var commandAsControl = true
    /// Finder files may be dropped on it.
    var acceptsDrops = false
    var onResize: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onToggleFullScreen: (() -> Void)?

    private var cursor = NSCursor.arrow
    private(set) var modifiers: NSEvent.ModifierFlags = []
    /// Keys held down (Mac key codes), let go when the focus leaves.
    private var pressed: Set<UInt16> = []
    private var scrollRemainder = CGPoint.zero
    private var trackingArea: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    /// Two surfaces, shown in turn (Core Animation takes a new object as new contents), each with the part of the
    /// desktop that changed since it was last brought up to date.
    private var surfaces: [(surface: IOSurfaceRef, stale: CGRect)] = []
    private var shown = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()  // layer-hosting: the view draws nothing itself
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        updateBackground()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A click on the desktop goes to Windows also while AirSCP's window isn't the key window (the click that makes it
    /// key, or an agent's while AirSCP stays in the background).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    /// Where the desktop is shown: scaled to fit the view, keeping its proportions, centred (as `.resizeAspect`).
    var imageRect: CGRect {
        guard desktopSize.width > 0, desktopSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / desktopSize.width, bounds.height / desktopSize.height)
        let size = CGSize(width: desktopSize.width * scale, height: desktopSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
                      height: size.height)
    }

    /// The part of the desktop that changed (desktop pixels, top-left origin): it is copied into the surface not on
    /// screen, which is then shown.
    func invalidate(desktop rect: CGRect) {
        guard let session else { return }
        session.withFrame { frame in
            guard let frame else { return }
            let all = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            if surfaces.count != 2 || IOSurfaceGetWidth(surfaces[0].surface) != frame.width
                || IOSurfaceGetHeight(surfaces[0].surface) != frame.height {
                surfaces = (0..<2).compactMap { _ in Self.surface(width: frame.width, height: frame.height).map { ($0, all) } }
                guard surfaces.count == 2 else { return }
            }
            for index in surfaces.indices { surfaces[index].stale = surfaces[index].stale.union(rect) }
            let next = 1 - shown
            Self.copy(frame, surfaces[next].stale.intersection(all).integral, into: surfaces[next].surface)
            surfaces[next].stale = .null
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = surfaces[next].surface
            CATransaction.commit()
            shown = next
        }
    }

    private static func surface(width: Int, height: Int) -> IOSurfaceRef? {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
            kIOSurfacePixelFormat: 0x4247_5241,  // 'BGRA' (the frame buffer's X byte is ignored over the black background)
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList()
        else { return nil }
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space)
        return surface
    }

    private static func copy(_ frame: RDPSession.Frame, _ rect: CGRect, into surface: IOSurfaceRef) {
        guard !rect.isEmpty else { return }
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let base = IOSurfaceGetBaseAddress(surface), stride = IOSurfaceGetBytesPerRow(surface)
        let (x, width) = (Int(rect.minX), Int(rect.width) * 4)
        for row in Int(rect.minY)..<Int(rect.maxY) {
            memcpy(base + row * stride + x * 4, frame.pixels + row * frame.stride + x * 4, width)
        }
    }

    /// Pixel for pixel when the desktop matches the screen (Retina resolution), smoothed when scaled.
    private func updateFilter() {
        let exact = abs(convertToBacking(imageRect).width - desktopSize.width) < 1
        layer?.magnificationFilter = exact ? .nearest : .linear
        layer?.minificationFilter = exact ? .nearest : .linear
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (session == nil ? NSColor.underPageBackgroundColor : NSColor.black).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateFilter()
        onResize?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateFilter()
        onResize?()
    }

    // MARK: Pointer

    func setPointer(_ pointer: RDPSession.Pointer) {
        switch pointer {
        case .arrow:
            cursor = .arrow
        case .hidden:
            cursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
        case .image(let image, let hotSpot):
            // Windows' pointer is in desktop pixels; show it at the desktop's scale.
            let scale = desktopSize.width > 0 ? imageRect.width / desktopSize.width : 1
            let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            cursor = NSCursor(image: NSImage(cgImage: image, size: size),
                              hotSpot: NSPoint(x: hotSpot.x * scale, y: hotSpot.y * scale))
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: session == nil ? .arrow : cursor)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// The event's position on the desktop, in pixels.
    private func desktopPoint(_ event: NSEvent) -> CGPoint { desktopPoint(atWindowPoint: event.locationInWindow) }

    /// A point of the window (bottom-left origin) on the desktop, in pixels.
    func desktopPoint(atWindowPoint location: NSPoint) -> CGPoint {
        let point = convert(location, from: nil), image = imageRect
        guard image.width > 0, image.height > 0, desktopSize.width > 0 else { return .zero }
        let x = (point.x - image.minX) * desktopSize.width / image.width
        let y = (image.maxY - point.y) * desktopSize.height / image.height
        return CGPoint(x: min(max(x, 0), desktopSize.width - 1).rounded(.down),
                       y: min(max(y, 0), desktopSize.height - 1).rounded(.down))
    }

    override func mouseMoved(with event: NSEvent) { session?.mouseMove(to: desktopPoint(event)) }
    override func mouseDragged(with event: NSEvent) { session?.mouseMove(to: desktopPoint(event)) }
    override func rightMouseDragged(with event: NSEvent) { session?.mouseMove(to: desktopPoint(event)) }
    override func otherMouseDragged(with event: NSEvent) { session?.mouseMove(to: desktopPoint(event)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        session?.mouseButton(0, down: true, at: desktopPoint(event))
    }

    override func mouseUp(with event: NSEvent) { session?.mouseButton(0, down: false, at: desktopPoint(event)) }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        session?.mouseButton(1, down: true, at: desktopPoint(event))
    }

    override func rightMouseUp(with event: NSEvent) { session?.mouseButton(1, down: false, at: desktopPoint(event)) }

    override func otherMouseDown(with event: NSEvent) {
        guard (2...4).contains(event.buttonNumber) else { return }
        session?.mouseButton(event.buttonNumber, down: true, at: desktopPoint(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard (2...4).contains(event.buttonNumber) else { return }
        session?.mouseButton(event.buttonNumber, down: false, at: desktopPoint(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session else { return }
        // 120 units are one notch of a wheel (a few lines); a trackpad reports points.
        let units: CGFloat = event.hasPreciseScrollingDeltas ? 3 : 120
        scrollRemainder.x += event.scrollingDeltaX * units
        scrollRemainder.y += event.scrollingDeltaY * units
        let point = desktopPoint(event)
        let vertical = Int(scrollRemainder.y), horizontal = Int(scrollRemainder.x)
        if vertical != 0 { session.wheel(horizontal: false, delta: vertical, at: point) }
        // The Mac's horizontal delta is positive to the left; Windows' to the right.
        if horizontal != 0 { session.wheel(horizontal: true, delta: -horizontal, at: point) }
        scrollRemainder.x -= CGFloat(horizontal)
        scrollRemainder.y -= CGFloat(vertical)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session else { return super.keyDown(with: event) }
        syncModifiers(event.modifierFlags)
        if session.key(event.keyCode, down: true, isRepeat: event.isARepeat) {
            pressed.insert(event.keyCode)
        } else if let characters = event.characters {
            session.unicode(characters)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let session else { return super.keyUp(with: event) }
        syncModifiers(event.modifierFlags)
        pressed.remove(event.keyCode)
        session.key(event.keyCode, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        syncModifiers(event.modifierFlags)
    }

    /// Key combinations with ⌘ or Ctrl would go to AirSCP's menus: they go to Windows instead, but for ⌘Q and ⌃⌘F (the
    /// way out of full screen). AppKit sends no key-up after ⌘ combinations, so the key is let go at once.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let session else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command, .control] && key == "f" {
            onToggleFullScreen?()
            return true
        }
        if flags == .command && key == "q" { return super.performKeyEquivalent(with: event) }
        syncModifiers(event.modifierFlags)
        if session.key(event.keyCode, down: true, isRepeat: event.isARepeat) {
            session.key(event.keyCode, down: false)
        } else if let characters = event.characters {
            session.unicode(characters)
        }
        return true
    }

    /// Sends the modifier keys that went down or up since the last event (left-hand keys; Caps Lock toggles).
    private func syncModifiers(_ flags: NSEvent.ModifierFlags) {
        guard let session else { return }
        let now = flags.intersection([.shift, .control, .option, .command, .capsLock])
        let keys: [(NSEvent.ModifierFlags, UInt16)] = [
            (.shift, 0x2A), (.control, 0x1D), (.option, 0x38), (.command, commandAsControl ? 0x1D : 0x15B),
        ]
        for (flag, scancode) in keys where now.contains(flag) != modifiers.contains(flag) {
            session.scancode(scancode, down: now.contains(flag))
        }
        if now.contains(.capsLock) != modifiers.contains(.capsLock) {
            session.scancode(0x3A, down: true)
            session.scancode(0x3A, down: false)
        }
        modifiers = now
    }

    /// The desktop got the keyboard focus: Windows takes the Mac's Caps Lock state (and no key held), and so does this
    /// view's memory of the modifiers, so that the next key doesn't toggle Caps Lock back.
    func focusIn() {
        let capsLock = NSEvent.modifierFlags.contains(.capsLock)
        session?.focus(capsLock: capsLock)
        modifiers = capsLock ? [.capsLock] : []
    }

    /// Lets go of every key held down (the focus left: Windows would otherwise repeat it).
    private func releaseKeys() {
        guard let session else { return }
        pressed.forEach { session.key($0, down: false) }
        pressed = []
        syncModifiers(modifiers.intersection(.capsLock))
    }

    override func becomeFirstResponder() -> Bool {
        if window?.isKeyWindow == true { onFocus?(true) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseKeys()
        onFocus?(false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                guard let self, self.window?.firstResponder === self else { return }
                self.onFocus?(true)
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                guard let self, self.window?.firstResponder === self else { return }
                self.releaseKeys()
                self.onFocus?(false)
            },
        ]
    }

    // MARK: Drag and drop (Upload)

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrops && !fileURLs(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard acceptsDrops, !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
