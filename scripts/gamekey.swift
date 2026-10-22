// gamekey <pid> <keycode>...: activates the process (NSRunningApplication) and, only if it
// then is the frontmost app, posts key down/up through the HID event tap (what a real
// keyboard does). 36 = Return, 49 = Space, 53 = Esc, 126/125 = up/down.
import AppKit
let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else { print("usage: gamekey <pid> <keycode>..."); exit(2) }
guard let app = NSRunningApplication(processIdentifier: pid) else { print("no such process"); exit(1) }
app.activate(options: [.activateIgnoringOtherApps])
usleep(700_000)
let front = NSWorkspace.shared.frontmostApplication
print("frontmost: \(front?.localizedName ?? "?") pid \(front?.processIdentifier ?? -1)")
guard front?.processIdentifier == pid else { print("game is not frontmost; not sending keys"); exit(3) }
let src = CGEventSource(stateID: .hidSystemState)
for k in args[2...] {
    guard let code = UInt16(k),
          let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false) else { continue }
    down.post(tap: .cghidEventTap); usleep(90_000); up.post(tap: .cghidEventTap); usleep(400_000)
    print("sent key \(code)")
}
