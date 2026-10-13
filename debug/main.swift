import Foundation; import AVFoundation
// debug <video> <seconds...> : OCR lines + parsed bubbles for given timestamps
let a = CommandLine.arguments
let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: a[1])))
gen.appliesPreferredTrackTransform = true; gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
let an = FrameAnalyzer()
for s in a[2...] {
    let img = try! gen.copyCGImage(at: CMTime(seconds: Double(s)!, preferredTimescale: 600), actualTime: nil)
    print("== t=\(s)")
    for l in try! an.ocr(img) { print(String(format: "  ocr x%.3f-%.3f y%.3f-%.3f %@", l.rect.minX, l.rect.maxX, l.rect.minY, l.rect.maxY, l.text)) }
    let r = try! an.analyze(img)
    print("  header=\(r.headerName ?? "nil") bar=\(r.hasInputBar)")
    for m in r.messages { print("  [\(m.side.rawValue)\(m.sender.map { ":" + $0 } ?? "")] \(m.text)") }
}
