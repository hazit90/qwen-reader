import AppKit
import os
import ReaderCore

/// Which voice the user has chosen in the menu.
enum VoiceSelection: Hashable {
    /// The model's own voice.
    case standard
    /// A saved cloned voice.
    case cloned(UUID)

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("standard", 1): self = .standard
        case ("cloned", 2):
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .cloned(id)
        default: return nil
        }
    }

    var storageValue: String {
        switch self {
        case .standard: "standard"
        case .cloned(let id): "cloned:\(id.uuidString)"
        }
    }
}

enum AppModelError: LocalizedError {
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: "The voice model isn't installed yet."
        }
    }
}

/// What the menu bar icon shows.
enum MenuBarIcon: Equatable {
    /// An SF Symbol, with a variable value from 0 to 1 for symbols that animate.
    case symbol(String, value: Double = 1)
    /// A ring filling up as the model downloads or is copied, from 0 to 1.
    case progress(Double)
}

/// App-wide state and settings, shared by the menu, the hotkey and the Services menu.
@MainActor
@Observable
final class AppModel {
    /// Whether the installed model is in memory.
    enum ModelState: Equatable {
        case notLoaded
        case loading
        case ready
        case failed(String)
    }

    private enum Keys {
        static let voice = "currentVoice"
        static let speed = "speed"
        static let language = "language"
        static let unloadWhenIdle = "unloadWhenIdle"
        static let showsProgressHUD = "showsProgressHUD"
        static let didSetUpLoginItem = "didSetUpLoginItem"
    }

    /// Fast reads start speaking within this time, so the badge would only flicker.
    private static let progressHUDDelay: Duration = .milliseconds(300)

    static let speeds: [Double] = [0.8, 1.0, 1.25, 1.5]
    static let idleUnloadDelay: TimeInterval = 30 * 60

    @ObservationIgnored let engine = TTSEngine()
    @ObservationIgnored let player = AudioPlayer()
    let voices = VoiceStore()
    let reader = ReadingController()
    let library = ModelLibrary()

    private(set) var modelState: ModelState = .notLoaded
    private(set) var accessibilityTrusted = SelectionReader.isTrusted
    private(set) var loginItemEnabled = LoginItem.isEnabled
    private(set) var hotKeyProblem: String?
    /// A short-lived message shown at the top of the menu.
    private(set) var flashMessage: String?

    /// The chosen voice. Change it with `selectVoice(_:)`.
    private(set) var voiceSelection: VoiceSelection

    var speed: Double {
        didSet {
            defaults.set(speed, forKey: Keys.speed)
            player.rate = Float(speed)
        }
    }

    var language: String {
        didSet {
            defaults.set(language, forKey: Keys.language)
            preloadSelectedVoice()
        }
    }

    var unloadWhenIdle: Bool {
        didSet { defaults.set(unloadWhenIdle, forKey: Keys.unloadWhenIdle) }
    }

    /// Whether to show the floating badge near the pointer while speech is being prepared.
    var showsProgressHUD: Bool {
        didSet { defaults.set(showsProgressHUD, forKey: Keys.showsProgressHUD) }
    }

