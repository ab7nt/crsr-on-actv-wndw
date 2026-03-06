import Cocoa
import CoreServices

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
    private var isSuspended = false // For when dialogs are open
    private var clickMonitor: Any?
    private var clickMonitorLocal: Any? // Added separate handle for local
    private var dockMinimizeMouseDownMonitorGlobal: Any?
    private var dockMinimizeMonitorGlobal: Any?
    private var lastDockMinimizeAttemptAt: TimeInterval = 0
    private var lastDockMouseDownFrontmostPID: pid_t?
    private var lastDockMouseDownItemName: String?
    private var lastDockMouseDownAt: TimeInterval = 0
    private var lastDockMouseDownHadUnminimizedFocusedWindow: Bool = false
    
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
                DispatchQueue.main.async { [weak self] in
                    self?.overlay.hide(animated: false)
                }
            }
        }
    }
    
    var isMiddleClickGestureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "EnableMiddleClickGesture") }
        set {
            UserDefaults.standard.set(newValue, forKey: "EnableMiddleClickGesture")
            updateTrackpadListenerState()
        }
    }

    var isAppLaunchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "EnableAppLaunch") }
        set {
            UserDefaults.standard.set(newValue, forKey: "EnableAppLaunch")
            updateTrackpadListenerState()
            setupAppLauncher()
        }
    }
    
    var selectedAppPath: String? {
        get { UserDefaults.standard.string(forKey: "SelectedAppPath") }
        set { UserDefaults.standard.set(newValue, forKey: "SelectedAppPath") }
    }
    
    func setOverlayEnabledFromUser(_ enabled: Bool) -> Bool {
        guard enabled else {
            isOverlayEnabled = false
            return false
        }

        guard ensureAccessibilityPermissionRequested() else {
            return false
        }

        isOverlayEnabled = true
        return true
    }

    func setSpacesSwipeEnabledFromUser(_ enabled: Bool) -> Bool {
        guard enabled else {
            isSpacesSwipeEnabled = false
            return false
        }

        guard ensureAccessibilityPermissionRequested() else {
            return false
        }

        isSpacesSwipeEnabled = true
        return true
    }

    func setMiddleClickGestureEnabledFromUser(_ enabled: Bool) -> Bool {
        guard enabled else {
            isMiddleClickGestureEnabled = false
            return false
        }

        guard ensureAccessibilityPermissionRequested() else {
            return false
        }

        isMiddleClickGestureEnabled = true
        return true
    }

    private func ensureAccessibilityPermissionRequested() -> Bool {
        if WindowDetector.isAccessibilityTrusted() {
            return true
        }

        WindowDetector.requestPermissions()
        return WindowDetector.isAccessibilityTrusted()
    }
    
    init() {
        if UserDefaults.standard.object(forKey: "EnableSpacesSwipe") == nil {
            UserDefaults.standard.set(false, forKey: "EnableSpacesSwipe")
        }
        if UserDefaults.standard.object(forKey: "EnableOverlay") == nil {
            UserDefaults.standard.set(false, forKey: "EnableOverlay")
        }
        if UserDefaults.standard.object(forKey: "EnableMiddleClickGesture") == nil {
            UserDefaults.standard.set(false, forKey: "EnableMiddleClickGesture")
        }
        if UserDefaults.standard.object(forKey: "EnableAppLaunch") == nil {
            UserDefaults.standard.set(false, forKey: "EnableAppLaunch")
        }
        Logger.shared.log("App Started. Check Permissions: \(WindowDetector.isAccessibilityTrusted())")
        self.mouseTracker = MouseTracker()
        self.windowDetector = WindowDetector()
        self.overlay = OverlayIndicator()
        
        self.mouseTracker.delegate = self
        
        setupClickMonitoring()
        setupDockMinimizeMonitoring()
        setupSpaceObserver()
        setupGestures()
        setupTrackpadGestures()
    }
    
    deinit {
        swipeTracker = nil // Stop monitoring
        TrackpadListener.shared.stop()
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = dockMinimizeMonitorGlobal {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = dockMinimizeMouseDownMonitorGlobal {
            NSEvent.removeMonitor(monitor)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    // MARK: - Trackpad Handling
    
    private func setupTrackpadGestures() {
        TrackpadListener.shared.onThreeFingerTap = { [weak self] in
            self?.simulateMiddleClick()
        }
        setupAppLauncher()
        updateTrackpadListenerState()
    }

    private func setupAppLauncher() {
         if isAppLaunchEnabled {
            TrackpadListener.shared.onThreeFingerDoubleTap = { [weak self] in
                self?.launchSelectedApp()
            }
        } else {
            TrackpadListener.shared.onThreeFingerDoubleTap = nil
        }
    }

    private func launchSelectedApp() {
        guard let path = selectedAppPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
    
    private func updateTrackpadListenerState() {
        guard !isSuspended else {
            TrackpadListener.shared.stop()
            return
        }
        
        let anyEnabled = isMiddleClickGestureEnabled || isAppLaunchEnabled
        TrackpadListener.shared.isEnabled = anyEnabled
        
        if anyEnabled {
            DispatchQueue.global(qos: .userInitiated).async {
                TrackpadListener.shared.start()
            }
        } else {
            TrackpadListener.shared.stop()
        }
    }

    // MARK: - Dock Re-click Minimize (Global)

    private func setupDockMinimizeMonitoring() {
        if dockMinimizeMouseDownMonitorGlobal == nil {
            dockMinimizeMouseDownMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleDockMouseDownSnapshot(event)
            }
        }
        guard dockMinimizeMonitorGlobal == nil else { return }
        dockMinimizeMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleDockMouseDown(event)
        }
    }

    private func handleDockMouseDownSnapshot(_ event: NSEvent) {
        lastDockMouseDownAt = ProcessInfo.processInfo.systemUptime
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            lastDockMouseDownFrontmostPID = frontmost.processIdentifier
            lastDockMouseDownHadUnminimizedFocusedWindow = hasUnminimizedFocusedWindow(of: frontmost)
        } else {
            lastDockMouseDownFrontmostPID = nil
            lastDockMouseDownHadUnminimizedFocusedWindow = false
        }
        lastDockMouseDownItemName = dockApplicationItemName(at: event.locationInWindow)
    }

    private func handleDockMouseDown(_ event: NSEvent) {
        guard UserDefaults.standard.bool(forKey: "HideBackToDockOnReopen") else {
            Logger.shared.log("[DockMinimize] ignored: setting disabled")
            return
        }
        guard WindowDetector.isAccessibilityTrusted() else {
            Logger.shared.log("[DockMinimize] ignored: accessibility not trusted")
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDockMinimizeAttemptAt < 0.2 {
            Logger.shared.log("[DockMinimize] ignored: debounce")
            return
        }
        lastDockMinimizeAttemptAt = now

        guard let activeApp = NSWorkspace.shared.frontmostApplication else {
            Logger.shared.log("[DockMinimize] ignored: no frontmost app")
            return
        }
        guard let activeName = activeApp.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !activeName.isEmpty else {
            Logger.shared.log("[DockMinimize] ignored: frontmost app has empty name")
            return
        }

        let clickPoint = event.locationInWindow
        guard let dockItemName = dockApplicationItemName(at: clickPoint) else {
            Logger.shared.log("[DockMinimize] ignored: click at \(clickPoint) is not Dock app item")
            return
        }
        guard dockItemName.caseInsensitiveCompare(activeName) == .orderedSame else {
            Logger.shared.log("[DockMinimize] ignored: dock item '\(dockItemName)' != frontmost '\(activeName)'")
            return
        }

        let downAge = ProcessInfo.processInfo.systemUptime - lastDockMouseDownAt
        guard downAge >= 0, downAge < 1.0 else {
            Logger.shared.log("[DockMinimize] ignored: stale mousedown snapshot, age=\(String(format: "%.3f", downAge))")
            return
        }
        guard let downPID = lastDockMouseDownFrontmostPID,
              downPID == activeApp.processIdentifier else {
            Logger.shared.log("[DockMinimize] ignored: app was not active on mousedown")
            return
        }
        guard let downItem = lastDockMouseDownItemName,
              downItem.caseInsensitiveCompare(activeName) == .orderedSame else {
            Logger.shared.log("[DockMinimize] ignored: mousedown dock item mismatch (down='\(lastDockMouseDownItemName ?? "nil")', active='\(activeName)')")
            return
        }
        guard lastDockMouseDownHadUnminimizedFocusedWindow else {
            Logger.shared.log("[DockMinimize] ignored: app had no unminimized focused window on mousedown")
            return
        }

        Logger.shared.log("[DockMinimize] match: dock item '\(dockItemName)', frontmost '\(activeName)', scheduling minimize")

        // Run after Dock finishes processing the click, otherwise the app can be re-activated immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            guard let currentFrontmost = NSWorkspace.shared.frontmostApplication,
                  currentFrontmost.processIdentifier == activeApp.processIdentifier else {
                let currentName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
                Logger.shared.log("[DockMinimize] canceled after delay: frontmost changed to '\(currentName)'")
                return
            }
            Logger.shared.log("[DockMinimize] executing minimize for '\(activeName)'")
            self.minimizeFocusedWindow(of: activeApp)
        }
    }

    private func dockApplicationItemName(at cocoaPoint: CGPoint) -> String? {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }

        guard let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            return nil
        }
        let axY = primaryScreen.frame.height - cocoaPoint.y

        let dockAX = AXUIElementCreateApplication(dockApp.processIdentifier)
        var hitElement: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(dockAX, Float(cocoaPoint.x), Float(axY), &hitElement)
        guard hitResult == .success, let element = hitElement else {
            return nil
        }

        var subroleValue: AnyObject?
        let subroleResult = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        guard subroleResult == .success,
              let subrole = subroleValue as? String,
              subrole == "AXApplicationDockItem" else {
            return nil
        }

        var titleValue: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        guard titleResult == .success,
              let title = (titleValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        return title
    }

    private func minimizeFocusedWindow(of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let windowEl = focusedWindow as! AXUIElement? else {
            Logger.shared.log("[DockMinimize] AX focused window unavailable for '\(app.localizedName ?? "unknown")', result=\(result.rawValue)")
            return
        }

        let appName = app.localizedName ?? "unknown"
        let beforeMinimized = readWindowMinimizedState(windowEl)

        let setResult = AXUIElementSetAttributeValue(windowEl, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        let afterSetMinimized = readWindowMinimizedState(windowEl)
        Logger.shared.log("[DockMinimize] AX set minimized '\(appName)': setResult=\(setResult.rawValue), before=\(String(describing: beforeMinimized)), afterSet=\(String(describing: afterSetMinimized))")

        if afterSetMinimized == true {
            return
        }

        if pressWindowMinimizeButton(windowEl) {
            let afterPressMinimized = readWindowMinimizedState(windowEl)
            Logger.shared.log("[DockMinimize] AX minimize button '\(appName)': afterPress=\(String(describing: afterPressMinimized))")
            if afterPressMinimized == true {
                return
            }
        } else {
            Logger.shared.log("[DockMinimize] AX minimize button unavailable for '\(appName)'")
        }

        let sentCmdM = sendCmdM()
        Logger.shared.log("[DockMinimize] fallback Cmd+M for '\(appName)': sent=\(sentCmdM)")
    }

    private func hasUnminimizedFocusedWindow(of app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let windowEl = focusedWindow as! AXUIElement? else {
            return false
        }
        let minimized = readWindowMinimizedState(windowEl)
        return minimized == false
    }

    private func readWindowMinimizedState(_ windowEl: AXUIElement) -> Bool? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(windowEl, kAXMinimizedAttribute as CFString, &value)
        guard result == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func pressWindowMinimizeButton(_ windowEl: AXUIElement) -> Bool {
        var buttonValue: AnyObject?
        let buttonResult = AXUIElementCopyAttributeValue(windowEl, kAXMinimizeButtonAttribute as CFString, &buttonValue)
        guard buttonResult == .success, let buttonEl = buttonValue as! AXUIElement? else {
            return false
        }
        let pressResult = AXUIElementPerformAction(buttonEl, kAXPressAction as CFString)
        return pressResult == .success
    }

    private func sendCmdM() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 46, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 46, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Suspension Logic
    
    func suspendForDialog() {
        Logger.shared.log("Suspending for Dialog...")
        isSuspended = true
        TrackpadListener.shared.stop()
        mouseTracker.stopTracking()
        swipeTracker?.stop()
        stopClickMonitoring()
        overlay.hide(animated: false)
    }
    
    func resumeFromDialog() {
        Logger.shared.log("Resuming from Dialog...")
        isSuspended = false
        updateTrackpadListenerState()
        mouseTracker.startTracking()
        swipeTracker?.start()
        startClickMonitoring()
    }

    private func simulateMiddleClick() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let point = CGEvent(source: nil)?.location ?? .zero
        
        if let mouseDown = CGEvent(mouseEventSource: source, mouseType: .otherMouseDown, mouseCursorPosition: point, mouseButton: .center),
           let mouseUp = CGEvent(mouseEventSource: source, mouseType: .otherMouseUp, mouseCursorPosition: point, mouseButton: .center) {
            mouseDown.post(tap: .cghidEventTap)
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    private func setupGestures() {
        Logger.shared.log("Initializing Gesture Support...")
        self.swipeTracker = SwipeTracker()
        
        self.swipeTracker?.onSwipe = { [weak self] direction in
            guard let self = self else { return }
            guard self.isSpacesSwipeEnabled else { return }
            
            guard direction == .left || direction == .right else { return }
            
            guard self.windowDetector.getActiveWindowID() != nil else {
                return
            }
            
            if direction == .left {
                DisplayMover.shared.moveActiveWindowToNextDisplay()
            } else if direction == .right {
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
        let delays = [0.1, 0.5, 0.8]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let loc = NSEvent.mouseLocation
                self.checkState(at: loc)
            }
        }
    }
    
    private func setupClickMonitoring() {
        startClickMonitoring()
    }
    
    private func startClickMonitoring() {
        guard clickMonitor == nil else { return }
        
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.handleGlobalClick()
        }
        
        clickMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleGlobalClick()
            return event
        }
    }
    
    private func stopClickMonitoring() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
        if let m = clickMonitorLocal {
            NSEvent.removeMonitor(m)
            clickMonitorLocal = nil
        }
    }
    
    private func handleGlobalClick() {
        guard isEnabled, overlay.isVisible else { return }
        
        DispatchQueue.main.async {
            self.overlay.setLocked(false)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.overlay.hide(animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.overlay.setLocked(true)
                }
            }
        }
        
        lastCheckTime = Date().timeIntervalSince1970 + 0.5
    }
    
    func mouseDidMove(to point: CGPoint) {
        guard isEnabled else { return }
        overlay.updatePosition(to: point)
        
        let now = Date().timeIntervalSince1970
        if now - lastCheckTime > checkInterval {
            lastCheckTime = now
            checkState(at: point)
        }
    }
    
    private func checkState(at cursorPoint: CGPoint) {
        guard isOverlayEnabled else { return }

        guard WindowDetector.isAccessibilityTrusted() else { return }
        
        let screens = NSScreen.screens
        guard let primaryScreenHeight = screens.first?.frame.height else { return }
        
        if isCursorInMenuBar(cursorPoint, screens: screens) {
            updateOverlay(show: false, reason: "MenuBar")
            return
        }
        
        let axCursorPoint = CGPoint(x: cursorPoint.x, y: primaryScreenHeight - cursorPoint.y)
        let pidUnder = windowDetector.getAppPID(at: axCursorPoint)
        let activeApp = NSWorkspace.shared.frontmostApplication

        if let pid = pidUnder, let app = NSRunningApplication(processIdentifier: pid), let _ = app.bundleIdentifier {
        } else {
        }

        if let pid = pidUnder, let app = NSRunningApplication(processIdentifier: pid), let bundleId = app.bundleIdentifier {
            if isSafeBundle(bundleId) {
                updateOverlay(show: false, reason: "SafeBundle: \(bundleId)")
                return
            }
            
            if let active = activeApp, pid == active.processIdentifier {
                updateOverlay(show: false, reason: "HoveringActiveApp: \(bundleId)")
                return
            }
        }
        
        if let activeWindowFrame = windowDetector.getActiveWindowFrame() {
            let cocoaActiveWindowFrame = CGRect(
                x: activeWindowFrame.origin.x,
                y: primaryScreenHeight - (activeWindowFrame.origin.y + activeWindowFrame.height),
                width: activeWindowFrame.width,
                height: activeWindowFrame.height
            )
            
            let relaxedFrame = cocoaActiveWindowFrame.insetBy(dx: -5, dy: -5)
            if NSPointInRect(cursorPoint, relaxedFrame) {
                 updateOverlay(show: false, reason: "GeometryMatch")
                 return
            }
        }
        
        if isCursorOverActiveAppWindow(cursorPoint, primaryHeight: primaryScreenHeight) {
            updateOverlay(show: false, reason: "VisualOverride")
            return
        }
        
        if isCursorOverDock(cursorPoint, primaryHeight: primaryScreenHeight) {
             updateOverlay(show: false, reason: "DockVisual")
             return
        }

        updateOverlay(show: true, reason: "Verdict:Unsafe")
    }
    
    // MARK: - Helpers
    
    private func updateOverlay(show: Bool, reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if show {
                if !self.overlay.isVisible || !self.overlay.isLockedState {
                    self.overlay.setLocked(true)
                    self.overlay.show()
                }
                self.overlay.updatePosition(to: NSEvent.mouseLocation)
            } else {
                if self.overlay.isVisible {
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
        let safeBundles = [
            "com.apple.dock",
            "com.apple.systemuiserver",
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
            "com.apple.loginwindow"
        ]
        return safeBundles.contains(bundleId)
    }
    
    private func isCursorOverDock(_ cursorPoint: CGPoint, primaryHeight: CGFloat) -> Bool {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return false
        }
        
        let dockPID = dockApp.processIdentifier
        let dockElement = AXUIElementCreateApplication(dockPID)
        
        var windowsValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(dockElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success,
              let dockWindows = windowsValue as? [AXUIElement],
              !dockWindows.isEmpty else {
            return false
        }
        
        for dockWindow in dockWindows {
            var posValue: AnyObject?
            var sizeValue: AnyObject?
            AXUIElementCopyAttributeValue(dockWindow, kAXPositionAttribute as CFString, &posValue)
            AXUIElementCopyAttributeValue(dockWindow, kAXSizeAttribute as CFString, &sizeValue)
            
            if posValue != nil, sizeValue != nil {
                let pos = posValue as! AXValue
                let size = sizeValue as! AXValue
                var cgPos = CGPoint.zero
                var cgSize = CGSize.zero
                AXValueGetValue(pos, .cgPoint, &cgPos)
                AXValueGetValue(size, .cgSize, &cgSize)
                
                let cocoaRect = CGRect(x: cgPos.x,
                                       y: primaryHeight - (cgPos.y + cgSize.height),
                                       width: cgSize.width,
                                       height: cgSize.height)
                if cocoaRect.contains(cursorPoint) {
                    return true
                }
            }
        }
        
        return false
    }
    
    private func isCursorOverActiveAppWindow(_ cursorPoint: CGPoint, primaryHeight: CGFloat) -> Bool {
        guard let activeApp = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(activeApp.processIdentifier)
        
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let windowEl = focusedWindow as! AXUIElement? else {
            return false
        }
        
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(windowEl, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(windowEl, kAXSizeAttribute as CFString, &sizeValue)
        
        guard posValue != nil, sizeValue != nil else {
            return false
        }
        let pos = posValue as! AXValue
        let size = sizeValue as! AXValue
        
        var cgPos = CGPoint.zero
        var cgSize = CGSize.zero
        AXValueGetValue(pos, .cgPoint, &cgPos)
        AXValueGetValue(size, .cgSize, &cgSize)
        
        let cocoaRect = CGRect(x: cgPos.x,
                               y: primaryHeight - (cgPos.y + cgSize.height),
                               width: cgSize.width,
                               height: cgSize.height)
        return cocoaRect.contains(cursorPoint)
    }
}
