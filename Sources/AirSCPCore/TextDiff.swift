import Foundation

/// Two texts side by side, line by line (Compare): rows that pair a line of the left text with one of the right, with an
/// empty filler opposite a line only one side has. A run of lines that differ is a block: its removed and added lines
/// are paired row by row (changed), the rest are only on one side. Changed rows mark the characters that differ.
/// Line ends don't count as a difference (a Windows file against a Unix one), and a trailing "\r" isn't shown.
public struct TextDiff: Sendable {
    /// What the comparison leaves out.
    public struct Options: Equatable, Sendable {
        /// Spaces and tabs at the start and end of lines, and runs of them inside (taken as one space).
        public var whitespace = false
        public var caseOfLetters = false
        public var blankLines = false
        public init(whitespace: Bool = false, caseOfLetters: Bool = false, blankLines: Bool = false) {
            self.whitespace = whitespace
            self.caseOfLetters = caseOfLetters
            self.blankLines = blankLines
        }
    }

    public enum Kind: Sendable { case same, leftOnly, rightOnly, changed }

    public struct Row: Equatable, Sendable {
        /// Line indexes (from 0); nil: a filler row on that side.
        public var left: Int?, right: Int?
        public var kind: Kind
        /// A changed row's differing characters, as UTF-16 offsets into each side's line (as shown).
        public var leftRanges: [Range<Int>] = [], rightRanges: [Range<Int>] = []
    }

    /// A run of differing rows, and the lines it holds on each side (an empty range: none on that side, before the line
    /// at its lower bound).
    public struct Block: Equatable, Sendable {
        public var rows: Range<Int>
        public var left: Range<Int>, right: Range<Int>
    }

    /// The texts' lines as they are (a Windows line end's "\r" kept, so that a merge writes it back).
    public let leftLines: [String], rightLines: [String]
    public let rows: [Row]
    public let blocks: [Block]

    /// Character differences are worked out for lines up to this long; longer ones mark what is between their common
    /// start and end (the work grows with the square of the length).
    static let characterLimit = 500

    public init(left: String, right: String, options: Options = Options()) {
        leftLines = left.components(separatedBy: "\n")
        rightLines = right.components(separatedBy: "\n")
        var rows: [Row] = [], blocks: [Block] = []
        var i = 0, j = 0
        let leftLines = self.leftLines, rightLines = self.rightLines
        func gap(to li: Int, _ rj: Int) {
            let left = i..<li, right = j..<rj
            guard !left.isEmpty || !right.isEmpty else { return }
            // Only blank lines (and Ignore blank lines on): no difference.
            let ignored = options.blankLines && (left.map { leftLines[$0] } + right.map { rightLines[$0] }).allSatisfy(Self.isBlank)
            let start = rows.count
            // The shorter side's lines go opposite the run of the longer side's that they are most like.
            let shift = Self.bestShift(left.map { leftLines[$0] }, right.map { rightLines[$0] })
            for k in 0..<max(left.count, right.count) {
                let lk = left.count < right.count ? k - shift : k, rk = right.count < left.count ? k - shift : k
                let l = (0..<left.count).contains(lk) ? left.lowerBound + lk : nil
                let r = (0..<right.count).contains(rk) ? right.lowerBound + rk : nil
                var row = Row(left: l, right: r, kind: ignored ? .same : l == nil ? .rightOnly : r == nil ? .leftOnly : .changed)
                if row.kind == .changed, let l, let r {
                    (row.leftRanges, row.rightRanges) = Self.characterDifference(Self.shown(leftLines[l]), Self.shown(rightLines[r]))
                }
                rows.append(row)
            }
            if !ignored { blocks.append(Block(rows: start..<rows.count, left: left, right: right)) }
        }
        for (li, rj) in Self.matches(leftLines, rightLines, options) {
            gap(to: li, rj)
            rows.append(Row(left: li, right: rj, kind: .same))
            i = li + 1
            j = rj + 1
        }
        gap(to: leftLines.count, rightLines.count)
        self.rows = rows
        self.blocks = blocks
    }

