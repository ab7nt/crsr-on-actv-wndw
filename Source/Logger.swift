import Foundation
import os.log

class Logger {
    static let shared = Logger()
    private let osLog = OSLog(subsystem: "com.user.absentweaks", category: "Application")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()
    
    // Simple console logging for debugging if needed
    func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        print("[\(timestamp)] \(message)")
        // Also send to system log
        os_log("%{public}@", log: osLog, type: .default, message)
    }
}
