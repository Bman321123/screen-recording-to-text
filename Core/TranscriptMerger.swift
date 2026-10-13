import Foundation

// Stitches per-frame bubble lists into one conversation.
//
// Consecutive frames of a scrolling recording overlap heavily, so each new frame
// is locally aligned (Smith–Waterman style, fuzzy text match, same speaker) against
// the transcript so far. Matched bubbles vote on their text (OCR noise averages
// out; a bubble half-hidden under the header loses to its full version). New
// bubbles are added at whichever end the frame extends — scrolling up or down
// both work.

public struct Entry {
    public var side: Side
    public var sender: String?
    var variants: [String: Int]
    var seen: Int

    init(_ m: FrameMessage) {
        side = m.side; sender = m.sender; variants = [m.text: 1]; seen = 1
    }

    static func gap() -> Entry {
        var e = Entry(FrameMessage(side: .system, sender: nil, text: Entry.gapText))
        e.seen = 99
        return e
    }
    static let gapText = "[…some messages may be missing here…]"

    /// Most-voted variant, where a variant that is a fragment of a longer one
    /// donates its votes to it.
    public var text: String {
        let norms = variants.keys.map { ($0, TextSim.norm($0)) }
        var best = "", bestScore = -1
        for (v, nv) in norms {
            var score = variants[v]!
            for (w, nw) in norms where w != v && nw.count < nv.count && !nw.isEmpty && nv.contains(nw) {
                score += variants[w]!
            }
            if score > bestScore || (score == bestScore && v.count > best.count) { best = v; bestScore = score }
        }
        return best
    }

    mutating func absorb(_ m: FrameMessage) {
        variants[m.text, default: 0] += 1
        seen += 1
        if sender == nil { sender = m.sender }
    }
}

enum TextSim {
    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static func sim(_ a: String, _ b: String) -> Double {
        let x = norm(a), y = norm(b)
        if x.isEmpty || y.isEmpty { return a == b ? 1 : 0 }
        if x == y { return 1 }
        let (s, l) = x.count <= y.count ? (x, y) : (y, x)
        if s.count >= 6 && l.contains(s) { return 0.9 }
        if s.count < 4 { return 0 }
        if Double(s.count) / Double(l.count) < 0.6 { return 0 }
        let xa = Array(x.prefix(160)), ya = Array(y.prefix(160))
        return 1 - Double(levenshtein(xa, ya)) / Double(max(xa.count, ya.count))
    }
}

/// One contiguous stretch of conversation built from overlapping frames.
final class Segment {
    var entries: [Entry]
    var anchor: Int
    var appended = 0, prepended = 0
    init(_ frame: [FrameMessage]) { entries = frame.map(Entry.init); anchor = entries.count - 1 }

    struct Alignment { var pairs: [(Int, Int)]; var lo: Int; var score: Double }

    private func score(_ e: Entry, _ m: FrameMessage) -> Double {
        guard e.side == m.side else { return 0 }
        var best = 0.0
        for v in e.variants.keys.prefix(6) { best = max(best, TextSim.sim(v, m.text)) }
        return best >= TranscriptMerger.threshold ? best : 0
    }

