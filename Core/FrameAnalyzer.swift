import Foundation
import CoreGraphics
import Vision

// Reads one screenshot of a messaging app and returns its bubbles top-to-bottom.
//
// Speaker detection never relies on bubble *colour names* (blue/green/gray) so it
// keeps working in dark mode, SMS, custom iOS 26 backgrounds and other apps:
//   1. a text line is "in a bubble" if the pixels just outside its OCR box differ
//      from the local background;
//   2. we scan outward to find the bubble's left/right edges;
//   3. a bubble hugging the right edge is "me", hugging the left is "them".
// Lines are joined into one message when a vertical scan between them never
// leaves the bubble colour.

public enum Side: String, Codable { case me, them, system }

public struct FrameMessage {
    public var side: Side
    public var sender: String?
    public var text: String
}

public struct FrameResult {
    public var messages: [FrameMessage]
    public var headerName: String?
    public var hasInputBar: Bool
    /// The newest message sits right above the input bar — chat is scrolled to the bottom.
    public var atBottom: Bool = false
}

struct RGB {
    var r: Double, g: Double, b: Double
    func dist(_ o: RGB) -> Double {
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

final class PixelBuffer {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; data = buf
    }

    /// Single pixel, top-left pixel coordinates.
    func pixel(_ x: Int, _ y: Int) -> RGB {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        let i = (cy * width + cx) * 4
        return RGB(r: Double(data[i]), g: Double(data[i + 1]), b: Double(data[i + 2]))
    }

    /// 3x3 average at normalized top-left coordinates.
    func color(_ nx: Double, _ ny: Double) -> RGB {
        let x = Int(nx * Double(width)), y = Int(ny * Double(height))
        var r = 0.0, g = 0.0, b = 0.0
        for dy in -1...1 { for dx in -1...1 {
            let p = pixel(x + dx, y + dy); r += p.r; g += p.g; b += p.b
        } }
        return RGB(r: r / 9, g: g / 9, b: b / 9)
    }
}

struct OCRLine {
    var text: String
    var conf: Float
    var rect: CGRect   // normalized, top-left origin
}

public final class FrameAnalyzer {
    public init() {}