    private(set) var preparingFrame = 0

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: "io.github.hazit90.QwenReader", category: "App")
    /// The newest load or unload. Each waits for the one before it, so they never overlap.
    @ObservationIgnored private var loadTask: Task<Void, Error>?
    /// Whether `loadTask` is a load, rather than an unload.
    @ObservationIgnored private var isLoadQueued = false
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var servicesProvider: ServicesProvider?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private let progressHUD = ProgressHUD()
    @ObservationIgnored private var progressHUDTask: Task<Void, Never>?
    @ObservationIgnored private var preparingAnimation: Timer?

    init() {
        voiceSelection = defaults.string(forKey: Keys.voice).flatMap(VoiceSelection.init(storageValue:)) ?? .standard
        speed = defaults.object(forKey: Keys.speed) as? Double ?? 1.0
        language = defaults.string(forKey: Keys.language) ?? LanguageResolver.auto
        unloadWhenIdle = defaults.bool(forKey: Keys.unloadWhenIdle)
        showsProgressHUD = defaults.object(forKey: Keys.showsProgressHUD) as? Bool ?? true

        if case .cloned(let id) = voiceSelection, voices.voice(id: id) == nil {
            voiceSelection = .standard
        }
        player.rate = Float(speed)
        reader.attach(to: self)
        library.onInstalled = { [weak self] in self?.preloadSelectedVoice() }
    }

    // MARK: - Startup

    func start() {
        do {
            let shortcut = GlobalHotKey.controlOptionS
            hotKey = try GlobalHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                self?.reader.toggle()
            }
        } catch {
            hotKeyProblem = error.localizedDescription
            log.error("Hotkey registration failed: \(error.localizedDescription, privacy: .public)")
        }

        let provider = ServicesProvider { [weak self] text in self?.reader.read(text) }
        NSApp.servicesProvider = provider
        servicesProvider = provider
        NSUpdateDynamicServices()

        // The app is meant to run from login, so turn that on the first time it runs.
        if !defaults.bool(forKey: Keys.didSetUpLoginItem) {
            defaults.set(true, forKey: Keys.didSetUpLoginItem)
            setLaunchAtLogin(true)
        }

        timers = [
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.unloadIfIdle() }
            },
        ]

        if library.isInstalled {
            if !accessibilityTrusted {
                // Reading can't work without it, so say so up front rather than failing quietly later.
                SelectionReader.requestAccess()
                SetupWindow.shared.show(app: self)
            }
            preloadSelectedVoice()
        } else if !library.adoptExistingDownload() {
            // First launch: the setup window offers the download, then asks for Accessibility.
            SetupWindow.shared.show(app: self)
        }
    }

    // MARK: - Model on disk

    func downloadModel() {
        library.download()
    }

    /// Asks for the folder holding a model that is already on disk, and installs a copy of it.
    func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.title = "Use a Model on Disk"
        panel.message = "Choose the folder that holds the Qwen3-TTS Base model, or a folder that contains it, such as Downloads."
        panel.prompt = "Use Model"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate()
        if panel.runModal() == .OK, let folder = panel.url {
            library.importModel(from: folder)
        }
    }

    /// Asks first, then removes the model from memory and from disk.
    func confirmDeleteModel() {
        let alert = NSAlert()
        alert.messageText = "Delete the voice model?"
        alert.informativeText = "This frees \(library.sizeOnDisk.formatted(.byteCount(style: .file))). Qwen Reader can't read aloud until you download the model again or choose one on disk. Your voices are kept."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        reader.stop()
        queueUnload()
        do {
            try library.delete()
        } catch {
            report(error)
        }
    }

    /// Opens the setup window when there is no model to read with. Returns whether there is one.
    func requireModel() -> Bool {
        if library.isInstalled { return true }
        if library.isBusy {
            flash("The voice model isn't ready yet.")
        }
        SetupWindow.shared.show(app: self)
        return false
    }

    // MARK: - Model in memory

    /// Loads the model if it isn't loaded. Loads and unloads run one after another, so if the
    /// model is being unloaded this waits for that and then loads it again.
    func ensureModelLoaded() async throws {
        guard library.isInstalled else { throw AppModelError.modelNotInstalled }
        while modelState != .ready {
            if !isLoadQueued {
                let previous = loadTask
                let engine = engine
                let directory = library.modelDirectory
                isLoadQueued = true
                modelState = .loading
                loadTask = Task {
                    _ = await previous?.result
                    try await engine.load(from: directory)
                }
            }
            guard let task = loadTask else { return }
            do {
                try await task.value
                if loadTask == task {
                    loadTask = nil
                    isLoadQueued = false
                    modelState = .ready
                }
            } catch {
                if loadTask == task {
                    loadTask = nil
                    isLoadQueued = false
                    modelState = .failed(error.localizedDescription)
                }
                throw error
            }
        }
    }

    func loadModel() {
        preloadSelectedVoice()
    }

    func unloadModel() {
        guard modelState == .ready, !reader.isActive else { return }
        queueUnload()
    }

    /// Queues the unload behind any load, so a later load can't be undone by this unload.
    private func queueUnload() {
        let previous = loadTask
        let engine = engine
        loadTask = Task {
            _ = await previous?.result
            await engine.unload()
        }
        isLoadQueued = false
        modelState = .notLoaded
    }

    func noteActivity() {
        lastActivity = Date()
    }

    private func unloadIfIdle() {
        guard unloadWhenIdle, !reader.isActive,
              Date().timeIntervalSince(lastActivity) > Self.idleUnloadDelay
        else { return }
        unloadModel()
    }

    // MARK: - Voices

    func selectVoice(_ selection: VoiceSelection) {
        voiceSelection = selection
        defaults.set(selection.storageValue, forKey: Keys.voice)
        preloadSelectedVoice()
    }

    var selectedSpeechVoice: SpeechVoice {
        switch voiceSelection {
        case .standard:
            return .standard
        case .cloned(let id):
            guard let voice = voices.voice(id: id) else { return .standard }
            return .cloned(id: voice.id, audioURL: voices.audioURL(for: voice), transcript: voice.transcript)
        }
    }

    func deleteVoice(_ voice: VoiceProfile) {
        if voiceSelection == .cloned(voice.id) {
            selectVoice(.standard)
        }
        do {
            try voices.delete(voice)
        } catch {
            report(error)
        }
    }

    /// Loads the model, and prepares a cloned voice, in the background so the next read starts
    /// quickly. Waits for the current read, which calls this again when done.
    func preloadSelectedVoice() {
        guard library.isInstalled, !reader.isActive else { return }
        let voice = selectedSpeechVoice
        let language = language == LanguageResolver.auto ? LanguageResolver.preferred : language
        let engine = engine
        Task {
            do {
                try await ensureModelLoaded()
                try await engine.prepare(voice, language: language)
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Login item and permissions

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            report(error)
        }
        loginItemEnabled = LoginItem.isEnabled
    }

    func requestAccessibilityAccess() {
        SelectionReader.requestAccess()
        SelectionReader.openAccessibilitySettings()
    }

    private func refreshPermissions() {
        accessibilityTrusted = SelectionReader.isTrusted
        loginItemEnabled = LoginItem.isEnabled
    }

    // MARK: - Status

    /// Shows progress from the moment a read starts until its first audio: the menu bar icon
    /// animates, and after a short delay the badge appears near the pointer.
    func readingPhaseDidChange() {
        progressHUDTask?.cancel()
        guard reader.phase == .preparing else {
            preparingAnimation?.invalidate()
            preparingAnimation = nil
            progressHUD.hide()
            return
        }

        if preparingAnimation == nil {
            preparingFrame = 0
            preparingAnimation = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.preparingFrame += 1 }
            }
        }
        guard showsProgressHUD else { return }
        progressHUDTask = Task {
            try? await Task.sleep(for: Self.progressHUDDelay)
            guard !Task.isCancelled, reader.phase == .preparing else { return }
            progressHUD.show(app: self)
        }
    }

    /// What the progress badge says while speech is being prepared.
    var progressMessage: String {
        modelState == .loading ? "Loading the voice model…" : "Preparing speech…"
    }

    func flash(_ message: String) {
        flashMessage = message
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { flashMessage = nil }
        }
    }

    func report(_ error: Error) {
        log.error("\(error.localizedDescription, privacy: .public)")
        flash(error.localizedDescription)
    }

    var statusText: String {
        if let flashMessage { return flashMessage }
        switch library.state {
        case .downloading(let progress):
            return "Downloading the voice model… \(progress.transfer.fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .importing:
            return "Copying the voice model…"
        case .missing:
            if let problem = library.problem { return problem }
            return library.hasPartialDownload ? "The voice model download is paused." : "Qwen Reader needs its voice model."
        case .installed:
            break
        }
        if case .failed(let message) = modelState { return "The voice model failed to load: \(message)" }
        switch reader.phase {
        case .speaking: return reader.isPaused ? "Paused" : "Speaking…"
        case .preparing: return modelState == .loading ? "Loading the voice model…" : "Preparing…"
        case .idle: break
        }
        switch modelState {
        case .loading: return "Loading the voice model…"
        case .notLoaded: return "Model unloaded. It reloads on the next read."
        case .ready, .failed: return "Ready. Select text and press ⌃⌥S."
        }
    }

    var menuBarIcon: MenuBarIcon {
        switch reader.phase {
        case .speaking: return .symbol(reader.isPaused ? "pause.circle" : "waveform.circle.fill")
        // The speaker's waves light up one at a time. One symbol keeps the menu bar item's
        // width steady, unlike cycling through speaker.wave.1/2/3.
        case .preparing: return .symbol("speaker.wave.3", value: Double(preparingFrame % 4) / 3)
        case .idle: break
        }
        if let fraction = library.transferFraction {
            return .progress(fraction)
        }
        if !library.isInstalled {
            return .symbol("arrow.down.circle")
        }
        switch modelState {
        case .loading: return .symbol("hourglass")
        case .failed: return .symbol("exclamationmark.triangle")
        case .ready, .notLoaded: return .symbol("waveform")
        }
    }
}