    /// Local alignment of the frame against a window of this segment.
    func align(_ B: [FrameMessage]) -> Alignment {
        let lo = max(0, anchor - 80), hi = min(entries.count, anchor + 80)
        let A = Array(entries[lo..<hi])
        let n = A.count, m = B.count
        let gap = -0.6
        var dp = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var bt = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1)
        var best = 0.0, bi = 0, bj = 0
        for i in 1...max(1, n) where n > 0 {
            for j in 1...m {
                var v = 0.0, d: UInt8 = 0
                let s = score(A[i - 1], B[j - 1])
                if s > 0, dp[i - 1][j - 1] + 1 + s > v { v = dp[i - 1][j - 1] + 1 + s; d = 1 }
                if dp[i - 1][j] + gap > v { v = dp[i - 1][j] + gap; d = 2 }
                if dp[i][j - 1] + gap > v { v = dp[i][j - 1] + gap; d = 3 }
                dp[i][j] = v; bt[i][j] = d
                if v > best { best = v; bi = i; bj = j }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = bi, j = bj
        while i > 0, j > 0, bt[i][j] != 0 {
            switch bt[i][j] {
            case 1: pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            case 2: i -= 1
            default: j -= 1
            }
        }
        return Alignment(pairs: pairs.reversed(), lo: lo, score: best)
    }

    func apply(_ al: Alignment, _ B: [FrameMessage]) {
        let pairs = al.pairs, lo = al.lo, m = B.count
        for (pi, pj) in pairs { entries[lo + pi].absorb(B[pj]) }

        // Inserts, applied back-to-front so indices stay valid.
        var inserts: [(at: Int, items: [FrameMessage])] = []
        let (fi, fj) = pairs.first!, (li, lj) = pairs.last!
        if lo + fi == 0, fj > 0 { inserts.append((0, Array(B[0..<fj]))) }
        for k in 1..<max(1, pairs.count) {
            let (i1, j1) = pairs[k - 1], (i2, j2) = pairs[k]
            if i2 == i1 + 1, j2 > j1 + 1 { inserts.append((lo + i2, Array(B[(j1 + 1)..<j2]))) }
        }
        if lo + li == entries.count - 1 && lj < m - 1 {
            entries += B[(lj + 1)...].map(Entry.init)
            appended += 1
        }
        for ins in inserts.sorted(by: { $0.at > $1.at }) {
            entries.insert(contentsOf: ins.items.map(Entry.init), at: ins.at)
        }
        let pre = inserts.first(where: { $0.at == 0 })?.items.count ?? 0
        if pre > 0 { prepended += 1 }
        anchor = min(entries.count - 1, lo + pairs[pairs.count / 2].0 + pre)
    }

    var asFrame: [FrameMessage] { entries.map { FrameMessage(side: $0.side, sender: $0.sender, text: $0.text) } }
}

public final class TranscriptMerger {
    private var segments: [Segment] = []   // in creation (time) order
    private var startedAtBottom = false
    static let threshold = 0.72

    public init() {}

    public func add(_ frame: [FrameMessage], atBottom: Bool = false) {
        guard !frame.isEmpty else { return }
        if segments.isEmpty {
            segments.append(Segment(frame)); startedAtBottom = atBottom
            return
        }
        let scored = segments.enumerated()
            .map { ($0.offset, $0.element.align(frame)) }
            .filter { !$0.1.pairs.isEmpty }
            .sorted { $0.1.score > $1.1.score }
        guard let (bestIdx, al) = scored.first else {
            // No overlap with anything yet: the user scrolled faster than we
            // sampled. Start a new stretch if the frame clearly shows chat.
            if frame.filter({ $0.side != .system }).count >= 2 { segments.append(Segment(frame)) }
            return
        }
        let seg = segments[bestIdx]
        seg.apply(al, frame)
        // The frame bridged two stretches: fold the other one in.
        var absorbed: [Int] = []
        for (idx, _) in scored.dropFirst() {
            let other = segments[idx]
            let al2 = seg.align(other.asFrame)
            guard !al2.pairs.isEmpty else { continue }
            seg.apply(al2, other.asFrame)
            seg.appended += other.appended; seg.prepended += other.prepended
            absorbed.append(idx)
        }
        for idx in absorbed.sorted(by: >) { segments.remove(at: idx) }
    }

    /// Joins the stretches in conversation order, then tidies: drops one-frame
    /// OCR flukes sitting between well-seen bubbles and collapses duplicates.
    public func finished() -> [Entry] {
        let up = segments.reduce(0) { $0 + $1.prepended }, down = segments.reduce(0) { $0 + $1.appended }
        // No scroll evidence? A recording that opens at the newest message can only scroll up.
        let scrolledUp = up != down ? up > down : startedAtBottom
        var ordered = scrolledUp ? Array(segments.reversed()) : segments
        var entries: [Entry] = []
        for (k, s) in ordered.enumerated() {
            if k > 0 { entries.append(Entry.gap()) }
            entries += s.entries
        }
        ordered.removeAll()

        var out: [Entry] = []
        for (k, e) in entries.enumerated() {
            let prevSeen = k > 0 ? entries[k - 1].seen : 0
            let nextSeen = k + 1 < entries.count ? entries[k + 1].seen : 0
            if e.seen == 1 && prevSeen >= 3 && nextSeen >= 3 { continue }
            if let last = out.last, last.side == e.side, TextSim.sim(last.text, e.text) >= 0.9 {
                out[out.count - 1].variants.merge(e.variants, uniquingKeysWith: +)
                out[out.count - 1].seen += e.seen
                continue
            }
            out.append(e)
        }
        while out.last?.text == Entry.gapText { out.removeLast() }
        while out.first?.text == Entry.gapText { out.removeFirst() }
        return out
    }
}
