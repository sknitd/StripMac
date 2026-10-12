import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (no Input Monitoring permission needed).
final class Hotkeys: ObservableObject {
    static let shared = Hotkeys()
    /// Names of bindings that could not be registered (usually taken by another app).
    @Published private(set) var failed: Set<String> = []
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    struct Binding { let key: Int; let mods: Int; let name: String; let action: () -> Void }

    func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if st == noErr { Hotkeys.shared.fire(hk.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    fileprivate func fire(_ id: UInt32) {
        if let a = actions[id] { DispatchQueue.main.async { a() } }
    }

    func register(_ b: Binding) {
        install()
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5354_5250), id: id) // 'STRP'
        let st = RegisterEventHotKey(UInt32(b.key), UInt32(b.mods), hkID, GetApplicationEventTarget(), 0, &ref)
        if st == noErr, let ref {
            refs.append(ref); actions[id] = b.action
            failed.remove(b.name)
        } else {
            NSLog("StripMac: could not register hotkey \"%@\" (error %ld)", b.name, Int(st))
            failed.insert(b.name)
        }
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll(); actions.removeAll(); failed.removeAll()
    }
}

enum DefaultBindings {
    static let ctrlOpt = controlKey | optionKey
    static let ctrlOptShift = controlKey | optionKey | shiftKey

    static func all(engine e: StripEngine, toggle: @escaping () -> Void) -> [Hotkeys.Binding] {
        // Strip commands do nothing while tiling is stopped; only start/stop always works.
        func cmd(_ f: @escaping () -> Void) -> () -> Void { { if e.enabled { f() } } }
        return [
            .init(key: kVK_LeftArrow, mods: ctrlOpt, name: "Focus left  ⌃⌥←", action: cmd(e.focusLeft)),
            .init(key: kVK_ANSI_H, mods: ctrlOpt, name: "Focus left  ⌃⌥H", action: cmd(e.focusLeft)),
            .init(key: kVK_RightArrow, mods: ctrlOpt, name: "Focus right  ⌃⌥→", action: cmd(e.focusRight)),
            .init(key: kVK_ANSI_L, mods: ctrlOpt, name: "Focus right  ⌃⌥L", action: cmd(e.focusRight)),
            .init(key: kVK_LeftArrow, mods: ctrlOptShift, name: "Move left  ⌃⌥⇧←", action: cmd(e.moveLeft)),
            .init(key: kVK_ANSI_H, mods: ctrlOptShift, name: "Move left  ⌃⌥⇧H", action: cmd(e.moveLeft)),
            .init(key: kVK_RightArrow, mods: ctrlOptShift, name: "Move right  ⌃⌥⇧→", action: cmd(e.moveRight)),
            .init(key: kVK_ANSI_L, mods: ctrlOptShift, name: "Move right  ⌃⌥⇧L", action: cmd(e.moveRight)),
            .init(key: kVK_Home, mods: ctrlOpt, name: "Focus first  ⌃⌥Home", action: cmd(e.focusFirst)),
            .init(key: kVK_End, mods: ctrlOpt, name: "Focus last  ⌃⌥End", action: cmd(e.focusLast)),
            .init(key: kVK_ANSI_R, mods: ctrlOpt, name: "Cycle preset width  ⌃⌥R", action: cmd(e.cycleWidth)),
            .init(key: kVK_ANSI_Minus, mods: ctrlOpt, name: "Narrower  ⌃⌥-", action: cmd({ e.nudgeWidth(-0.1) })),
            .init(key: kVK_ANSI_Equal, mods: ctrlOpt, name: "Wider  ⌃⌥=", action: cmd({ e.nudgeWidth(0.1) })),
            .init(key: kVK_ANSI_F, mods: ctrlOpt, name: "Full width  ⌃⌥F", action: cmd(e.fullWidth)),
            .init(key: kVK_ANSI_C, mods: ctrlOpt, name: "Center column  ⌃⌥C", action: cmd(e.center)),
            .init(key: kVK_ANSI_0, mods: ctrlOpt, name: "Equalize widths  ⌃⌥0", action: cmd(e.equalize)),
            .init(key: kVK_ANSI_Q, mods: ctrlOpt, name: "Start/stop tiling  ⌃⌥Q", action: toggle),
        ]
    }
}
