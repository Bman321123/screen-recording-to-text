import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A picked video, copied out of the Photos sandbox into our temp dir.
struct Movie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return Movie(url: dst)
        }
    }
}

@MainActor
final class Model: ObservableObject {
    enum Phase { case idle, loading, working(Double, String), done, failed(String) }
    @Published var phase: Phase = .idle
    @Published var output: TranscriptionOutput?
    @Published var transcript = ""
    @Published var fileURL: URL?

    func run(_ item: PhotosPickerItem, fps: Double) async {
        phase = .loading
        output = nil
        do {
            guard let movie = try await item.loadTransferable(type: Movie.self) else {
                phase = .failed("Couldn't load that video."); return
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            let out = try await Task.detached(priority: .userInitiated) {
                try await VideoTranscriber.run(url: movie.url, fps: fps) { p, msg in
                    Task { @MainActor in self.phase = .working(p, msg) }
                }
            }.value
            guard !out.entries.isEmpty else {
                phase = .failed("No messages found. Record the Messages app itself, scrolling slowly through the chat.")
                return
            }
            output = out
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func render(me: String, them: String, format: TranscriptFormat) {
        guard let output else { return }
        transcript = TranscriptRenderer.render(output, myName: me, theirName: them, format: format)
        writeFile(them: them, format: format)
    }

    func writeFile(them: String, format: TranscriptFormat) {
        let who = (them.isEmpty ? output?.headerName ?? "chat" : them)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-\(who.isEmpty ? "chat" : who)-\(df.string(from: Date()))")
            .appendingPathExtension(format.rawValue)
        try? transcript.write(to: url, atomically: true, encoding: .utf8)
        fileURL = url
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var pick: PhotosPickerItem?
    @AppStorage("myName") private var myName = "Me"
    @AppStorage("theirName") private var theirName = ""
    @AppStorage("format") private var format: TranscriptFormat = .markdown
    @AppStorage("thorough") private var thorough = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $pick, matching: .videos) {
                        Label("Choose screen recording", systemImage: "video.badge.plus")
                            .font(.headline)
                    }
                    .disabled(isBusy)
                } footer: {
                    Text("Open the chat, start a screen recording, scroll through the messages at a steady pace, then pick the video here. Everything runs on your phone.")
                }

                Section("Names") {
                    LabeledContent("You") {
                        TextField("Me", text: $myName).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Them") {
                        TextField(model.output?.headerName ?? "Auto (from chat header)", text: $theirName)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("File type", selection: $format) {
                        Text("Markdown (.md)").tag(TranscriptFormat.markdown)
                        Text("Plain text (.txt)").tag(TranscriptFormat.text)
                    }
                    Toggle("Thorough (slower, for fast scrolling)", isOn: $thorough)
                }

                statusSection

                if model.output != nil {
                    Section {
                        TextEditor(text: $model.transcript)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 320)
                            .onChange(of: model.transcript) { _, _ in
                                model.writeFile(them: theirName, format: format)
                            }
                    } header: {
                        Text("Transcript: tap to fix typos")
                    } footer: {
                        if let o = model.output {
                            Text("\(o.entries.filter { $0.side != .system }.count) messages, ~\(model.transcript.count / 4) tokens. Used \(o.framesUsed) of \(o.framesRead) frames.")
                        }
                    }
                }
            }
            .navigationTitle("Chat → Text")
            .toolbar {
                if model.output != nil, let url = model.fileURL {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            UIPasteboard.general.string = model.transcript
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Spacer()
                        ShareLink(item: url) {
                            Label("Share file", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                await model.run(item, fps: thorough ? 8 : 4)
                model.render(me: myName, them: theirName, format: format)
                pick = nil
            }
        }
        .onChange(of: myName) { _, _ in model.render(me: myName, them: theirName, format: format) }
        .onChange(of: theirName) { _, _ in model.render(me: myName, them: theirName, format: format) }
        .onChange(of: format) { _, _ in model.render(me: myName, them: theirName, format: format) }
    }

    private var isBusy: Bool {
        switch model.phase { case .loading, .working: return true; default: return false }
    }

    @ViewBuilder private var statusSection: some View {
        switch model.phase {
        case .idle, .done:
            EmptyView()
        case .loading:
            Section { HStack { ProgressView(); Text("Loading video…").padding(.leading, 8) } }
        case .working(let p, let msg):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: p)
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .failed(let msg):
            Section { Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
    }
}