    private static let placeholder = try! NSRegularExpression(
        pattern: #"^(imessage|text message|rcs message|message)\b"#, options: [.caseInsensitive])
    private static let status = try! NSRegularExpression(
        pattern: #"^(delivered|read|sent|edited|not delivered|kept|undo send|sending|seen)\b"#,
        options: [.caseInsensitive])
    private static let initials = try! NSRegularExpression(pattern: #"^[A-Z]{1,2}$"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // Recognition is English-only, so any Cyrillic Vision emits on a compressed
    // frame is a look-alike misread ("np" -> "пр"). Map it back.
    private static let homoglyphs: [Character: Character] = [
        "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o", "п": "n", "р": "p",
        "с": "c", "т": "t", "у": "y", "х": "x", "ь": "b", "А": "A", "В": "B", "Е": "E", "К": "K",
        "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X"]
    static func latinize(_ s: String) -> String {
        String(s.map { homoglyphs[$0] ?? $0 })
    }

    func ocr(_ image: CGImage) throws -> [OCRLine] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        return (req.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            let text = Self.latinize(c.string.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, conf: c.confidence,
                           rect: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
    }

    public func analyze(_ image: CGImage) throws -> FrameResult {
        let lines = try ocr(image)
        guard let px = PixelBuffer(image) else { return FrameResult(messages: [], headerName: nil, hasInputBar: false) }

        // --- Header: contact name centered under the status bar. ---
        var headerName: String?
        var top = 0.14
        let headerCands = lines
            .filter { $0.rect.minY > 0.045 && $0.rect.minY < 0.2 && abs($0.rect.midX - 0.5) < 0.12
                      && $0.rect.width < 0.6 && $0.conf > 0.3 }
            .filter { !Self.matches(Self.initials, $0.text) }
            .sorted { $0.rect.minY < $1.rect.minY }
        if let name = headerCands.first {
            headerName = name.text.trimmingCharacters(in: CharacterSet(charactersIn: " >›〉"))
            top = Double(name.rect.maxY) + 0.012
        }

        // --- Input bar: "iMessage" / "Text Message" placeholder. ---
        var bottom = 0.9
        let bar = lines
            .filter { $0.rect.minY > 0.45 && $0.rect.minX < 0.45 && Self.matches(Self.placeholder, $0.text) }
            .max { $0.rect.minY < $1.rect.minY }
        if let bar { bottom = Double(bar.rect.minY) - 0.015 }

        let body = lines.filter {
            Double($0.rect.minY) >= top && Double($0.rect.maxY) <= bottom && $0.conf >= 0.25
        }

        // --- Classify each line. ---
        struct Classified {
            var line: OCRLine
            var inBubble: Bool
            var side: Side = .system
            var left = 0.0, right = 0.0          // bubble edges
            var bubble = RGB(r: 0, g: 0, b: 0)
            var bg = RGB(r: 0, g: 0, b: 0)
        }

        func localBG(_ y: Double, preferRight: Bool) -> RGB {
            px.color(preferRight ? 0.992 : 0.008, y)
        }

        func scanEdge(from nx: Double, y ny: Double, step: Int, bubble: RGB, bg: RGB) -> Double {
            var x = Int(nx * Double(px.width))
            let y = Int(ny * Double(px.height))
            var misses = 0
            var lastGood = x
            while x > 0 && x < px.width - 1 {
                let p = px.pixel(x, y)
                if p.dist(bubble) < p.dist(bg) { lastGood = x; misses = 0 } else {
                    misses += 1
                    if misses >= 3 { break }
                }
                x += step
            }
            return Double(lastGood) / Double(px.width)
        }

        let dx = 0.014
        var cls: [Classified] = body.map { line in
            let r = line.rect
            let y = Double(r.midY)
            let bg = localBG(y, preferRight: r.midX > 0.5)
            let lx = Double(r.minX) - dx, rx = Double(r.maxX) + dx
            let cl = px.color(lx, y), cr = px.color(rx, y)
            let dl = cl.dist(bg), dr = cr.dist(bg)
            var c = Classified(line: line, inBubble: max(dl, dr) > 20)
            c.bg = bg
            guard c.inBubble else { return c }
            c.bubble = dl >= dr ? cl : cr
            c.left = dl > 20 ? scanEdge(from: lx, y: y, step: -1, bubble: c.bubble, bg: bg) : Double(r.minX)
            c.right = dr > 20 ? scanEdge(from: rx, y: y, step: 1, bubble: c.bubble, bg: bg) : Double(r.maxX)
            c.side = (1 - c.right) < c.left ? .me : .them
            return c
        }

        // Drop initials avatars ("AB" in a gray circle at the far left of group chats).
        cls.removeAll { $0.inBubble && Self.matches(Self.initials, $0.line.text)
                        && $0.right - $0.left < 0.14 && $0.left < 0.06 }

        // Reading order: rows top-to-bottom, left-to-right within a row.
        cls.sort { a, b in
            let ha = Double(min(a.line.rect.height, b.line.rect.height)) * 0.4
            if abs(Double(a.line.rect.midY - b.line.rect.midY)) < ha { return a.line.rect.minX < b.line.rect.minX }
            return a.line.rect.midY < b.line.rect.midY
        }

        func sameBubble(_ a: Classified, _ b: Classified) -> Bool {
            guard a.inBubble, b.inBubble, a.side == b.side else { return false }
            let ol = max(a.left, b.left), orr = min(a.right, b.right)
            guard orr > ol + 0.03 else { return false }
            let y0 = Double(a.line.rect.maxY), y1 = Double(b.line.rect.minY)
            if y1 <= y0 { return true }
            if y1 - y0 > 1.6 * Double(max(a.line.rect.height, b.line.rect.height)) { return false }
            // Walk down the bubble's side padding (never text) looking for background.
            let x = Int((ol + 0.012) * Double(px.width))
            let p0 = Int(y0 * Double(px.height)), p1 = Int(y1 * Double(px.height))
            var run = 0
            for py in p0...max(p0, p1) {
                let p = px.pixel(x, py)
                if p.dist(a.bubble) <= p.dist(a.bg) { run = 0 } else {
                    run += 1
                    if run >= 2 { return false }
                }
            }
            return true
        }

        // --- Build messages. ---
        struct Built { var msg: FrameMessage; var top: Double; var bottom: Double; var left: Double; var cls: Classified }
        var built: [Built] = []
        var labels: [Classified] = []
        for c in cls {
            if c.inBubble {
                if let last = built.last, last.msg.side != .system, sameBubble(last.cls, c) {
                    built[built.count - 1].msg.text += " " + c.line.text
                    built[built.count - 1].bottom = Double(c.line.rect.maxY)
                    built[built.count - 1].cls = c
                } else {
                    built.append(Built(msg: FrameMessage(side: c.side, sender: nil, text: c.line.text),
                                       top: Double(c.line.rect.minY), bottom: Double(c.line.rect.maxY),
                                       left: c.left, cls: c))
                }
            } else if Self.matches(Self.status, c.line.text) {
                continue
            } else if abs(Double(c.line.rect.midX) - 0.5) < 0.15 {
                built.append(Built(msg: FrameMessage(side: .system, sender: nil, text: c.line.text),
                                   top: Double(c.line.rect.minY), bottom: Double(c.line.rect.maxY),
                                   left: Double(c.line.rect.minX), cls: c))
            } else if c.line.rect.minX < 0.35 {
                labels.append(c)   // maybe a group-chat sender name
            }
        }

        // Group-chat names sit just above the first bubble of a run.
        for label in labels {
            let ly = Double(label.line.rect.maxY)
            guard let i = built.firstIndex(where: { $0.top >= ly - 0.002 }),
                  built[i].msg.side == .them, built[i].top - ly < 0.05,
                  abs(built[i].left - Double(label.line.rect.minX)) < 0.1 else { continue }
            var j = i
            while j < built.count, built[j].msg.side == .them {
                if j > i, built[j].msg.sender != nil { break }
                built[j].msg.sender = label.line.text
                j += 1
            }
        }

        let atBottom = bar != nil && (built.last.map { bottom - $0.bottom < 0.07 } ?? false)
        return FrameResult(messages: built.map(\.msg), headerName: headerName, hasInputBar: bar != nil,
                           atBottom: atBottom)
    }
}
