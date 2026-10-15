import Foundation
import os

/// Appends to ~/Library/Logs/Yap.log (and the unified log) so dictation problems can be diagnosed after the fact.
enum Log {
    private static let logger = Logger(subsystem: "app.yap.mac", category: "yap")
    private static let queue = DispatchQueue(label: "yap.log")
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Yap.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
