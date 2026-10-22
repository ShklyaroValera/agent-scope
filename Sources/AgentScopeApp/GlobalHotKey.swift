import Carbon.HIToolbox

/// A system-wide shortcut via Carbon's hot key API (no accessibility permission needed).
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init?(keyCode: Int = kVK_ANSI_A, modifiers: Int = cmdKey | shiftKey, action: @escaping @MainActor () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr,
              RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4153_4350), id: 1),
                                  GetApplicationEventTarget(), 0, &hotKey) == noErr
        else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