    /// A line as shown: without a Windows line end's "\r".
    public static func shown(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    /// What a line is compared by, with the options.
    static func key(_ line: String, _ options: Options) -> String {
        var key = shown(line)
        if options.whitespace {
            key = key.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        return options.caseOfLetters ? key.lowercased() : key
    }

    /// The pairs of equal lines (left index, right index), in order. Lines that are on one side only (or blank, when
    /// blank lines don't count) are left out before diffing: they can't match, and leaving them out keeps the diff fast
    /// when the files differ a lot (its work grows with the number of differences).
    static func matches(_ left: [String], _ right: [String], _ options: Options) -> [(Int, Int)] {
        var ids: [String: Int] = [:]
        func intern(_ lines: [String]) -> [Int] {
            lines.map { line in
                if options.blankLines, isBlank(line) { return -1 }
                let key = key(line, options)
                if let id = ids[key] { return id }
                ids[key] = ids.count
                return ids.count - 1
            }
        }
        let a = intern(left), b = intern(right)
        let inA = Set(a), inB = Set(b)
        let keptA = a.indices.filter { a[$0] >= 0 && inB.contains(a[$0]) }, keptB = b.indices.filter { b[$0] >= 0 && inA.contains(b[$0]) }
        let x = keptA.map { a[$0] }, y = keptB.map { b[$0] }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in y.difference(from: x) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var pairs: [(Int, Int)] = [], p = 0, q = 0
        while p < x.count && q < y.count {
            if removed.contains(p) {
                p += 1
            } else if inserted.contains(q) {
                q += 1
            } else {
                pairs.append((keptA[p], keptB[q]))
                p += 1
                q += 1
            }
        }
        return pairs
    }

    /// The characters of `old` and `new` that the other doesn't have, as UTF-16 ranges (adjacent ones joined).
    static func characterDifference(_ old: String, _ new: String) -> ([Range<Int>], [Range<Int>]) {
        let a = Array(old), b = Array(new)
        func offsets(_ characters: [Character]) -> [Int] {
            var offsets = [0]
            for character in characters { offsets.append(offsets.last! + character.utf16.count) }
            return offsets
        }
        func ranges(_ indexes: [Int], _ offsets: [Int]) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            for index in indexes.sorted() {
                let range = offsets[index]..<offsets[index + 1]
                if let last = ranges.last, last.upperBound == range.lowerBound {
                    ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    ranges.append(range)
                }
            }
            return ranges
        }
        let oa = offsets(a), ob = offsets(b)
        guard a.count <= characterLimit, b.count <= characterLimit else {
            let prefix = zip(a, b).prefix { $0 == $1 }.count
            let suffix = zip(a.dropFirst(prefix).reversed(), b.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
            let left = oa[prefix]..<oa[a.count - suffix], right = ob[prefix]..<ob[b.count - suffix]
            return (left.isEmpty ? [] : [left], right.isEmpty ? [] : [right])
        }
        var removed: [Int] = [], inserted: [Int] = []
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.append(offset)
            case .insert(let offset, _, _): inserted.append(offset)
            }
        }
        return (ranges(removed, oa), ranges(inserted, ob))
    }

    /// Where the shorter of a block's two runs of lines goes along the longer one (how many of its lines come first): where
    /// its lines share the most characters at their start and end with those opposite. 0 for runs of the same length,
    /// or too long to try every place.
    static func bestShift(_ a: [String], _ b: [String]) -> Int {
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        guard !short.isEmpty, short.count != long.count, short.count * (long.count - short.count + 1) <= 2_000 else { return 0 }
        func likeness(_ x: String, _ y: String) -> Int {
            let prefix = zip(x, y).prefix { $0 == $1 }.count
            return prefix + zip(x.dropFirst(prefix).reversed(), y.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
        }
        return (0...(long.count - short.count)).max { first, second in
            let score = { (shift: Int) in short.indices.reduce(0) { $0 + likeness(short[$1], long[$1 + shift]) } }
            return score(first) < score(second)
        } ?? 0
    }

    /// The text of the other side after copying `block`'s lines to it (`toRight`: from the left), in place of the lines
    /// it has there.
    public func merging(_ block: Block, toRight: Bool) -> String {
        var lines = toRight ? rightLines : leftLines
        let source = toRight ? leftLines[block.left] : rightLines[block.right]
        lines.replaceSubrange(toRight ? block.right : block.left, with: source)
        return lines.joined(separator: "\n")
    }
}
