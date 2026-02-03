import Foundation
import os.log

class Logger {
    static let shared = Logger()
    private let osLog = OSLog(subsystem: "com.user.cursoroverlay", category: "Application")
    
    // Simple console logging for debugging if needed
    func log(_ message: String) {
        #if DEBUG
        os_log("%{public}@", log: osLog, type: .default, message)
        #endif
    }
}
