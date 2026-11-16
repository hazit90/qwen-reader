import AppKit
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

/// Opens the Voices window. Managed with AppKit because the app has no Dock icon or main window.
@MainActor
final class VoicesWindow {
    static let shared = VoicesWindow()
    private var window: NSWindow?

    func show(app: AppModel) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: VoicesView(app: app)))
            window.title = "Qwen Reader Voices"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 540, height: 680))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Chooses a voice, and adds cloned voices by recording or importing a clip.
struct VoicesView: View {
    private static let previewText = "Here's how I sound. Select any text and press Control Option S to hear it read aloud."

    enum Source: String, CaseIterable, Identifiable {
        case record = "Record"
        case file = "Import File"
        var id: Self { self }
    }

    @Bindable var app: AppModel
    @State private var recorder = VoiceRecorder()
    @State private var source = Source.record
    @State private var name = ""
    @State private var transcript = ""
    @State private var importedClip: URL?
    @State private var errorMessage: String?
    @State private var preview: NSSound?

    var body: some View {
        Form {
            cloningSections
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 560)
        .onChange(of: source) { errorMessage = nil }
    }

    @ViewBuilder
    private var cloningSections: some View {
        Section {
            voiceRow(name: "Default Voice", detail: "The model's own voice", selection: .standard)
            ForEach(app.voices.voices) { voice in
                voiceRow(name: voice.name, detail: voice.transcript, selection: .cloned(voice.id)) {
                    Button("Play sample", systemImage: "play.circle") {
                        play(app.voices.audioURL(for: voice))
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        app.deleteVoice(voice)
                    }
                }
            }
        } header: {
            HStack {
                Text("Voices")
                Spacer()
                Button("Preview", systemImage: "play.circle") {
                    app.reader.read(Self.previewText)
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
            }
        }

        Section {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Name", text: $name, prompt: Text("For example, My Voice"))

            switch source {
            case .record: recordFields
            case .file: importFields
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Save Voice", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        } header: {
            Text("Add a Voice")
        } footer: {
            Text("Use 5–15 seconds of clear speech from one person, with no music or background noise. A cloned voice takes about twice as long to generate as the default voice.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func voiceRow(
        name: String, detail: String, selection: VoiceSelection,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        let isSelected = app.voiceSelection == selection
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            actions()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        .onTapGesture { app.selectVoice(selection) }
    }

    @ViewBuilder
    private var recordFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read this aloud in a quiet room:")
                .foregroundStyle(.secondary)
            Text(VoiceRecorder.passage)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button(recorder.isRecording ? "Stop" : recorder.recordingURL == nil ? "Start Recording" : "Record Again",
                   systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle") {
                toggleRecording()
            }
            Text(recorder.elapsed.formatted(.number.precision(.fractionLength(1))) + " s")
                .monospacedDigit()
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
            Spacer()
            if let url = recorder.recordingURL, !recorder.isRecording {
                Button("Play Back", systemImage: "play.circle") { play(url) }
            }
        }
    }

    @ViewBuilder
    private var importFields: some View {
        HStack {
            Button("Choose Audio File…", action: chooseFile)
            Text(importedClip?.lastPathComponent ?? "No file chosen")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        TextField("Transcript", text: $transcript, prompt: Text("Exactly what is said in the clip"), axis: .vertical)
            .lineLimit(3 ... 6)
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch source {
        case .record:
            return recorder.recordingURL != nil && !recorder.isRecording
        case .file:
            return importedClip != nil && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func toggleRecording() {
        errorMessage = nil
        if recorder.isRecording {
            recorder.stop()
            return
        }
        Task {
            do {
                try await recorder.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            importedClip = panel.url
            errorMessage = nil
        }
    }

    private func play(_ url: URL) {
        preview?.stop()
        preview = NSSound(contentsOf: url, byReference: true)
        preview?.play()
    }

    private func save() {
        let clip: URL?
        let spokenText: String
        switch source {
        case .record:
            clip = recorder.recordingURL
            spokenText = VoiceRecorder.passage
        case .file:
            clip = importedClip
            spokenText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let clip else { return }

        do {
            let voice = try app.voices.add(
                name: name.trimmingCharacters(in: .whitespaces), transcript: spokenText, clip: clip
            )
            app.selectVoice(.cloned(voice.id))
            recorder.discard()
            name = ""
            transcript = ""
            importedClip = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
