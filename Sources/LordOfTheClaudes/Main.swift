import AppKit
import LotcKit
import SwiftUI

/// `--screenshots <dir>` renders the panel with made-up sessions to PNG files and exits.
/// `--summarise <transcript.jsonl>` runs the observer's summariser once on a transcript and prints the digest.
/// Anything else runs the menu bar app.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--screenshots"), args.indices.contains(flag + 1) {
            MainActor.assumeIsolated { Screenshots.render(into: URL(fileURLWithPath: args[flag + 1])) }
        } else if let flag = args.firstIndex(of: "--summarise"), args.indices.contains(flag + 1) {
            summarise(URL(fileURLWithPath: args[flag + 1]))
        } else {
            MenuBarApp.main()
        }
    }

    /// For trying the summariser by hand: the digest it writes, and how long it took.
    private static func summarise(_ transcript: URL) -> Never {
        let event = StopEvent(sessionId: transcript.deletingPathExtension().lastPathComponent,
                              transcriptPath: transcript.path)
        Task.detached {
            guard let excerpt = Transcript.excerpt(of: event) else {
                print("Nothing to summarise in \(transcript.path).")
                exit(1)
            }
            print("Excerpt: \(excerpt.text.count) characters.")
            let started = Date()
            do {
                let reply = try await withDeadline(Observer.timeout) { try await ClaudeSummariser().summarise(excerpt.text) }
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                guard let digest = DigestReply.parse(reply, at: Date()) else {
                    print("No digest in the reply after \(seconds)s:\n\(reply)")
                    exit(1)
                }
                print("goal: \(digest.goal)\nstate: \(digest.state)\nblocked on: \(digest.blockedOn ?? "nothing")")
                print("Took \(seconds)s.")
                exit(0)
            } catch {
                print("Failed: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }
}
