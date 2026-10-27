import Foundation

public struct Hotkey: Equatable {
    public static let command: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46,
    ]

    public let modifiers: UInt32
    public let keyCode: UInt32
    public let key: String

    public init?(_ spec: String) {
        var mods: UInt32 = 0
        var key: String?
        for raw in spec.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "ctrl", "control": mods |= Hotkey.control
            case "opt", "option", "alt": mods |= Hotkey.option
            case "cmd", "command": mods |= Hotkey.command
            case "shift": mods |= Hotkey.shift
            default:
                guard key == nil, Hotkey.keyCodes[part] != nil else { return nil }
                key = part
            }
        }
        guard mods & (Hotkey.control | Hotkey.option | Hotkey.command) != 0, let key, let code = Hotkey.keyCodes[key] else { return nil }
        modifiers = mods
        keyCode = code
        self.key = key
    }

    public var display: String {
        var out = ""
        if modifiers & Hotkey.control != 0 { out += "⌃" }
        if modifiers & Hotkey.option != 0 { out += "⌥" }
        if modifiers & Hotkey.shift != 0 { out += "⇧" }
        if modifiers & Hotkey.command != 0 { out += "⌘" }
        return out + key.uppercased()
    }
}
