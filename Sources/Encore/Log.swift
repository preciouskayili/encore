import Foundation

/// A small plain-text log at ~/Library/Logs/Encore.log. The lock screen can't
/// be inspected while it's up, so this is how to see what happened there.
enum Log {
    private static let url = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Encore.log")
    private static let queue = DispatchQueue(label: "encore.log")
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    static func write(_ message: String) {
        queue.async {
            let line = Data("\(stamp.string(from: Date())) \(message)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }
}
