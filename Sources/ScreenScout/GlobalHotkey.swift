import Carbon
import Foundation

final class GlobalHotkey {
    private var handler: EventHandlerRef?
    private var reference: EventHotKeyRef?
    var onStop: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotkey>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { owner.onStop?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(code: UInt32, modifiers: UInt32) -> Bool {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        let identifier = EventHotKeyID(signature: 0x53435354, id: 1)
        return RegisterEventHotKey(code, modifiers, identifier, GetApplicationEventTarget(), 0, &reference) == noErr
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
