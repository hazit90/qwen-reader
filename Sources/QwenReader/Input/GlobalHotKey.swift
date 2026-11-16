import Carbon.HIToolbox

enum HotKeyError: LocalizedError {
    case installFailed(OSStatus)
    case registerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .installFailed(let status):
            "Couldn't listen for the shortcut (error \(status))."
        case .registerFailed(let status) where status == eventHotKeyExistsErr:
            "⌃⌥S is already used by another app."
        case .registerFailed(let status):
            "Couldn't register the shortcut (error \(status))."
        }
    }
}

/// A system-wide keyboard shortcut. Uses the Carbon hot key API, which works in any app
/// and needs no permissions.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Control+Option+S. Apps rarely use Control+Option, and unlike Option+letter it types no character.
    static let controlOptionS = (keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey)

    init(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) throws {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard status == noErr else { throw HotKeyError.installFailed(status) }

        let id = EventHotKeyID(signature: OSType(0x5152_4452), id: 1) // "QRDR"
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registered == noErr else {
            RemoveEventHandler(handlerRef)
            throw HotKeyError.registerFailed(registered)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
