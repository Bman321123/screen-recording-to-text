import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import CoreVideo

// Composites header/body/footer PNGs into a scrolling "screen recording".
//   makevideo <dir> <out.mp4> <up|down>
let a = CommandLine.arguments
let dir = a[1], outPath = a[2], mode = a[3]
func load(_ n: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(dir)/\(n)") as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
let header = load("header.png"), footer = load("footer.png"), bodyFull = load("body.png"), cc = load("cc.png")

// Trim trailing background rows from the body screenshot.
func contentHeight(_ img: CGImage) -> Int {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let bg = (buf[0], buf[1], buf[2])
    for y in stride(from: h - 1, through: 0, by: -1) {
        for x in stride(from: 0, to: w, by: 3) {
            let i = (y * w + x) * 4
            if abs(Int(buf[i]) - Int(bg.0)) + abs(Int(buf[i+1]) - Int(bg.1)) + abs(Int(buf[i+2]) - Int(bg.2)) > 30 {
                return min(h, y + 60)
            }
        }
    }
    return h
}
let bodyH = contentHeight(bodyFull)
let body = bodyFull.cropping(to: CGRect(x: 0, y: 0, width: bodyFull.width, height: bodyH))!

let W = 1170, H = 2532
let areaTop = header.height, areaBottom = H - footer.height
let areaH = areaBottom - areaTop
let maxOff = max(0, bodyH - areaH)

// Keyframes of scroll offset (0 = top of conversation visible).
var keys: [(t: Double, off: Double)] = []
let ttime = Double(ProcessInfo.processInfo.environment["TTIME"] ?? "0.45") ?? 0.45
let flick = Double(areaH) * (Double(ProcessInfo.processInfo.environment["FLICK"] ?? "0.55") ?? 0.55)
if mode == "up" {
    var off = Double(maxOff), t = 0.9
    keys.append((t, off))
    while off > 0 { t += 0.35; keys.append((t, off)); off = max(0, off - flick); t += ttime; keys.append((t, off)) }
    keys.append((t + 0.6, 0))
} else {
    var off = 0.0, t = 0.9
    keys.append((t, off))
    while off < Double(maxOff) { t += 0.35; keys.append((t, off)); off = min(Double(maxOff), off + flick); t += ttime; keys.append((t, off)) }
    keys.append((t + 0.6, Double(maxOff)))
}
let total = keys.last!.t + 0.6
func offset(at t: Double) -> Double {
    if t <= keys[0].t { return keys[0].off }
    for k in 1..<keys.count where t <= keys[k].t {
        let a = keys[k - 1], b = keys[k]
        var p = (t - a.t) / (b.t - a.t); p = p * p * (3 - 2 * p)
        return a.off + (b.off - a.off) * p
    }
    return keys.last!.off
}

try? FileManager.default.removeItem(atPath: outPath)
let writer = try! AVAssetWriter(outputURL: URL(fileURLWithPath: outPath), fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: W,
    kCVPixelBufferHeightKey as String: H])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)

let fps = 30
let frames = Int(total * Double(fps))
for f in 0..<frames {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    let t = Double(f) / Double(fps)
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    // CG origin is bottom-left; convert top-left y.
    func draw(_ img: CGImage, top: Int) {
        ctx.draw(img, in: CGRect(x: 0, y: H - top - img.height, width: img.width, height: img.height))
    }
    if t < 0.5 || t > total - 0.3 {
        draw(cc, top: 0)   // Control Center at start/end of a real screen recording
    } else {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        draw(footer, top: areaBottom)   // fills bottom background first
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: H - areaBottom, width: W, height: areaH))
        draw(body, top: areaTop - Int(offset(at: t)))
        ctx.restoreGState()
        draw(header, top: 0)
        draw(footer, top: areaBottom)
    }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let s = DispatchSemaphore(value: 0)
writer.finishWriting { s.signal() }
s.wait()
print("wrote \(outPath) \(String(format: "%.1f", total))s, body \(bodyH)px, area \(areaH)px")
