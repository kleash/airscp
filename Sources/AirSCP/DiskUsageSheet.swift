import AirSCPCore
import AppKit
import SwiftUI

/// Disk Usage of a folder on a server (`Session.diskUsage`) or on this Mac (`DiskUsage.scan`): what takes the room,
/// largest first, as rings and a list that grow while the scan runs, folder by folder, or the largest files below.
/// Show goes to an item in the pane; Delete… removes it.
@MainActor
final class DiskUsageModel: ObservableObject {
    /// One arc of the rings: an item, its ring (0: the folder shown's own items) and its share of the circle (0…1).
    struct Segment {
        let item: DiskUsage.Item
        let depth: Int
        let start: Double
        let end: Double
        /// The colour of the folder shown's item it is in.
        let hue: Double
    }

    /// nil: this Mac.
    let session: Session?
    let dir: String
    @Published private(set) var usage: DiskUsage?
    /// The folder whose items show.
    @Published private(set) var folder: DiskUsage.Item?
    @Published var largest = false { didSet { refresh() } }
    @Published private(set) var rows: [DiskUsage.Item] = []
    @Published private(set) var segments: [Segment] = []
    /// The files the scan found last, newest first, while it runs.
    @Published private(set) var discovered: [DiskUsage.Record] = []
    @Published var selection: Set<DiskUsage.Item.ID> = []
    @Published private(set) var scanning = false
    @Published private(set) var status = ""
    private var scan: Task<Void, Never>?
    private var generation = 0
    private var refreshed = Date.distantPast
    /// The most files Largest Files lists.
    static let largestCount = 200
    /// The rings drawn around the middle.
    static let rings = 3

    init(session: Session?, dir: String) {
        self.session = session
        self.dir = dir
    }

    /// The folder scanned, as the sheet names it ("/" is the server's name).
    var title: String { dir == "/" ? session?.host.displayName ?? "/" : RemotePath.name(dir) }

    func start() {
        scan?.cancel()
        let usage = DiskUsage(path: dir)
        self.usage = usage
        folder = usage.root
        discovered = []
        refresh()
        scanning = true
        status = "Scanning…"
        generation += 1
        let generation = self.generation, session = self.session, dir = self.dir
        let found: ([DiskUsage.Record], Int) -> Void = { [weak self] records, expected in
            DispatchQueue.main.async { self?.add(records, expected: expected, from: generation) }
        }
        scan = Task { [self] in
            let outcome: String
            do {
                if let session {
                    try await session.diskUsage(of: dir, found: found)
                } else {
                    // Off the main thread: a home folder has hundreds of thousands of files.
                    let work = Task.detached(priority: .userInitiated) { try DiskUsage.scan(dir, found: found) }
                    try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                }
                guard !Task.isCancelled else { return }
                outcome = usage.root.files == 0 ? "No files below “\(title)”." : "Scanned \(usage.root.files.formatted()) files."
            } catch {
                guard !Task.isCancelled else { return }
                outcome = (error as? AirSCPError)?.message ?? error.localizedDescription
            }
            // After the last batch: the main queue runs them in order.
            DispatchQueue.main.async { [self] in
                guard self.generation == generation else { return }
                scanning = false
                status = outcome
                withAnimation(.easeInOut(duration: 0.25)) { refresh() }
            }
        }
    }

    /// What the scan under way found: into the tree; the rings and the list follow a few times a second, as sizes grow.
    private func add(_ records: [DiskUsage.Record], expected: Int, from scan: Int) {
        guard scanning, scan == generation, let usage else { return }
        usage.expected = expected
        usage.add(records)
        let files = records.reversed().lazy.filter { !$0.folder }.prefix(8)
        discovered = Array((Array(files) + discovered).prefix(8))
        // Largest Files goes through the whole tree: less often.
        guard Date().timeIntervalSince(refreshed) > (largest ? 1.5 : 0.3) else { return }
        status = "Scanning… \(usage.root.files.formatted()) files, \(FileList.size(usage.root.size))"
        withAnimation(.easeInOut(duration: 0.25)) { refresh() }
    }

    /// How far the scan is: the scanned folder's own items reached; nil before it knows how many there are.
    var progress: Double? {
        guard let usage, usage.expected > 0 else { return nil }
        return min(Double(usage.reached) / Double(usage.expected), 1)
    }

    /// Stops a scan under way; what it measured so far stays.
    func stop() {
        scan?.cancel()
        scan = nil
        if scanning {
            scanning = false
            generation += 1
            status = "Stopped: the sizes are of what was scanned so far."
            refresh()
        }
    }

    /// Double-click: a folder's items show; false for a file (it is shown in the pane instead).
    @discardableResult
    func open(_ item: DiskUsage.Item) -> Bool {
        guard item.isFolder else { return false }
        folder = item
        largest = false
        refresh()
        return true
    }

    func goUp() {
        guard let parent = folder?.parent else { return }
        folder = parent
        refresh()
    }

    /// Items deleted (Delete… in the sheet): off the tree, their sizes out of the folders above.
    func removed(_ items: [DiskUsage.Item]) {
        items.forEach { $0.remove() }
        refresh()
    }

