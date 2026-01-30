import Cocoa

protocol MouseTrackerDelegate: AnyObject {
    func mouseDidMove(to point: CGPoint)
}

class MouseTracker {
    weak var delegate: MouseTrackerDelegate?
    private var monitor: Any?
    
    init() {
        startTracking()
    }
    
    deinit {
        stopTracking()
    }
    
    private func startTracking() {
        // Global monitor for when the app is in the background (normal state for this utility)
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.notifyLocation()
        }
        
        // Also track local events just in case
        NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.notifyLocation()
            return event
        }
    }
    
    private func stopTracking() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
    
    private func notifyLocation() {
        // NSEvent.mouseLocation returns screen coordinates (bottom-left origin).
        // CoreGraphics/NSWindow usually expects bottom-left, but we need to match standard expectations.
        // Let's pass the raw NSEvent.mouseLocation and let the controller handle coordinate spaces.
        let location = NSEvent.mouseLocation
        delegate?.mouseDidMove(to: location)
    }
}
