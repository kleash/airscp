import AppKit
import SwiftUI

// Night Harbor (dark) and Paper (light), PLAN.md O.1: both are AppKit's own colours as the appearance resolves them
// (light or dark, Increase Contrast, the accent colour), so there is no theme object and no setting. What differs
// between the two reads the appearance where it is drawn: the colours below, and the chips, dots, pills and bars.

extension NSAppearance {
    /// Night Harbor; else Paper.
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    /// Night Harbor's wash, systemIndigo at 7 %, over the window and its surfaces; none in Paper, nor with Increase
    /// Contrast.
    static let wash = NSColor(name: nil) { washes($0) ? NSColor.systemIndigo.withAlphaComponent(0.07) : .clear }
    /// The window's ground: the toolbar, the workspace header, and around Paper's cards. macOS 26 draws windows in the
    /// content colour; 7.5 % of labelColor gives the ground back its grey (Paper) and its lift (Night Harbor).
    static let ground = NSColor(name: nil) { surface(.windowBackgroundColor, $0, lifted: true) }
    /// File panes, the Transfers list and the other tables.
    static let content = NSColor(name: nil) { surface(.controlBackgroundColor, $0, lifted: false) }
    /// A pane's or panel's bars (its controls, its status line): the ground at 40 % over the content.
    static let bar = NSColor(name: nil) { appearance in
        var color = NSColor.content
        appearance.performAsCurrentDrawingAppearance { color = NSColor.content.blended(withFraction: 0.4, of: .ground) ?? color }
        return color
    }
    /// The selected, active or primary fill: the accent in Night Harbor, labelColor in Paper (its black pill).
    static let pill = NSColor(name: nil) { $0.isDark ? .controlAccentColor : .labelColor }
    /// Text and symbols on a pill.
    static let onPill = NSColor(name: nil) { $0.isDark ? .alternateSelectedControlTextColor : .controlBackgroundColor }

    /// A status colour as text: itself on Night Harbor's dark surfaces, 35 % towards labelColor in Paper, where the
    /// system colours are too light on white.
    static func readable(_ hue: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            guard !appearance.isDark else { return hue }
            var color = hue
            appearance.performAsCurrentDrawingAppearance { color = hue.blended(withFraction: 0.35, of: .labelColor) ?? hue }
            return color
        }
    }

    private static func washes(_ appearance: NSAppearance) -> Bool {
        appearance.isDark && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private static func surface(_ base: NSColor, _ appearance: NSAppearance, lifted: Bool) -> NSColor {
        var color = base
        appearance.performAsCurrentDrawingAppearance {
            if lifted, #available(macOS 26, *) { color = color.blended(withFraction: 0.075, of: .labelColor) ?? color }
            if washes(appearance) { color = color.blended(withFraction: 0.07, of: .systemIndigo) ?? color }
        }
        return color
    }
}

/// An AppKit surface in one of the colours above: a plain one, or (`card`) Paper's 10 pt card with a separator edge,
/// which is edge to edge in Night Harbor. The colour follows the appearance as the view redraws.
final class SurfaceView: NSView {
    let color: NSColor
    let card: Bool

    init(_ color: NSColor, card: Bool = false) {
        self.color = color
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        // Increase Contrast turns the wash off: the colour is worked out again as the layer is updated.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(redraw),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let paper = card && !effectiveAppearance.isDark
        layer.backgroundColor = color.cgColor
        layer.cornerRadius = paper ? 10 : 0
        layer.borderWidth = paper ? 1 : 0
        layer.borderColor = NSColor.separatorColor.cgColor
        layer.masksToBounds = paper
    }
}

/// Holds a card: inset by `paperInsets` in Paper, so that the ground shows around it; edge to edge in Night Harbor.
final class CardHolder: NSView {
    let card: NSView
    let paperInsets: NSEdgeInsets

    init(card: NSView, paperInsets: NSEdgeInsets) {
        self.card = card
        self.paperInsets = paperInsets
        super.init(frame: .zero)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let inset = effectiveAppearance.isDark ? NSEdgeInsetsZero : paperInsets
        card.frame = NSRect(x: inset.left, y: inset.bottom, width: max(0, bounds.width - inset.left - inset.right),
                            height: max(0, bounds.height - inset.top - inset.bottom))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// A split view between surfaces: a hairline in Night Harbor, an empty gap between Paper's cards.
final class SurfaceSplitView: NSSplitView {
    private static let divider = NSColor(name: nil) { $0.isDark ? .separatorColor : .clear }

    override var dividerColor: NSColor { Self.divider }
}

/// A sidebar symbol in its 22 pt chip: in Night Harbor the section's hue at 18 % behind the hue; in Paper labelColor
/// at 7 % behind labelColor (a colour tag keeps its colour); on the selected row the pill's text colour. Drawn as a
/// picture of its own: a sidebar draws its rows' content vibrant, which would pale the colours.
struct Chip: View {
    let symbol: String
    var hue: Color = .blue
    /// A host's own colour tag, shown in Paper too.
    var tagged = false
    var selected = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = selected ? Color(nsColor: .onPill) : scheme == .dark || tagged ? hue : .primary
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(selected ? 0.2 : scheme == .dark ? 0.18 : 0.07)))
            .drawingGroup()
            .accessibilityHidden(true)
    }
}

