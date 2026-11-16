import AppKit
import SwiftUI

/// A small badge near the pointer, shown while speech is being prepared. It floats over every
/// app and Space, never takes focus, and lets clicks pass through.
@MainActor
final class ProgressHUD {
    private var panel: NSPanel?

    func show(app: AppModel) {
        let panel = panel ?? makePanel(app: app)
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(app: AppModel) -> NSPanel {
        let content = NSHostingView(rootView: ProgressHUDView(app: app))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    /// Just below and to the right of the pointer, where the selected text usually is, kept on screen.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: pointer.x + 16, y: pointer.y - size.height - 16)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}

private struct ProgressHUDView: View {
    let app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(app.progressMessage)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("⌃⌥S to stop")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Fixed width so the panel doesn't need resizing when the message changes.
        .frame(width: 280)
        .background(.regularMaterial, in: Capsule())
    }
}
