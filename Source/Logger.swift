import Foundation

class Logger {
    static let shared = Logger()
    private let logFile: URL
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFile = docs.appendingPathComponent("cursor_overlay_log.txt")
        // Create/Truncate
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
    }
    
    func log(_ message: String) {
        let entry = "\(Date()): \(message)\n"
        if let data = entry.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? entry.write(to: logFile, atomically: true, encoding: .utf8)
            }
        }
    }
}
