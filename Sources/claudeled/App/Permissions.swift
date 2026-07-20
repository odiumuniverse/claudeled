// Permissions.swift -- Input Monitoring, the one grant claudeled cannot work without.
//
// macOS gates IOHIDDeviceOpen and element enumeration on keyboards behind Input
// Monitoring, whether you intend to read keystrokes or only write to an LED. Without
// it the caps LED element is invisible, which looks exactly like a keyboard that has
// no LED at all -- so check explicitly and say so, rather than lying in the menu.
//
// The CLI usually works without it because it inherits the terminal's grant. The app
// is its own subject and needs its own.

import AppKit
import IOKit.hid

enum InputMonitoring {
    static var granted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt, once per app identity.
    static func request() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static var description: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown (never asked)"
        }
    }

    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
