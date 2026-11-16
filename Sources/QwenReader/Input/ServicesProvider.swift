import AppKit

/// Handles Services › Read Aloud with Qwen Reader, declared under NSServices in Info.plist.
/// The Services menu passes the selection directly, so this path needs no Accessibility access.
final class ServicesProvider: NSObject {
    private let onText: @MainActor (String) -> Void

    init(onText: @escaping @MainActor (String) -> Void) {
        self.onText = onText
    }

    @objc func readAloud(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "No text was selected." as NSString
            return
        }
        MainActor.assumeIsolated { onText(text) }
    }
}
