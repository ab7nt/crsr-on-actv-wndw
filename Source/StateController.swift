import Cocoa

class StateController: MouseTrackerDelegate {
    
    private let mouseTracker: MouseTracker
    private let windowDetector: WindowDetector
    private let overlay: OverlayIndicator
    
    // Throttling to prevent excessive Accessibility API calls (expensive)
    private var lastCheckTime: TimeInterval = 0
    private let checkInterval: TimeInterval = 0.05 // ~20 checks per second max
    
    private var isEnabled = true
    private var clickMonitor: Any?
    
    init() {
        Logger.shared.log("App Started. Check Permissions: \(WindowDetector.isAccessibilityTrusted())")
        self.mouseTracker = MouseTracker()
        self.windowDetector = WindowDetector()
        self.overlay = OverlayIndicator()
        
        self.mouseTracker.delegate = self
        
        setupMenu()
        setupClickMonitoring()
    }
    
    deinit {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func setupMenu() {
        // Simple polling for permissions if not trusted
        if !WindowDetector.isAccessibilityTrusted() {
            WindowDetector.requestPermissions()
        }
    }
    
    private func setupClickMonitoring() {
        // Monitor Left Clicks globally to provide instant feedback
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.handleGlobalClick()
        }
        
        NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleGlobalClick()
            return event
        }
    }
    
    private func handleGlobalClick() {
        guard isEnabled, overlay.isVisible else { return }
        
        // User clicked!
        // 1. Show "Unlock" state immediately
        // 2. Hide with animation
        
        DispatchQueue.main.async {
            self.overlay.setLocked(false)
            
            // Short delay to let the user see the "Unlock" icon, then fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.overlay.hide(animated: true)
                // Reset to locked state after hiding, ready for next appearance
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.overlay.setLocked(true)
                }
            }
        }
        
        // Reset check timer so we don't immediately pop it back up before the click processes
        lastCheckTime = Date().timeIntervalSince1970 + 0.5
    }
    
    func mouseDidMove(to point: CGPoint) {
        // If we are currently running an animation (e.g. fading out), skip updates
        // To simplify, we rely on the fact that `checkState` is throttled.
        guard isEnabled else { return }
        overlay.updatePosition(to: point)
        
        let now = Date().timeIntervalSince1970
        if now - lastCheckTime > checkInterval {
            lastCheckTime = now
            checkState(at: point)
        }
    }
    
    private func checkState(at cursorPoint: CGPoint) {
        // If accessibility isn't enabled, we can't do anything meaningful
        guard WindowDetector.isAccessibilityTrusted() else { 
            Logger.shared.log("Accessiblity NOT trusted")
            return 
        }
        
        // New Logic: Screen-Based Detection
        // 1. Where is the active window?
        // 2. Where is the cursor?
        // 3. Are they on different screens?
        
        guard let activeWindowFrame = windowDetector.getActiveWindowFrame() else {
            // No active window found? Assume safe.
            setOverlay(visible: false)
            return
        }
        
        let screens = NSScreen.screens
        
        // Find screen containing active window center
        // Note: activeWindowFrame is CG (Top-Left 0,0). Screens usually handled with Cocoa (Bottom-Left 0,0) in high-level checks, 
        // BUT here we need to map carefuly.
        // Let's normalize everything to Cocoa coordinates (Bottom-Left) for NSScreen checks.
        
        guard let primaryScreenHeight = screens.first?.frame.height else { return }
        
        // Flip CoreGraphics Rect to Cocoa Rect
        let cocoaActiveWindowFrame = CGRect(
            x: activeWindowFrame.origin.x,
            y: primaryScreenHeight - (activeWindowFrame.origin.y + activeWindowFrame.height),
            width: activeWindowFrame.width,
            height: activeWindowFrame.height
        )
        
        // Which screen has the active window?
        // Simple heuristic: use the screen that contains the greatest area of the window.
        // Or simpler: Center point.
        let activeWindowScreen = screens.first { $0.frame.intersects(cocoaActiveWindowFrame) }
        
        // Which screen has the cursor?
        // cursorPoint is already Cocoa (Global Screen Coordinates) from MouseTracker
        let cursorScreen = screens.first { NSPointInRect(cursorPoint, $0.frame) }
        
        // Logic:
        // If they are on DIFFERENT screens -> Show Overlay
        // If they are on SAME screen -> Hide Overlay
        
        let shouldShow: Bool
        
        if let activeScreen = activeWindowScreen, let curScreen = cursorScreen {
            shouldShow = (activeScreen != curScreen)
            // Excessive logging, uncomment to debug
            // Logger.shared.log("ActiveScreen: \(activeScreen.localizedName) CursorScreen: \(curScreen.localizedName) ShouldShow: \(shouldShow)")
        } else {
            // Fallback: If we can't determine screens, hide to be safe
            shouldShow = false
        }
        
        DispatchQueue.main.async { [weak self] in
            // Only update visibility if we are NOT in the middle of a click-animation
            // (heuristic: if alpha is < 1, we might be fading out)
            // But simpler: just set it. If we overlap with animation, the next frame fixes it.
            // Check if we need to 'reset' the lock icon if it was shown again
            
            guard let self = self else { return }
            
            if shouldShow {
                // Always call show() to ensure alpha is reset if we interrupted an animation
                self.overlay.setLocked(true) 
                self.overlay.show()
            } else {
                // Only hide if we aren't already animating handled by click
                // But generally safe to just call hide (non-animated) if we moved back to safe zone
                if self.overlay.isVisible && self.overlay.alphaValue > 0.9 {
                     self.overlay.hide(animated: false)
                }
            }
        }
    }
    
    private func setOverlay(visible: Bool) {
        // Deprecated by direct logic above, but keeping if needed for refactor
        if visible {
            overlay.show()
        } else {
            overlay.hide()
        }
    }
}