    var selectedItems: [DiskUsage.Item] { rows.filter { selection.contains($0.id) } }

    func items(_ ids: Set<DiskUsage.Item.ID>) -> [DiskUsage.Item] { rows.filter { ids.contains($0.id) } }

    /// Below the folder shown ("logs/app.log"), for Largest Files.
    func relative(_ item: DiskUsage.Item) -> String {
        guard let folder else { return item.name }
        let prefix = folder.path == "/" ? "/" : folder.path + "/"
        return item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path
    }

    private func refresh() {
        refreshed = Date()
        rows = folder.map { largest ? $0.largestFiles(Self.largestCount) : $0.children } ?? []
        segments = folder.map(Self.segments) ?? []
        selection.formIntersection(rows.map(\.id))
    }

    /// The rings of `folder`: its items, then theirs, each arc its share of the one it is in; arcs too thin to see are
    /// left out.
    static func segments(of folder: DiskUsage.Item) -> [Segment] {
        var segments: [Segment] = []
        func add(_ item: DiskUsage.Item, depth: Int, start: Double, span: Double, hue: Double?) {
            guard depth < rings, item.size > 0 else { return }
            var at = start
            for (index, child) in item.children.enumerated() {
                let width = span * Double(child.size) / Double(item.size)
                guard width >= 0.003 else { break }  // largest first: the rest are thinner still
                let tint = hue ?? Double(index % 10) / 10
                segments.append(Segment(item: child, depth: depth, start: at, end: at + width, hue: tint))
                if child.isFolder { add(child, depth: depth + 1, start: at, span: width, hue: tint) }
                at += width
            }
        }
        add(folder, depth: 0, start: 0, span: 1, hue: nil)
        return segments
    }
}

