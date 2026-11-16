import AppKit
import SwiftUI

@main
struct QwenReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon is an AppKit status item (see StatusItemController). SwiftUI needs at
        // least one scene, and keeping its app lifecycle provides the standard Edit shortcuts for
        // the Voices window's text fields.
        Settings { EmptyView() }
            .commandsRemoved()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(app: app)
        app.start()
    }
}
