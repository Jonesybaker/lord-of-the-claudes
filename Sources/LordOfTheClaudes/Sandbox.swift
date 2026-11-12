import Foundation

/// `LOTC_SANDBOX=1` runs a second copy of the app beside the installed one, to try out `lotc`:
/// no global hotkey and no state.json, so the two never fight. Give it its own `LOTC_SOCKET` too.
enum Sandbox {
    static let isOn = ProcessInfo.processInfo.environment["LOTC_SANDBOX"] == "1"
}
