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
    private var activateVisibleMouseUpMonitorGlobal: Any?
    private var activateVisibleMouseUpMonitorLocal: Any?
    private var hasActivateVisibleTerminationObserver = false
    private var lastDockMinimizeAttemptAt: TimeInterval = 0
    private var lastActivateVisibleRepairAt: TimeInterval = 0
    private var suppressActivateVisibleUntil: TimeInterval = 0
    private var lastDockMouseDownFrontmostPID: pid_t?
    private var lastDockMouseDownItemName: String?
    private var lastDockMouseDownAt: TimeInterval = 0
    private var lastDockMouseDownHadUnminimizedFocusedWindow: Bool = false
    private var isMiddleAutoScrollActive = false
    private var middleAutoScrollVelocityX: CGFloat = 0
    private var middleAutoScrollVelocityY: CGFloat = 0
    private var middleAutoScrollResidualX: CGFloat = 0
    private var middleAutoScrollResidualY: CGFloat = 0
    private var middleAutoScrollLastImpulseAt: TimeInterval = 0
    private var middleAutoScrollTimer: DispatchSourceTimer?
    
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

    var isMiddleScrollGestureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "EnableMiddleScrollGesture") }
        set { UserDefaults.standard.set(newValue, forKey: "EnableMiddleScrollGesture") }
    }

    var isActivateVisibleAppEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "EnableActivateVisibleApp") }
        set { UserDefaults.standard.set(newValue, forKey: "EnableActivateVisibleApp") }
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

    func setMiddleScrollGestureEnabledFromUser(_ enabled: Bool) -> Bool {
        guard enabled else {
            isMiddleScrollGestureEnabled = false
            return false
        }

        guard ensureAccessibilityPermissionRequested() else {
            return false
        }

        isMiddleScrollGestureEnabled = true
        return true
    }

    func setActivateVisibleAppEnabledFromUser(_ enabled: Bool) -> Bool {
        guard enabled else {
            isActivateVisibleAppEnabled = false
            return false
        }

        guard ensureAccessibilityPermissionRequested() else {
            return false
        }

        isActivateVisibleAppEnabled = true
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
        if UserDefaults.standard.object(forKey: "EnableMiddleScrollGesture") == nil {
            UserDefaults.standard.set(false, forKey: "EnableMiddleScrollGesture")
        }
        if UserDefaults.standard.object(forKey: "EnableActivateVisibleApp") == nil {
            UserDefaults.standard.set(false, forKey: "EnableActivateVisibleApp")
        }
        Logger.shared.log("App Started. Check Permissions: \(WindowDetector.isAccessibilityTrusted())")
        self.mouseTracker = MouseTracker()
        self.windowDetector = WindowDetector()
        self.overlay = OverlayIndicator()
        
        self.mouseTracker.delegate = self
        
        setupClickMonitoring()
        setupDockMinimizeMonitoring()
        setupActivateVisibleAppMonitoring()
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
        if let monitor = activateVisibleMouseUpMonitorGlobal {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = activateVisibleMouseUpMonitorLocal {
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
        suppressActivateVisibleUntil = ProcessInfo.processInfo.systemUptime + 1.2
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

    // MARK: - Activate Visible App After Close/Minimize

    private func setupActivateVisibleAppMonitoring() {
        if activateVisibleMouseUpMonitorGlobal == nil {
            activateVisibleMouseUpMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                self?.scheduleActivateVisibleAppRepair(cursorPoint: NSEvent.mouseLocation)
            }
        }

        if activateVisibleMouseUpMonitorLocal == nil {
            activateVisibleMouseUpMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.scheduleActivateVisibleAppRepair(cursorPoint: NSEvent.mouseLocation)
                return event
            }
        }

        if !hasActivateVisibleTerminationObserver {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(handleApplicationDidTerminate(_:)),
                name: NSWorkspace.didTerminateApplicationNotification,
                object: nil
            )
            hasActivateVisibleTerminationObserver = true
        }
    }

    @objc private func handleApplicationDidTerminate(_ notification: Notification) {
        guard isActivateVisibleAppEnabled, !isSuspended else { return }

        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.processIdentifier == NSRunningApplication.current.processIdentifier {
            return
        }

        scheduleActivateVisibleAppRepair(
            cursorPoint: NSEvent.mouseLocation,
            delays: [0.12, 0.45, 1.35]
        )
    }

    private func scheduleActivateVisibleAppRepair(cursorPoint: CGPoint, delays: [Double] = [0.12, 0.35]) {
        guard isActivateVisibleAppEnabled, !isSuspended else { return }
        guard let targetScreen = screen(containing: cursorPoint) else { return }
        let targetScreenFrame = targetScreen.frame

        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.activateVisibleAppIfNeeded(targetScreenFrame: targetScreenFrame)
            }
        }
    }

    private func activateVisibleAppIfNeeded(targetScreenFrame: CGRect) {
        guard isActivateVisibleAppEnabled, !isSuspended else { return }
        guard WindowDetector.isAccessibilityTrusted() else { return }
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastActivateVisibleRepairAt > 0.18 else { return }
        guard now >= suppressActivateVisibleUntil else {
            return
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        let frontmostPID = frontmost.processIdentifier

        guard !hasVisibleNormalWindow(pid: frontmostPID, on: targetScreenFrame, primaryHeight: primaryScreenHeight) else {
            return
        }

        if hasActiveAXSurface(frontmost, on: targetScreenFrame, primaryHeight: primaryScreenHeight) {
            return
        }

        guard let visibleApp = topVisibleNormalApplication(
            excluding: frontmostPID,
            on: targetScreenFrame,
            primaryHeight: primaryScreenHeight
        ) else {
            return
        }

        lastActivateVisibleRepairAt = now
        visibleApp.activate(options: [.activateAllWindows])
    }

    private func hasActiveAXSurface(_ app: NSRunningApplication, on screenFrame: CGRect, primaryHeight: CGFloat) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        if let focusedWindow = copyAXElementAttribute(axApp, kAXFocusedWindowAttribute as CFString) {
            return isUsableAXSurface(focusedWindow, on: screenFrame, primaryHeight: primaryHeight)
        }

        if let mainWindow = copyAXElementAttribute(axApp, kAXMainWindowAttribute as CFString) {
            return isUsableAXSurface(mainWindow, on: screenFrame, primaryHeight: primaryHeight)
        }

        return false
    }

    private func isUsableAXSurface(_ windowEl: AXUIElement, on screenFrame: CGRect, primaryHeight: CGFloat) -> Bool {
        if readWindowMinimizedState(windowEl) == true {
            return false
        }

        let role = axStringAttribute(windowEl, kAXRoleAttribute as CFString)
        let subrole = axStringAttribute(windowEl, kAXSubroleAttribute as CFString)
        let isWindowLike = role == kAXWindowRole as String ||
            role == "AXDialog" ||
            role == "AXPopover" ||
            subrole == "AXSystemDialog" ||
            subrole == "AXFloatingWindow"

        guard isWindowLike else {
            return false
        }

        guard let rect = axWindowRect(windowEl, primaryHeight: primaryHeight) else {
            return true
        }

        return rect.intersects(screenFrame)
    }

    private func copyAXElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as! AXUIElement?
    }

    private func axStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func hasVisibleNormalWindow(pid: pid_t, on screenFrame: CGRect, primaryHeight: CGFloat) -> Bool {
        visibleNormalWindowInfos().contains { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber else {
                return false
            }
            guard ownerPID.int32Value == pid,
                  let windowRect = cocoaWindowRect(from: info, primaryHeight: primaryHeight) else {
                return false
            }
            return windowRect.intersects(screenFrame)
        }
    }

    private func topVisibleNormalApplication(excluding excludedPID: pid_t, on screenFrame: CGRect, primaryHeight: CGFloat) -> NSRunningApplication? {
        for info in visibleNormalWindowInfos() {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }
            guard let windowRect = cocoaWindowRect(from: info, primaryHeight: primaryHeight),
                  windowRect.intersects(screenFrame) else {
                continue
            }

            let pid = ownerPID.int32Value
            guard pid != excludedPID,
                  pid != NSRunningApplication.current.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  !isSafeBundle(bundleID) else {
                continue
            }

            return app
        }

        return nil
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return screen
        }

        return NSScreen.screens.min { lhs, rhs in
            distance(from: point, to: lhs.frame) < distance(from: point, to: rhs.frame)
        }
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - clampedX, point.y - clampedY)
    }

    private func cocoaWindowRect(from info: [String: Any], primaryHeight: CGFloat) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? NSNumber,
              let y = bounds["Y"] as? NSNumber,
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber else {
            return nil
        }

        return CGRect(
            x: x.doubleValue,
            y: Double(primaryHeight) - (y.doubleValue + height.doubleValue),
            width: width.doubleValue,
            height: height.doubleValue
        )
    }

    private func visibleNormalWindowInfos() -> [[String: Any]] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowList.filter { info in
            guard let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0 else {
                return false
            }

            if let alpha = info[kCGWindowAlpha as String] as? NSNumber,
               alpha.doubleValue <= 0.01 {
                return false
            }

            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber else {
                return false
            }

            return width.doubleValue >= 80 && height.doubleValue >= 40
        }
    }

    // MARK: - Suspension Logic
    
    func suspendForDialog() {
        Logger.shared.log("Suspending for Dialog...")
        isSuspended = true
        stopMiddleAutoScroll(reason: "suspend")
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

    private func handleCommandAutoScrollGesture(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            stopMiddleAutoScroll(reason: "command released")
            return
        }

        if event.phase == .ended || event.phase == .cancelled {
            stopMiddleAutoScroll(reason: "touch ended")
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = middleAutoScrollLastImpulseAt > 0 ? now - middleAutoScrollLastImpulseAt : 1.0 / 60.0
        middleAutoScrollLastImpulseAt = now

        let previousVelocityY = middleAutoScrollVelocityY
        let previousVelocityX = middleAutoScrollVelocityX
        middleAutoScrollVelocityY = accumulatedAutoScrollVelocity(
            current: middleAutoScrollVelocityY,
            delta: event.scrollingDeltaY,
            elapsed: elapsed,
            maxStep: 88
        )
        middleAutoScrollVelocityX = accumulatedAutoScrollVelocity(
            current: middleAutoScrollVelocityX,
            delta: event.scrollingDeltaX,
            elapsed: elapsed,
            maxStep: 72
        )

        let didChangeVelocity = abs(middleAutoScrollVelocityY - previousVelocityY) > 0.05 ||
            abs(middleAutoScrollVelocityX - previousVelocityX) > 0.05
        guard didChangeVelocity else { return }

        if !isMiddleAutoScrollActive {
            startMiddleAutoScroll()
        }
    }

    private func startMiddleAutoScroll() {
        guard !isMiddleAutoScrollActive else { return }
        isMiddleAutoScrollActive = true
        middleAutoScrollResidualX = 0
        middleAutoScrollResidualY = 0

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.emitMiddleAutoScrollStep()
        }
        middleAutoScrollTimer = timer
        timer.resume()
        Logger.shared.log("[MiddleAutoScroll] started")
    }

    private func stopMiddleAutoScroll(reason: String) {
        guard isMiddleAutoScrollActive else { return }
        isMiddleAutoScrollActive = false
        middleAutoScrollVelocityX = 0
        middleAutoScrollVelocityY = 0
        middleAutoScrollResidualX = 0
        middleAutoScrollResidualY = 0
        middleAutoScrollLastImpulseAt = 0
        middleAutoScrollTimer?.cancel()
        middleAutoScrollTimer = nil
        Logger.shared.log("[MiddleAutoScroll] stopped: \(reason)")
    }

    private func emitMiddleAutoScrollStep() {
        guard isMiddleAutoScrollActive else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let wheel1 = scrollStep(from: middleAutoScrollVelocityY, residual: &middleAutoScrollResidualY)
        let wheel2 = scrollStep(from: middleAutoScrollVelocityX, residual: &middleAutoScrollResidualX)
        guard wheel1 != 0 || wheel2 != 0 else { return }

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ) else { return }

        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private func accumulatedAutoScrollVelocity(current: CGFloat, delta: CGFloat, elapsed: TimeInterval, maxStep: CGFloat) -> CGFloat {
        let elapsed = min(max(elapsed, 1.0 / 240.0), 0.12)
        let decay = pow(0.2, CGFloat(elapsed / 0.12))
        let decayedCurrent = current * decay
        let impulse = autoScrollImpulse(fromScrollDelta: delta, maxStep: maxStep)

        guard impulse != 0 else { return decayedCurrent }
        guard decayedCurrent == 0 || impulse.sign == decayedCurrent.sign else {
            return impulse
        }

        return max(-maxStep, min(maxStep, decayedCurrent + impulse))
    }

    private func autoScrollImpulse(fromScrollDelta delta: CGFloat, maxStep: CGFloat) -> CGFloat {
        let sign: CGFloat = delta >= 0 ? 1 : -1
        let value = abs(delta)
        guard value > 0.05 else { return 0 }

        let curved = pow(value, 1.18)
        let minimumStep: CGFloat = 0.18
        return sign * min(maxStep, max(minimumStep, curved * 1.7))
    }

    private func scrollStep(from velocity: CGFloat, residual: inout CGFloat) -> Int32 {
        residual += velocity
        let step: CGFloat
        if residual >= 0 {
            step = floor(residual)
        } else {
            step = ceil(residual)
        }
        residual -= step
        return Int32(step)
    }

    private func setupGestures() {
        Logger.shared.log("Initializing Gesture Support...")
        self.swipeTracker = SwipeTracker()
        
        self.swipeTracker?.onSwipe = { [weak self] direction in
            guard let self = self else { return }
            guard self.isSpacesSwipeEnabled else { return }
            
            guard direction == .left || direction == .right else { return }

            if direction == .left {
                DisplayMover.shared.moveActiveWindowToNextDisplay()
            } else if direction == .right {
                DisplayMover.shared.moveActiveWindowToPrevDisplay()
            }
        }

        self.swipeTracker?.onCommandAutoScroll = { [weak self] event in
            guard let self = self else { return }
            guard self.isMiddleScrollGestureEnabled else { return }
            self.handleCommandAutoScrollGesture(event)
        }

        self.swipeTracker?.onCommandAutoScrollEnd = { [weak self] in
            self?.stopMiddleAutoScroll(reason: "command scroll ended")
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
        
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
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
        if isMiddleAutoScrollActive {
            stopMiddleAutoScroll(reason: "mouse click")
        }

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

            if let activeBundleId = activeApp?.bundleIdentifier, bundleId == activeBundleId {
                updateOverlay(show: false, reason: "HoveringActiveBundle: \(bundleId)")
                return
            }
        }

        if isCursorOverFrontmostAppCGWindow(cursorPoint, primaryHeight: primaryScreenHeight) {
            updateOverlay(show: false, reason: "CGVisualOverride")
            return
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

        var windows: [AXUIElement] = []

        var focusedWindow: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let windowEl = focusedWindow as! AXUIElement? {
            windows.append(windowEl)
        }

        var mainWindow: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainWindow) == .success,
           let windowEl = mainWindow as! AXUIElement? {
            windows.append(windowEl)
        }

        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let appWindows = windowsValue as? [AXUIElement] {
            windows.append(contentsOf: appWindows)
        }

        for windowEl in windows {
            guard let rect = axWindowRect(windowEl, primaryHeight: primaryHeight) else { continue }
            if rect.insetBy(dx: -5, dy: -5).contains(cursorPoint) {
                return true
            }
        }

        return false
    }

    private func isCursorOverFrontmostAppCGWindow(_ cursorPoint: CGPoint, primaryHeight: CGFloat) -> Bool {
        guard let activeApp = NSWorkspace.shared.frontmostApplication else { return false }

        for info in visibleNormalWindowInfos() {
            guard let windowRect = cocoaWindowRect(from: info, primaryHeight: primaryHeight),
                  windowRect.insetBy(dx: -5, dy: -5).contains(cursorPoint),
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }

            return pidBelongsToApp(ownerPID.int32Value, activeApp)
        }

        return false
    }

    private func pidBelongsToApp(_ pid: pid_t, _ app: NSRunningApplication) -> Bool {
        if pid == app.processIdentifier {
            return true
        }

        guard let ownerApp = NSRunningApplication(processIdentifier: pid) else {
            return false
        }

        if let ownerBundleID = ownerApp.bundleIdentifier,
           let activeBundleID = app.bundleIdentifier,
           (ownerBundleID == activeBundleID ||
            ownerBundleID.hasPrefix(activeBundleID + ".") ||
            activeBundleID.hasPrefix(ownerBundleID + ".")) {
            return true
        }

        if let ownerBundlePath = ownerApp.bundleURL?.standardizedFileURL.path,
           let activeBundlePath = app.bundleURL?.standardizedFileURL.path,
           (ownerBundlePath == activeBundlePath ||
            ownerBundlePath.hasPrefix(activeBundlePath + "/") ||
            activeBundlePath.hasPrefix(ownerBundlePath + "/")) {
            return true
        }

        if let ownerExecutablePath = ownerApp.executableURL?.standardizedFileURL.path,
           let activeBundlePath = app.bundleURL?.standardizedFileURL.path,
           ownerExecutablePath.hasPrefix(activeBundlePath + "/") {
            return true
        }

        return false
    }

    private func axWindowRect(_ windowEl: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(windowEl, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(windowEl, kAXSizeAttribute as CFString, &sizeValue)
        
        guard posValue != nil, sizeValue != nil else {
            return nil
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
        return cocoaRect
    }
}
