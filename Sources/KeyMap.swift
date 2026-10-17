import AppKit

/// Rime modifier masks (X11 style).
enum RimeMask {
    static let shift: Int32 = 1 << 0
    static let lock: Int32 = 1 << 1
    static let control: Int32 = 1 << 2
    static let alt: Int32 = 1 << 3
    static let superKey: Int32 = 1 << 26
    static let release: Int32 = 1 << 30
}

/// Translates macOS key events into X11 keysyms understood by librime.
enum KeyMap {
    static func mask(_ flags: NSEvent.ModifierFlags) -> Int32 {
        var m: Int32 = 0
        if flags.contains(.shift) { m |= RimeMask.shift }
        if flags.contains(.capsLock) { m |= RimeMask.lock }
        if flags.contains(.control) { m |= RimeMask.control }
        if flags.contains(.option) { m |= RimeMask.alt }
        if flags.contains(.command) { m |= RimeMask.superKey }
        return m
    }

    static func keysym(for event: NSEvent) -> Int32? {
        switch event.keyCode {
        case 36: return 0xff0d   // Return
        case 76: return 0xff8d   // KP_Enter
        case 48: return 0xff09   // Tab
        case 49: return 0x20     // space
        case 51: return 0xff08   // BackSpace
        case 53: return 0xff1b   // Escape
        case 117: return 0xffff  // Delete
        case 123: return 0xff51  // Left
        case 124: return 0xff53  // Right
        case 125: return 0xff54  // Down
        case 126: return 0xff52  // Up
        case 115: return 0xff50  // Home
        case 119: return 0xff57  // End
        case 116: return 0xff55  // Page_Up
        case 121: return 0xff56  // Page_Down
        default: break
        }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let v = scalar.value
        if v >= 0x20 && v < 0x7f { return Int32(v) }
        if v >= 0xa0 { return Int32(0x0100_0000 + v) }
        return nil
    }

    /// Keysym and flag for a modifier key reported via `flagsChanged`.
    static func modifier(_ keyCode: UInt16) -> (keysym: Int32, flag: NSEvent.ModifierFlags)? {
        switch keyCode {
        case 56: return (0xffe1, .shift)     // Shift_L
        case 60: return (0xffe2, .shift)     // Shift_R
        case 59: return (0xffe3, .control)   // Control_L
        case 62: return (0xffe4, .control)   // Control_R
        case 58: return (0xffe9, .option)    // Alt_L
        case 61: return (0xffea, .option)    // Alt_R
        case 55: return (0xffeb, .command)   // Super_L
        case 54: return (0xffec, .command)   // Super_R
        case 57: return (0xffe5, .capsLock)  // Caps_Lock
        default: return nil
        }
    }
}
