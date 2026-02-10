import Foundation
import os.log

class Logger {
    static let shared = Logger()
    private let osLog = OSLog(subsystem: "com.user.absentweaks", category: "Application")
    
    // Simple console logging for debugging if needed
    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] \(message)")
        // Also send to system log
        os_log("%{public}@", log: osLog, type: .default, message)
    }
}
