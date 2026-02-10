import Cocoa

class StateController: MouseTrackerDelegate {
    
    private let mouseTracker: MouseTracker
    private let windowDetector: WindowDetector
    private let overlay: OverlayIndicator
    private var swipeTracker: SwipeTracker?
    
    // Throttling to prevent excessive Accessibility API calls (expensive)
    private var lastCheckTime: TimeInterval = 0
    private var lastLogTime: TimeInterval = 0 // Debug throttle
    private let checkInterval: TimeInterval = 0.05 // ~20 checks per second max
    
    private var isEnabled = true
    private var clickMonitor: Any?
    
    // User Preferences
    var isSpacesSwipeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "EnableSpacesSwipe") }
        set { UserDefaults.standard.set(newValue, forKey: "EnableSpacesSwipe") }
    }
    
    var isOverlayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "EnableOverlay") }
        set { 
            UserDefaults.standard.set(newValue, forKey: "EnableOverlay")
            if !newValue {
                // Immediately hide if disabled
                DispatchQueue.main.async { [weak self] in
                    self?.overlay.hide(animated: false)
                }
            }
        }
    }
    
    init() {
        // Default to true if not set
        if UserDefaults.standard.object(forKey: "EnableSpacesSwipe") == nil {
            UserDefaults.standard.set(true, forKey: "EnableSpacesSwipe")
        }
        if UserDefaults.standard.object(forKey: "EnableOverlay") == nil {
            UserDefaults.standard.set(true, forKey: "EnableOverlay")
        }
        
        Logger.shared.log("App Started. Check Permissions: \(WindowDetector.isAccessibilityTrusted())")
        self.mouseTracker = MouseTracker()
        self.windowDetector = WindowDetector()
        self.overlay = OverlayIndicator()
        
        self.mouseTracker.delegate = self
        
        setupMenu()
        setupClickMonitoring()
        setupSpaceObserver()
        setupGestures()
    }
    
    deinit {
        swipeTracker = nil // Stop monitoring
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func setupGestures() {
        Logger.shared.log("Initializing Gesture Support...")
        self.swipeTracker = SwipeTracker()
        
        self.swipeTracker?.onSwipe = { [weak self] direction in
            guard let self = self else { return }
            guard self.isSpacesSwipeEnabled else { return }
            
            // Handle Horizontal Swipes (Left/Right)
            guard direction == .left || direction == .right else { return }
            
            // Get active window
            guard self.windowDetector.getActiveWindowID() != nil else {
                return
            }
            
            // Logger.shared.log("[StateController] ✅ Found Active Window ID: \(windowID). Attempting move handling...")
            
            if direction == .left {
                // Move Window to Next Display
                DisplayMover.shared.moveActiveWindowToNextDisplay()
            } else if direction == .right {
                // Move Window to Previous Display
                DisplayMover.shared.moveActiveWindowToPrevDisplay()
            }
        }
    }
    
    private func setupSpaceObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleSpaceChange() {
        // Space switch animation is slow (~0.4s). Check repeatedly.
        let delays = [0.1, 0.5, 0.8]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // We use current mouse location
                let loc = NSEvent.mouseLocation
                self.checkState(at: loc)
            }
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
        // If overlay feature is disabled, skip checks
        guard isOverlayEnabled else { return }

        // If accessibility isn't enabled, we can't do anything meaningful
        guard WindowDetector.isAccessibilityTrusted() else { return }
        
        let screens = NSScreen.screens
        guard let primaryScreenHeight = screens.first?.frame.height else { return }
        
        // ---------------------------------------------------------
        // PHASE 1: SYSTEM UI EXCLUSION (Fastest)
        // ---------------------------------------------------------
        
        // 1. Menu Bar Check
        if isCursorInMenuBar(cursorPoint, screens: screens) {
            updateOverlay(show: false, reason: "MenuBar")
            return
        }
        
        // 2. Identify Metadata
        let axCursorPoint = CGPoint(x: cursorPoint.x, y: primaryScreenHeight - cursorPoint.y)
        let pidUnder = windowDetector.getAppPID(at: axCursorPoint)
        let activeApp = NSWorkspace.shared.frontmostApplication
        
        // ---------------------------------------------------------
        // PHASE 2: PID / INTERACTION CHECK (Precision)
        // ---------------------------------------------------------
        
        if let pid = pidUnder, let app = NSRunningApplication(processIdentifier: pid), let bundleId = app.bundleIdentifier {
            
            // A. Whitelist Safe Apps (Always Hide)
            if isSafeBundle(bundleId) { 
                updateOverlay(show: false, reason: "SafeBundle")
                return 
            }
            
            // B. Active App Interaction (Consolidated)
            if let active = activeApp, pid == active.processIdentifier {
                updateOverlay(show: false, reason: "HoveringActiveApp")
                return
            }
        }
        
        // ---------------------------------------------------------
        // PHASE 3: GEOMETRY CHECK (Fallback)
        // ---------------------------------------------------------
        // If PID failed or mismatch, check geometry
        
        if let activeWindowFrame = windowDetector.getActiveWindowFrame() {
            let cocoaActiveWindowFrame = CGRect(
                x: activeWindowFrame.origin.x,
                y: primaryScreenHeight - (activeWindowFrame.origin.y + activeWindowFrame.height),
                width: activeWindowFrame.width,
                height: activeWindowFrame.height
            )
            
            // Relaxed geometry (padding)
            let relaxedFrame = cocoaActiveWindowFrame.insetBy(dx: -5, dy: -5)
            if NSPointInRect(cursorPoint, relaxedFrame) {
                 updateOverlay(show: false, reason: "GeometryMatch")
                 return
            }
        }
        
        // ---------------------------------------------------------
        // PHASE 4: VISUAL OVERRIDE (Last Resort)
        // ---------------------------------------------------------
        
        if isCursorOverActiveAppWindow(cursorPoint, primaryHeight: primaryScreenHeight) {
            updateOverlay(show: false, reason: "VisualOverride")
            return
        }
        
        // Check for Dock Visual Auto-Hide Override
        // This catches the Dock when it is popped up (Auto-Sized) even if AX fails
        if isCursorOverDock(cursorPoint, primaryHeight: primaryScreenHeight) {
             updateOverlay(show: false, reason: "DockVisual")
             return
        }

        // ---------------------------------------------------------
        // PHASE 5: UNSAFE (Show Lock)
        // ---------------------------------------------------------
        updateOverlay(show: true, reason: "Verdict:Unsafe")
    }
    
    // MARK: - Helpers
    
    private func updateOverlay(show: Bool, reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if show {
                if !self.overlay.isVisible || !self.overlay.isLockedState {
                    // Logger.shared.log("[DECISION] SHOW -> \(reason)")
                    self.overlay.setLocked(true)
                    self.overlay.show()
                }
                self.overlay.updatePosition(to: NSEvent.mouseLocation)
            } else {
                if self.overlay.isVisible {
                    // Logger.shared.log("[DECISION] HIDE -> \(reason)")
                    self.overlay.hide(animated: false)
                }
            }
        }
    }
    
    private func isCursorInMenuBar(_ point: CGPoint, screens: [NSScreen]) -> Bool {
        for screen in screens {
            if NSPointInRect(point, screen.frame) {
                if point.y > screen.visibleFrame.maxY {
                    return true
                }
            }
        }
        return false
    }
    
    private func isSafeBundle(_ bundleId: String) -> Bool {
        let safe = [
            Bundle.main.bundleIdentifier ?? "com.user.absentweaks",
            "com.apple.finder",
            "com.apple.WindowManager", // Stage Manager
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
            "com.apple.dock" // Dock, Launchpad, Mission Control
        ]
        return safe.contains(bundleId)
    }
    
    private func isCursorInDockArea(_ point: CGPoint, screens: [NSScreen]) -> Bool {
        guard let screen = screens.first(where: { NSPointInRect(point, $0.frame) }) else { return false }
        
        // Reliable check: The Dock resides in the exclusion zone of visibleFrame.
        // Since 'visibleFrame' describes the available working area (screen minus menu bar and dock),
        // any point OUTSIDE 'visibleFrame' is either Menu Bar or Dock.
        // We already checked Menu Bar (Top) in Phase 1, so this catches the Dock (Bottom/Left/Right).
        return !NSPointInRect(point, screen.visibleFrame)
    }

    private func isCursorOverActiveAppWindow(_ cursor: CGPoint, primaryHeight: CGFloat) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        
        for entry in list {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == Int(pid) else { continue }
            
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            
            // Convert CGWindowList bounds (Top-Left) to Cocoa (Bottom-Left)
            // Cocoa Y = PrimaryHeight - (CG_Y + CG_Height)
            let cocoaFrame = CGRect(
                x: bounds.origin.x,
                y: primaryHeight - (bounds.origin.y + bounds.height),
                width: bounds.width,
                height: bounds.height
            )
            
            if NSPointInRect(cursor, cocoaFrame) {
                return true
            }
        }
        
        return false
    }

    private func isCursorOverDock(_ cursor: CGPoint, primaryHeight: CGFloat) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        guard let dockApp = apps.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return false }
        let pid = dockApp.processIdentifier
        
        // Note: We MUST include Desktop elements to see the Dock, but filter out the Wallpaper later.
        let options: CGWindowListOption = [.optionOnScreenOnly] 
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        
        for entry in list {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == Int(pid) else { continue }
            
            
            // Filter out the Desktop Wallpaper (usually Layer < 0 or specific names)
            // The Dock itself is usually Layer 20 or similar (kCGBackstopMenuLevel)
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer > 0 else { continue }
            
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            
            let cocoaFrame = CGRect(
                x: bounds.origin.x,
                y: primaryHeight - (bounds.origin.y + bounds.height),
                width: bounds.width,
                height: bounds.height
            )
            
            if NSPointInRect(cursor, cocoaFrame) {
                // Logger.shared.log("Cursor OVER Dock Window! Layer=\(layer)")
                return true
            }
        }
        return false
    }

}
