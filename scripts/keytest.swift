// keytest <pid> [group or key ...] (build: swiftc -O scripts/keytest.swift -o keytest; KEYTEST_HOLD_MS=<ms> holds each key): brings the process to the front and, only while it is frontmost,
// presses every key of a Mac keyboard once through the HID event tap (what a physical
// keyboard does). Modifiers are sent as flagsChanged with device-specific flag bits, which
// is what Wine's Mac driver reads. Prints one line per key: "<name> <mac keycode>".
import AppKit

struct Key { let name: String; let code: UInt16; let modFlags: UInt64 }  // modFlags 0 = normal key

// NX device masks + generic masks (IOKit/hidsystem/IOLLEvent.h)
let shiftG: UInt64 = 0x20000, ctrlG: UInt64 = 0x40000, altG: UInt64 = 0x80000, cmdG: UInt64 = 0x100000
let mods: [Key] = [
    Key(name: "LShift", code: 0x38, modFlags: shiftG | 0x2),
    Key(name: "RShift", code: 0x3C, modFlags: shiftG | 0x4),
    Key(name: "LCtrl", code: 0x3B, modFlags: ctrlG | 0x1),
    Key(name: "RCtrl", code: 0x3E, modFlags: ctrlG | 0x2000),
    Key(name: "LOption", code: 0x3A, modFlags: altG | 0x20),
    Key(name: "ROption", code: 0x3D, modFlags: altG | 0x40),
    Key(name: "LCommand", code: 0x37, modFlags: cmdG | 0x8),
    Key(name: "RCommand", code: 0x36, modFlags: cmdG | 0x10),
]
let letters: [(String, UInt16)] = [("A",0x00),("S",0x01),("D",0x02),("F",0x03),("H",0x04),("G",0x05),("Z",0x06),("X",0x07),
    ("C",0x08),("V",0x09),("B",0x0B),("Q",0x0C),("W",0x0D),("E",0x0E),("R",0x0F),("Y",0x10),("T",0x11),("O",0x1F),
    ("U",0x20),("I",0x22),("P",0x23),("L",0x25),("J",0x26),("K",0x28),("N",0x2D),("M",0x2E)]
let digits: [(String, UInt16)] = [("1",0x12),("2",0x13),("3",0x14),("4",0x15),("5",0x17),("6",0x16),("7",0x1A),("8",0x1C),("9",0x19),("0",0x1D)]
let punct: [(String, UInt16)] = [("Minus",0x1B),("Equal",0x18),("LBracket",0x21),("RBracket",0x1E),("Backslash",0x2A),
    ("Semicolon",0x29),("Quote",0x27),("Comma",0x2B),("Period",0x2F),("Slash",0x2C),("Grave",0x32),("ISOSection",0x0A)]
let control: [(String, UInt16)] = [("Space",0x31),("Tab",0x30),("Return",0x24),("Backspace",0x33),("ForwardDelete",0x75),
    ("Home",0x73),("End",0x77),("PageUp",0x74),("PageDown",0x79),("Left",0x7B),("Right",0x7C),("Down",0x7D),("Up",0x7E)]
let fkeys: [(String, UInt16)] = [("F1",0x7A),("F2",0x78),("F3",0x63),("F4",0x76),("F5",0x60),("F6",0x61),("F7",0x62),
    ("F8",0x64),("F9",0x65),("F10",0x6D),("F11",0x67),("F12",0x6F)]
let extra: [(String, UInt16)] = [("Escape",0x35)]
let keypad: [(String, UInt16)] = [("KP0",0x52),("KP1",0x53),("KP2",0x54),("KP3",0x55),("KP4",0x56),("KP5",0x57),("KP6",0x58),
    ("KP7",0x59),("KP8",0x5B),("KP9",0x5C),("KPDecimal",0x41),("KPPlus",0x45),("KPMinus",0x4E),("KPMultiply",0x43),
    ("KPDivide",0x4B),("KPEnter",0x4C),("KPEquals",0x51),("KPClear",0x47)]

let args = CommandLine.arguments
guard args.count >= 2, let pid = pid_t(args[1]) else { print("usage: keytest <pid> [all|mods|letters|digits|punct|control|fkeys|keypad|<name>...]"); exit(2) }
var groups = Array(args.dropFirst(2)); if groups.isEmpty { groups = ["all"] }

func plain(_ l: [(String, UInt16)]) -> [Key] { l.map { Key(name: $0.0, code: $0.1, modFlags: 0) } }
let table: [String: [Key]] = ["mods": mods, "letters": plain(letters), "digits": plain(digits), "punct": plain(punct),
                              "control": plain(control), "fkeys": plain(fkeys), "keypad": plain(keypad), "extra": plain(extra)]
let order = ["letters", "digits", "punct", "control", "mods", "fkeys", "keypad"]
var keys: [Key] = []
for g in groups {
    if g == "all" { for o in order { keys += table[o]! } }
    else if let t = table[g] { keys += t }
    else if let k = table.values.joined().first(where: { $0.name.lowercased() == g.lowercased() }) { keys.append(k) }
    else { print("unknown key or group \(g)"); exit(2) }
}

guard let app = NSRunningApplication(processIdentifier: pid) else { print("no such process"); exit(1) }
app.activate(options: [.activateIgnoringOtherApps])
usleep(800_000)
func frontOK() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
guard frontOK() else { print("not frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"); exit(3) }

let src = CGEventSource(stateID: .hidSystemState)
let holdUs: UInt32 = UInt32(ProcessInfo.processInfo.environment["KEYTEST_HOLD_MS"].flatMap { UInt32($0) } ?? 140) * 1000, gapUs: UInt32 = 320_000
for k in keys {
    guard frontOK() else { print("lost front before \(k.name); stopping"); exit(4) }
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: false) else { continue }
    if k.modFlags != 0 {
        down.type = .flagsChanged; down.flags = CGEventFlags(rawValue: k.modFlags | 0x100)
        up.type = .flagsChanged; up.flags = CGEventFlags(rawValue: 0x100)
    } else {
        down.flags = CGEventFlags(rawValue: 0x100); up.flags = CGEventFlags(rawValue: 0x100)
    }
    down.post(tap: .cghidEventTap); usleep(holdUs); up.post(tap: .cghidEventTap); usleep(gapUs)
    print("\(k.name) \(k.code)")
    fflush(stdout)
}
