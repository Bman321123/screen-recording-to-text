import Foundation
import AVFoundation
import CoreGraphics

public struct TranscriptionOutput {
    public var entries: [Entry]
    public var headerName: String?
    public var framesRead: Int
    public var framesUsed: Int
}

public enum VideoTranscriber {
    /// Samples `fps` frames per second, OCRs each, and stitches the conversation.
    public static func run(url: URL, fps: Double = 4,
                           progress: @escaping (Double, String) -> Void) async throws -> TranscriptionOutput {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw NSError(domain: "ChatTranscriber", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "That video has no readable frames."]) }

        let times = stride(from: 0.0, to: duration, by: 1 / fps).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)

        let analyzer = FrameAnalyzer()
        var results: [FrameResult] = []
        var lastThumb: [UInt8]?
        var read = 0
        for await item in gen.images(for: times) {
            read += 1
            progress(Double(read) / Double(times.count), "Reading frame \(read) of \(times.count)")
            guard let image = try? item.image else { continue }
            // Skip frames where nothing moved — same text, no new information.
            let thumb = thumbnail(image)
            if let last = lastThumb, meanDiff(last, thumb) < 1.0 { continue }
            lastThumb = thumb
            results.append(try analyzer.analyze(image))
        }

        progress(1, "Stitching conversation…")

        // The contact name in the header is the same in every real chat frame.
        // Frames that disagree (Control Center at the start/end of a screen
        // recording, the home screen, another app) are dropped.
        let consensus = mostCommon(results.compactMap(\.headerName))
        let chatFrames = results.filter { r in
            guard r.messages.contains(where: { $0.side != .system }) else { return false }
            guard let consensus else { return true }
            if let h = r.headerName { return TextSim.sim(h, consensus) >= 0.8 || h == consensus }
            return r.hasInputBar
        }

        let merger = TranscriptMerger()
        for f in chatFrames { merger.add(f.messages, atBottom: f.atBottom) }
        return TranscriptionOutput(entries: merger.finished(), headerName: consensus,
                                   framesRead: read, framesUsed: chatFrames.count)
    }

    static func mostCommon(_ names: [String]) -> String? {
        var counts: [String: Int] = [:]
        for n in names { counts[n, default: 0] += 1 }
        // Fold OCR near-misses into their best-supported spelling.
        let keys = counts.keys.sorted { counts[$0]! > counts[$1]! }
        guard let top = keys.first else { return nil }
        let support = keys.filter { TextSim.sim($0, top) >= 0.8 || $0 == top }.reduce(0) { $0 + counts[$1]! }
        return support * 5 >= names.count ? top : nil
    }

    static func thumbnail(_ image: CGImage) -> [UInt8] {
        let w = 24, h = 52
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return buf
    }

    static func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var s = 0
        for i in 0..<min(a.count, b.count) { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }
}

public enum TranscriptFormat: String, CaseIterable, Identifiable {
    case markdown = "md", text = "txt"
    public var id: String { rawValue }
}

public enum TranscriptRenderer {
    /// One line per message — `Name: text` — the cheapest form for an LLM to read.
    public static func render(_ out: TranscriptionOutput, myName: String, theirName: String,
                              format: TranscriptFormat, date: Date = Date()) -> String {
        let me = myName.trimmingCharacters(in: .whitespaces).isEmpty ? "Me" : myName
        let them = theirName.trimmingCharacters(in: .whitespaces).isEmpty
            ? (out.headerName ?? "Them") : theirName
        let isGroup = out.entries.contains { $0.side == .them && $0.sender != nil }
        let count = out.entries.filter { $0.side != .system }.count

        let df = DateFormatter(); df.dateStyle = .medium
        var lines: [String] = []
        switch format {
        case .markdown:
            lines.append("# Text conversation: \(me) and \(isGroup ? (out.headerName ?? "group") : them)")
            lines.append("_Screen-recording transcript, \(df.string(from: date)), \(count) messages. OCR'd, so expect small typos; emoji and images are not captured._")
        case .text:
            lines.append("Text conversation: \(me) and \(isGroup ? (out.headerName ?? "group") : them)")
            lines.append("(Screen-recording transcript, \(df.string(from: date)), \(count) messages. OCR'd; emoji/images not captured.)")
        }
        lines.append("")

        var lastSender = them
        for e in out.entries {
            switch e.side {
            case .system:
                lines.append("--- \(e.text) ---")
            case .me:
                lines.append("\(me): \(e.text)")
            case .them:
                let who = isGroup ? (e.sender ?? lastSender) : them
                lastSender = who
                lines.append("\(who): \(e.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
