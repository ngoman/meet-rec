import Carbon.HIToolbox
import Foundation
import MeetRecCore

private func hotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { HotkeyManager.shared.onPress?() }
    return noErr
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPress: (() -> Void)?
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    func register(_ hotkey: Hotkey) throws {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &type, nil, &handler)
            guard status == noErr else { throw MeetRecError("Не удалось установить обработчик хоткея (\(status))") }
        }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        let id = EventHotKeyID(signature: OSType(0x4D525243), id: 1)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else { throw MeetRecError("Не удалось зарегистрировать хоткей \(hotkey.display) (\(status))") }
    }
}