/// The selected sidebar row's pill: selectedContentBackgroundColor in Night Harbor, labelColor in Paper (the list's
/// own highlight can't be black, so it is off). Its row draws as one picture in the pill's text colour, not vibrant.
struct SidebarSelection: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        Group {
            if selected { content.drawingGroup() } else { content }
        }
        .listRowBackground(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color(nsColor: scheme == .dark ? .selectedContentBackgroundColor : .labelColor) : .clear)
            .padding(.horizontal, 10)
            .drawingGroup()
            .background(SystemHighlightOff()))
    }
}

/// Turns off the selection highlight of the list it is in (from a row's background, the one place inside it).
private struct SystemHighlightOff: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            (view as? NSTableView)?.selectionHighlightStyle = .none
        }
    }
}

/// A primary button (a sheet's default button) and a segmented choice: Paper's black pill; in Night Harbor the accent,
/// or a section's hue (Remote Desktop's purple, the proxies' orange).
struct PrimaryTint: ViewModifier {
    let hue: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.tint(scheme == .dark ? hue : Color(nsColor: .pill))
    }
}

/// Paper's 10 pt card: the content colour with a separator edge, `insets` from what holds it so that the ground shows
/// around it. Night Harbor has no cards: the content colour, edge to edge.
struct Card: ViewModifier {
    let insets: EdgeInsets
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let paper = scheme != .dark
        content
            .background(Color(nsColor: .content))
            .clipShape(RoundedRectangle(cornerRadius: paper ? 10 : 0))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)).opacity(paper ? 1 : 0))
            .padding(paper ? insets : EdgeInsets())
    }
}

/// Night Harbor's wash (`NSColor.wash`) in SwiftUI. Increase Contrast turns it off; SwiftUI wouldn't work the colour
/// out again until the next appearance change, so the view follows that setting itself (as `SurfaceView` does).
struct Wash: View {
    @State private var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

    var body: some View {
        Color(nsColor: increaseContrast ? .clear : .wash)
            .allowsHitTesting(false)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            }
    }
}

extension View {
    /// Night Harbor's wash over a SwiftUI table or list, which draws its own (system) background and zebra stripes.
    func washed() -> some View {
        overlay(Wash())
    }

    func primaryTint(_ hue: Color? = nil) -> some View { modifier(PrimaryTint(hue: hue)) }

    /// By default 10 points from the window's sides and bottom, as the Transfers panel and a tab's lists sit.
    func card(_ insets: EdgeInsets = EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10)) -> some View {
        modifier(Card(insets: insets))
    }
}

extension Color {
    /// A caption on a pill (a selected row's address or route).
    static let onPillCaption = Color(nsColor: .onPill).opacity(0.75)
}

/// A status dot (8 pt). In Night Harbor it glows in its own colour (a still shadow, not an animation).
struct StatusDot: View {
    let color: Color
    let help: String
    var glows = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .shadow(color: scheme == .dark && glows ? color.opacity(0.7) : .clear, radius: 3)
            .padding(4)
            .drawingGroup()
            .padding(-4)
            .help(help)
            .accessibilityElement().accessibilityLabel(help)  // the state isn't only a colour
    }
}

/// A status in a capsule: tinted (its colour at 16 % behind its readable text), the pill (Paper's black pill, Night
/// Harbor's accent) or neutral (grey).
struct StatusPill: View {
    enum Style { case tinted(NSColor), pill, neutral }
    let text: String
    var symbol: String?
    let style: Style

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)).accessibilityHidden(true) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch style {
        case .tinted(let hue): return Color(nsColor: .readable(hue))
        case .pill: return Color(nsColor: .onPill)
        case .neutral: return .secondary
        }
    }

    private var background: Color {
        switch style {
        case .tinted(let hue): return Color(nsColor: hue).opacity(0.16)
        case .pill: return Color(nsColor: .pill)
        case .neutral: return Color.primary.opacity(0.07)
        }
    }
}

/// A progress bar: a 6 pt capsule over labelColor at 10 %. Running, it fills with Night Harbor's systemBlue →
/// systemPurple (Paper: labelColor) and a soft shimmer passes over it (not with Reduce Motion); done is green, paused
/// grey, failed red.
struct CapsuleBar: View {
    enum State { case running, done, paused, failed }
    let fraction: Double
    let state: State
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(fill).frame(width: width)
                if state == .running && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                        LinearGradient(colors: [.clear, Color(nsColor: .onPill).opacity(0.28), .clear], startPoint: .leading,
                                       endPoint: .trailing)
                            .frame(width: width / 2)
                            .offset(x: (phase * 3 - 1) * width / 2)
                    }
                    .frame(width: width, alignment: .leading)
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 6)
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .done: return AnyShapeStyle(Color(nsColor: .systemGreen))
        case .paused: return AnyShapeStyle(Color(nsColor: .systemGray))
        case .failed: return AnyShapeStyle(Color(nsColor: .systemRed))
        case .running:
            return scheme == .dark ? AnyShapeStyle(LinearGradient(colors: [Color(nsColor: .systemBlue), Color(nsColor: .systemPurple)],
                                                                 startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(Color.primary)
        }
    }
}
