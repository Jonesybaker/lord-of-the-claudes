import Foundation

/// Scratch sessions in a temporary directory are not worth keeping once closed.
enum Throwaway {
    static func isTemporary(_ cwd: String, tmpdir: String = NSTemporaryDirectory()) -> Bool {
        let roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", tmpdir]
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
