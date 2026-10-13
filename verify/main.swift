import Foundation

// macOS harness: runs the exact same Core pipeline the iPhone app uses.
//   verify <video> [fps]
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: verify <video> [fps]"); exit(2) }
let url = URL(fileURLWithPath: args[1])
let fps = args.count > 2 ? Double(args[2]) ?? 4 : 4

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        let start = Date()
        let out = try await VideoTranscriber.run(url: url, fps: fps) { _, _ in }
        let md = TranscriptRenderer.render(out, myName: "Me", theirName: "", format: .markdown)
        print(md)
        FileHandle.standardError.write(
            "frames read \(out.framesRead), used \(out.framesUsed), \(String(format: "%.1f", Date().timeIntervalSince(start)))s\n"
                .data(using: .utf8)!)
    } catch {
        print("error: \(error)")
    }
    sema.signal()
}
sema.wait()
