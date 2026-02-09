import Cocoa

typealias SwipeAction = (SwipeDirection) -> Void

enum SwipeDirection {
    case up
    case down
    case left
    case right
}

class SwipeTracker {
    private var monitor: Any?
    private var scrollMonitor: Any?
    private var lastSwipeTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 1.0 // Increased to 1.0s to prevent double triggers on inertia
    
    var onSwipe: SwipeAction?
    
    init() {
        start()
    }
    
    deinit {
        stop()
    }
    
    func start() {
        // 1. Listen for Native Swipe Events
        // Note: This requires the user to 'Enable' standard swipe gestures or unbind system ones if conflicts rise.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .swipe) { [weak self] event in
            self?.handleSwipe(event)
        }
        
        // 2. Listen for Scroll Wheel (common for trackpad gestures not caught by .swipe)
        // High magnitude scroll events often map to swipes.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
        }
    }
    
    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let sm = scrollMonitor { NSEvent.removeMonitor(sm); scrollMonitor = nil }
    }
    
    private func handleSwipe(_ event: NSEvent) {
        guard Date().timeIntervalSince1970 - lastSwipeTime > debounceInterval else { return }
        
        // Horizontal Swipes
        if event.deltaX > 0 {
            trigger(.left) // Fingers moved left (content moves right)
        } else if event.deltaX < 0 {
            trigger(.right) // Fingers moved right
        }
        
        // Vertical Swipes (Optional - keeping for completeness if needed later)
        if event.deltaY > 0 {
            trigger(.up)
        } else if event.deltaY < 0 {
            trigger(.down)
        }
    }
    
    private func handleScroll(_ event: NSEvent) {
        // Debug Log
        // Logger.shared.log("Scroll Event: Phase:\(event.phase.rawValue) Modifiers:\(event.modifierFlags.rawValue) DeltaY:\(event.scrollingDeltaY)")
        
        guard Date().timeIntervalSince1970 - lastSwipeTime > debounceInterval else { return }
        
        // REQUIREMENT: Command Key must be held down
        if !event.modifierFlags.contains(.command) { return }
        
        let now = Date().timeIntervalSince1970
        
        // Strict Debounce: Ignore EVERYTHING if within debounce window
        if now - lastSwipeTime < debounceInterval {
            // Logger.shared.log("[SwipeTracker] Ignored due to debounce")
            return
        }
        
        // Logger.shared.log("[SwipeTracker] Cmd+Scroll Detected. Phase: \(event.phase.rawValue), DeltaY: \(event.scrollingDeltaY)")
        
        // Phase logic... we accept .began(1), .changed(2), or .none(0),
        // BUT relying on strict debounce is better because mice flood with 0.
        
        // Sensitivity threshold (Lowered slightly as Cmd+Scroll is intentional)
        let threshold: CGFloat = 0.5
        
        var triggered = false
        
        // Vertical Scroll (Y axis) Mapping for Spaces
        if event.scrollingDeltaY > threshold {
             // Logger.shared.log("[SwipeTracker] Triggering UP/RIGHT (Prev Space)")
             trigger(.right) 
             triggered = true
        } else if event.scrollingDeltaY < -threshold {
             // Logger.shared.log("[SwipeTracker] Triggering DOWN/LEFT (Next Space)")
             trigger(.left) 
             triggered = true
        }
        
        // Only check horizontal if not already triggered vertical
        if !triggered {
            if event.scrollingDeltaX > threshold {
                 trigger(.left)
            } else if event.scrollingDeltaX < -threshold {
                 trigger(.right)
            }
        }
    }
    
    private func trigger(_ direction: SwipeDirection) {
        lastSwipeTime = Date().timeIntervalSince1970
        onSwipe?(direction)
    }
}
