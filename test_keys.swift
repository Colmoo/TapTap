import CoreGraphics
import Foundation

let src = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: src, virtualKey: 0x04, keyDown: true) // 'H' key
down?.post(tap: .cghidEventTap)
let up = CGEvent(keyboardEventSource: src, virtualKey: 0x04, keyDown: false)
up?.post(tap: .cghidEventTap)

print("Key event posted.")
