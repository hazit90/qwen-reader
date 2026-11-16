import AppKit
import ReaderCore

/// The menu bar icon. Clicking it reads the selection, or stops reading, like ⌃⌥S; right-clicking
/// or Control-clicking opens the menu. An AppKit status item because SwiftUI's MenuBarExtra
/// always opens its menu and can't tell the clicks apart.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let app: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    /// The items that change while the menu is open, and the timer that keeps them current.
    private var statusLine: NSMenuItem?
    private var transferView: TransferMenuView?
    private var refreshTimer: Timer?
    /// The stage of setup the open menu was built for; when it changes, the menu is rebuilt.
    private var builtStage: Int?

    init(app: AppModel) {
        self.app = app
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Qwen Reader")
            button.toolTip = "Click to read the selection (⌃⌥S). Right-click for options."
        }
        updateIcon()
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            app.reader.toggle()
        }
    }

    /// Attaches the menu only while it's open, so a normal click stays an action.
    private func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Redraws the icon whenever what it depends on changes, such as the waves animating while
    /// speech is being prepared or the ring filling as the model downloads.
    private func updateIcon() {
        withObservationTracking {
            let image: NSImage? = switch app.menuBarIcon {
            case .symbol(let name, let value):
                NSImage(systemSymbolName: name, variableValue: value, accessibilityDescription: "Qwen Reader")
            case .progress(let fraction):
                ProgressRing.image(fraction: fraction)
            }
            image?.isTemplate = true
            statusItem.button?.image = image
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    // MARK: - Menu

    /// Whether the model is missing, arriving or installed, which decides most of the menu's items.
    private var setupStage: Int {
        switch app.library.state {
        case .missing: 0
        case .downloading: 1
        case .importing: 2
        case .installed: 3
        }
    }

    /// Rebuilt each time it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// Menus don't redraw by themselves while open, so a timer keeps the status line and the
    /// download progress moving. It runs in the common modes because an open menu blocks the default one.
    func menuWillOpen(_ menu: NSMenu) {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOpenMenu() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshOpenMenu() {
        // Rebuilding closes any open submenu, so only do it when setup moves on, such as the
        // download finishing; smaller changes wait until the menu is next opened.
        if setupStage != builtStage {
            rebuild()
        } else {
            statusLine?.title = app.statusText
            transferView?.update(fraction: app.library.transferFraction, text: app.library.transferDescription)
        }
    }

    private func rebuild() {
        builtStage = setupStage
        transferView = nil
        menu.removeAllItems()

        let status = info(app.statusText)
        statusLine = status
        menu.addItem(status)
        if app.library.isBusy {
            let view = TransferMenuView()
            view.update(fraction: app.library.transferFraction, text: app.library.transferDescription)
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
            transferView = view
        }
        if let problem = app.hotKeyProblem {
            menu.addItem(info("Shortcut unavailable: \(problem)"))
        }

        menu.addItem(.separator())
        switch app.library.state {
        case .missing:
            let title = app.library.hasPartialDownload
                ? "Resume Download"
                : "Download Voice Model (\(VoiceModel.downloadSize.formatted(.byteCount(style: .file))))"
            menu.addItem(ActionMenuItem(title) { [app] in app.downloadModel() })
            menu.addItem(ActionMenuItem("Use a Model on Disk…") { [app] in app.chooseModelFolder() })
            menu.addItem(ActionMenuItem("Set Up Qwen Reader…") { [app] in SetupWindow.shared.show(app: app) })
        case .downloading:
            menu.addItem(ActionMenuItem("Pause Download") { [app] in app.library.cancel() })
        case .importing:
            menu.addItem(ActionMenuItem("Cancel") { [app] in app.library.cancel() })
        case .installed:
            addReadingItems()
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Show Progress Near Pointer", checked: app.showsProgressHUD) { [app] in
            app.showsProgressHUD.toggle()
        })
        menu.addItem(ActionMenuItem("Launch at Login", checked: app.loginItemEnabled) { [app] in
            app.setLaunchAtLogin(!app.loginItemEnabled)
        })
        if !app.accessibilityTrusted {
            menu.addItem(ActionMenuItem("Allow Accessibility Access…") { [app] in app.requestAccessibilityAccess() })
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("About Qwen Reader") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        let quit = ActionMenuItem("Quit Qwen Reader") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// The items for reading and its settings, shown once the model is installed.
    private func addReadingItems() {
        let read = ActionMenuItem("Read Selection") { [app] in app.reader.readSelection() }
        read.keyEquivalent = "s"
        read.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(read)
        menu.addItem(ActionMenuItem("Replay Last Reading", enabled: app.reader.lastText != nil) { [app] in
            app.reader.replayLast()
        })
        if app.reader.isActive {
            menu.addItem(ActionMenuItem(app.reader.isPaused ? "Resume" : "Pause") { [app] in app.reader.togglePause() })
            menu.addItem(ActionMenuItem("Stop") { [app] in app.reader.stop() })
        }

        menu.addItem(.separator())
        menu.addItem(submenu("Voice", items: voiceItems()))
        menu.addItem(submenu("Speed", items: speedItems()))
        menu.addItem(submenu("Language", items: languageItems()))
        menu.addItem(submenu("Model", items: modelItems()))
    }

    private func voiceItems() -> [NSMenuItem] {
        let voices: [(title: String, selection: VoiceSelection)] =
            [("Default Voice", .standard)] + app.voices.voices.map { ($0.name, .cloned($0.id)) }
        var items: [NSMenuItem] = voices.map { voice in
            ActionMenuItem(voice.title, checked: voice.selection == app.voiceSelection) { [app] in
                app.selectVoice(voice.selection)
            }
        }
        items.append(.separator())
        items.append(ActionMenuItem("Add or Manage Voices…") { [app] in VoicesWindow.shared.show(app: app) })
        return items
    }

    private func speedItems() -> [NSMenuItem] {
        AppModel.speeds.map { speed in
            let title = speed.formatted(.number.precision(.fractionLength(0 ... 2))) + "×"
            return ActionMenuItem(title, checked: speed == app.speed) { [app] in app.speed = speed }
        }
    }

    private func languageItems() -> [NSMenuItem] {
        let languages = [LanguageResolver.auto] + LanguageResolver.supported
        var items: [NSMenuItem] = languages.map { language in
            ActionMenuItem(LanguageResolver.displayName(language), checked: language == app.language) { [app] in
                app.language = language
            }
        }
        items.insert(.separator(), at: 1)
        return items
    }

    private func modelItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [info(modelDescription)]
        switch app.modelState {
        case .ready:
            items.append(ActionMenuItem("Unload from Memory", enabled: !app.reader.isActive) { [app] in app.unloadModel() })
        case .notLoaded, .failed:
            items.append(ActionMenuItem("Load into Memory") { [app] in app.loadModel() })
        case .loading:
            break
        }
        items.append(ActionMenuItem("Unload After 30 Minutes Idle", checked: app.unloadWhenIdle) { [app] in
            app.unloadWhenIdle.toggle()
        })

        items.append(.separator())
        items.append(info("\(app.library.sizeOnDisk.formatted(.byteCount(style: .file))) on disk"))
        items.append(ActionMenuItem("Show in Finder") { [app] in
            NSWorkspace.shared.activateFileViewerSelecting([app.library.modelDirectory])
        })
        items.append(ActionMenuItem("Delete Model…", enabled: app.modelState != .loading) { [app] in
            app.confirmDeleteModel()
        })
        return items
    }

    private var modelDescription: String {
        switch app.modelState {
        case .ready: "\(VoiceModel.displayName): loaded, using about \(VoiceModel.loadedMemory)"
        case .loading: "\(VoiceModel.displayName): loading…"
        case .notLoaded: "\(VoiceModel.displayName): not loaded"
        case .failed: "\(VoiceModel.displayName): failed to load"
        }
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        items.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// A menu item that runs a closure, with an optional checkmark.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

/// A progress bar with a line of detail under it, shown in the menu while the model downloads
/// or is copied.
private final class TransferMenuView: NSView {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 38))
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail

        for view in [bar, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            label.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(fraction: Double?, text: String?) {
        bar.doubleValue = fraction ?? 0
        label.stringValue = text ?? ""
    }
}

/// The menu bar icon while the model downloads: a ring that fills clockwise around a down arrow.
private enum ProgressRing {
    static func image(fraction: Double) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.75
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            NSColor.black.setStroke()
            let arc = NSBezierPath()
            let sweep = 360 * min(1, max(0.02, fraction))
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            arc.lineWidth = 1.75
            arc.lineCapStyle = .round
            arc.stroke()

            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: center.x, y: center.y + 3.25))
            arrow.line(to: NSPoint(x: center.x, y: center.y - 3.25))
            arrow.move(to: NSPoint(x: center.x - 2.5, y: center.y - 0.75))
            arrow.line(to: NSPoint(x: center.x, y: center.y - 3.25))
            arrow.line(to: NSPoint(x: center.x + 2.5, y: center.y - 0.75))
            arrow.lineWidth = 1.5
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
    }
}