struct DiskUsageView: View {
    @ObservedObject var model: DiskUsageModel
    let show: (String) -> Void
    let close: () -> Void
    var delete: ([DiskUsage.Item]) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Disk Usage of “\(model.title)”").font(.headline)
                Text("What takes the room below “\(model.title)”, largest first. Click a ring or double-click a folder to go "
                     + "into it; select what you don't need and Delete… it"
                     + (model.session == nil ? " (to the Trash: empty it to free the space)." : "."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 16) {
                DiskUsageRings(model: model)
                    .frame(width: 300, height: 330)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                            .disabled(model.folder?.parent == nil)
                            .accessibilityIdentifier("diskUsage.up")
                            .help(model.folder?.parent == nil ? "This is the folder scanned" : "Go up one folder")
                        Text(model.folder?.path ?? model.dir).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Picker("Show", selection: $model.largest) {
                            Text("Contents").tag(false)
                            Text("Largest Files").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 210)
                        .accessibilityIdentifier("diskUsage.show")
                        .help("Contents: this folder's items by size. Largest Files: the \(DiskUsageModel.largestCount) biggest files at any depth below it")
                    }
                    list
                }
            }
            if model.scanning { scanning }
            HStack {
                HelpButton(.diskUsage)
                if model.scanning { ProgressView().controlSize(.small) }
                Text(model.status).foregroundColor(.secondary).lineLimit(2)
                Spacer()
                let none = model.selection.isEmpty
                Button("Copy Paths") { FindView.copy(model.selectedItems.map(\.path)) }
                    .disabled(none)
                    .accessibilityIdentifier("diskUsage.copyPaths")
                    .help(none ? "Select items first" : "Copy the selected items' full paths, one per line")
                Button("Delete…") { delete(model.selectedItems) }
                    .disabled(none || model.scanning)
                    .accessibilityIdentifier("diskUsage.delete")
                    .help(none ? "Select items first" : model.scanning ? "Wait for the scan to end, or stop it" : deleteHelp)
                if model.session == nil {
                    Button("Show in Finder") { Self.showInFinder(model.selectedItems) }
                        .disabled(none)
                        .accessibilityIdentifier("diskUsage.showInFinder")
                        .help(none ? "Select items first" : "Show the selected items in a Finder window")
                }
                Button(model.scanning ? "Stop" : "Scan Again") { model.scanning ? model.stop() : model.start() }
                    .help(model.scanning ? "Stop the scan; what it measured stays" : "Measure everything again")
                Button("Done", action: close).keyboardShortcut(.cancelAction).help("Close (a scan under way stops)")
                Button("Show") { if let item = model.selectedItems.first { show(item.path) } }
                    .disabled(model.selection.count != 1)
                    .help(model.selection.count == 1 ? "Go to the selected item in the pane" : "Select one item first")
            }
        }
        .padding(20)
        .frame(width: 940)
    }

    private var list: some View {
        List(model.rows, selection: $model.selection) { item in
            row(item)
        }
        .contextMenu(forSelectionType: DiskUsage.Item.ID.self, menu: { ids in
            let items = model.items(ids)
            if items.count == 1, items[0].isFolder {
                Button("Open") { model.open(items[0]) }.help("Show what is in the folder, by size")
            }
            Button("Show in Pane") { if let item = items.first { show(item.path) } }.help("Go to the item in the pane")
            if model.session == nil {
                Button("Show in Finder") { Self.showInFinder(items) }.help("Select the items in a Finder window")
            }
            Button("Copy Paths") { FindView.copy(items.map(\.path)) }.help("Copy the full paths, one per line")
            Button("Delete…") { delete(items) }
                .disabled(model.scanning)
                .help(model.scanning ? "Wait for the scan to end, or stop it" : deleteHelp)
        }, primaryAction: { ids in
            if let item = model.items(ids).first, !model.open(item) { show(item.path) }
        })
        .frame(minHeight: 300)
    }

    /// While it runs: how far it is, and the files it has just found, with their sizes.
    private var scanning: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = model.progress {
                ProgressView(value: progress).help("How many of “\(model.title)”'s own items the scan has measured")
            } else {
                ProgressView().progressViewStyle(.linear).help("Counting “\(model.title)”'s items")
            }
            ForEach(model.discovered, id: \.path) { record in
                HStack {
                    Label(record.path, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(FileList.size(record.size)).monospacedDigit()
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(height: 150, alignment: .top)
        .clipped()
        .accessibilityIdentifier("diskUsage.discovered")
    }

    static func showInFinder(_ items: [DiskUsage.Item]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) })
    }

    private var deleteHelp: String {
        model.session == nil ? "Move the selected items to the Trash (asks first)" : "Delete the selected items on the server (asks first)"
    }

    private func row(_ item: DiskUsage.Item) -> some View {
        let total = max(model.folder?.size ?? 0, 1)
        return HStack {
            Label(model.largest ? model.relative(item) : item.name, systemImage: item.isFolder ? "folder" : "doc")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            ProgressView(value: Double(min(item.size, total)), total: Double(total)).frame(width: 90)
            Text(FileList.size(item.size)).monospacedDigit().frame(width: 76, alignment: .trailing)
            Text((Double(item.size) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
        }
        .help(item.isFolder ? "Double-click to see what is in the folder" : "Double-click to go to the file in the pane")
    }
}

/// The rings: the folder shown in the middle, its items around it, theirs further out, each arc as wide as its share.
/// Pointing at an arc names it; clicking a folder's arc goes into it, a file's selects it, the middle goes up.
struct DiskUsageRings: View {
    @ObservedObject var model: DiskUsageModel
    @State private var pointed: DiskUsage.Item?

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let inner = side * 0.16, ring = (side / 2 - inner) / CGFloat(DiskUsageModel.rings)
                Canvas { context, _ in
                    for segment in model.segments {
                        let from = inner + CGFloat(segment.depth) * ring
                        var path = Path()
                        path.addArc(center: center, radius: from + ring - 1, startAngle: .degrees(segment.start * 360 - 90),
                                    endAngle: .degrees(segment.end * 360 - 90), clockwise: false)
                        path.addArc(center: center, radius: from, startAngle: .degrees(segment.end * 360 - 90),
                                    endAngle: .degrees(segment.start * 360 - 90), clockwise: true)
                        path.closeSubpath()
                        let lit = segment.item === pointed
                        let color = Color(hue: segment.hue, saturation: segment.item.isFolder ? 0.55 - 0.12 * Double(segment.depth) : 0.12,
                                          brightness: lit ? 1 : 0.88 - 0.06 * Double(segment.depth))
                        context.fill(path, with: .color(color))
                        context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 0.5)
                    }
                }
                .overlay {
                    VStack(spacing: 2) {
                        Text(model.folder.map { FileList.size($0.size) } ?? "—").font(.headline).monospacedDigit()
                        Text(model.folder.map { "\($0.files.formatted()) files" } ?? "").font(.caption2).foregroundColor(.secondary)
                    }
                    .frame(width: inner * 1.8)
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase { pointed = hit(point, center, inner, ring)?.item } else { pointed = nil }
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    let distance = hypot(point.x - center.x, point.y - center.y)
                    if distance < inner { return model.goUp() }
                    guard let item = hit(point, center, inner, ring)?.item, !model.open(item) else { return }
                    model.selection = [item.id]
                }
            }
            Text(pointed.map { "\($0.name): \(FileList.size($0.size))" } ?? " ")
                .font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk usage rings of \(model.folder?.name ?? model.title)")
        .accessibilityIdentifier("diskUsage.rings")
        .help("Point at an arc to see what it is; click a folder's arc to go into it, the middle to go up")
    }

    /// The arc under `point`, if any.
    private func hit(_ point: CGPoint, _ center: CGPoint, _ inner: CGFloat, _ ring: CGFloat) -> DiskUsageModel.Segment? {
        let distance = hypot(point.x - center.x, point.y - center.y)
        guard distance >= inner else { return nil }
        let depth = Int((distance - inner) / ring)
        // 0 at the top, going clockwise, as the arcs are drawn.
        var turn = (atan2(point.y - center.y, point.x - center.x) / (2 * .pi) + 0.25)
        if turn < 0 { turn += 1 }
        return model.segments.first { $0.depth == depth && $0.start <= turn && turn < $0.end }
    }
}
