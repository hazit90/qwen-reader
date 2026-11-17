import AppKit
import ReaderCore
import SwiftUI

/// Opens the setup window: shown on first launch, and whenever a read is attempted without a model.
/// Managed with AppKit because the app has no Dock icon or main window.
@MainActor
final class SetupWindow {
    static let shared = SetupWindow()
    private var window: NSWindow?

    func show(app: AppModel) {
        if window == nil {
            let controller = NSHostingController(rootView: SetupView(app: app) { [weak self] in self?.close() })
            let window = NSWindow(contentViewController: controller)
            window.title = "Qwen Reader"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // A menu bar app isn't always allowed to activate itself, and this window must not open
        // hidden behind whatever the user is working in.
        window?.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }
}

/// Walks through getting the voice model, by download or from a folder on disk, then shows how
/// to start reading.
struct SetupView: View {
    let app: AppModel
    let close: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 6) {
                Text("Qwen Reader")
                    .font(.title2.bold())
                Text("Reads selected text aloud, in the model's own voice or a clone of yours. Everything runs on this Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            switch app.library.state {
            case .missing: missing
            case .downloading, .importing: transferring
            case .installed: installed
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    // MARK: - No model yet

    @ViewBuilder
    private var missing: some View {
        Text("Qwen Reader needs the \(VoiceModel.displayName) voice model: a one-time \(VoiceModel.downloadSize.formatted(.byteCount(style: .file))) download from Hugging Face.")
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if let problem = app.library.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Use a Model on Disk…") { app.chooseModelFolder() }
            Button(app.library.hasPartialDownload ? "Resume Download" : "Download Model") { app.downloadModel() }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        Text("Already downloaded it? Choose its folder, or drop the folder here, and Qwen Reader makes its own copy.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(isDropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard let folder = urls.first else { return false }
                app.library.importModel(from: folder)
                return true
            } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: - Downloading or copying

    @ViewBuilder
    private var transferring: some View {
        let isDownload = if case .downloading = app.library.state { true } else { false }
        VStack(alignment: .leading, spacing: 6) {
            Text(isDownload ? "Downloading the voice model…" : "Copying the voice model…")
            ProgressView(value: app.library.transferFraction ?? 0)
            Text(app.library.transferDescription ?? " ")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        HStack {
            Text(isDownload
                ? "You can close this window. The menu bar icon shows progress, and a paused download carries on from where it stopped."
                : "This only takes a moment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(isDownload ? "Pause" : "Cancel") { app.library.cancel() }
        }
    }

    // MARK: - Installed

    /// Shown until macOS lets the app see the selection, since without it reading silently fails.
    @ViewBuilder
    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Qwen Reader needs Accessibility access", systemImage: "lock.shield.fill")
                .font(.headline)
            Text("macOS asks for this before an app can see the text you select. Turn on Qwen Reader under Privacy & Security › Accessibility.")
            Text("If Qwen Reader is already switched on there but reading still doesn't work, the entry belongs to an older copy of the app: select it, remove it with the – button, then add this copy again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Accessibility Settings…") { app.requestAccessibilityAccess() }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var installed: some View {
        if !app.accessibilityTrusted {
            accessibilityNotice
        }
        switch app.modelState {
        case .loading, .notLoaded:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading the voice model…")
            }
            Text("The first load takes a little longer while the Mac prepares the model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("The voice model failed to load: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete Model…") { app.confirmDeleteModel() }
        case .ready:
            if app.accessibilityTrusted {
                Label("Ready to read", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Select text in any app, then press ⌃⌥S or click the icon in the menu bar. Do the same again to stop.", systemImage: "text.cursor")
                Label("Right-click the menu bar icon for voices, speed and language.", systemImage: "menubar.arrow.up.rectangle")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Add Your Voice…") {
                    VoicesWindow.shared.show(app: app)
                    close()
                }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
