import AppKit
import SwiftUI

/// `--screenshots <dir>` renders the panel with made-up sessions to PNG files and exits.
/// Anything else runs the menu bar app.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--screenshots"), args.indices.contains(flag + 1) {
            MainActor.assumeIsolated { Screenshots.render(into: URL(fileURLWithPath: args[flag + 1])) }
        } else {
            MenuBarApp.main()
        }
    }
}
