import Carbon.HIToolbox

/// System-wide shortcuts via Carbon's hot key API (no accessibility permission needed). One event
/// handler dispatches all registered shortcuts by id.
@MainActor
final class GlobalHotKey {
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private static var nextId: UInt32 = 1
    private static let signature = OSType(0x4153_4350) // "ASCP"

    private var hotKey: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: Int = kVK_ANSI_A, modifiers: Int = cmdKey | shiftKey, action: @escaping @MainActor () -> Void) {
        guard Self.installHandler() else { return nil }
        id = Self.nextId
        Self.nextId += 1
        Self.actions[id] = action
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: Self.signature, id: id),
                                  GetApplicationEventTarget(), 0, &hotKey) == noErr
        else {
            Self.actions[id] = nil
            return nil
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        Self.actions[id] = nil
    }

    private static func installHandler() -> Bool {
        guard handler == nil else { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            MainActor.assumeIsolated { GlobalHotKey.actions[hotKeyID.id]?() }
            return noErr
        }
        return InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, nil, &handler) == noErr
    }
}
