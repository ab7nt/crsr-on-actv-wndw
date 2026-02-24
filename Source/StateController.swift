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
    private var finderDeleteMonitorGlobal: Any?
    private var finderDeleteMonitorLocal: Any?
    private var didShowFinderAutomationAlert = false
    private var finderDeleteWasActiveBeforeSuspend = false
    
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
    
    var isFinderDeleteEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "EnableFinderDelete") }
        set {
            UserDefaults.standard.set(newValue, forKey: "EnableFinderDelete")
            updateFinderDeleteMonitoring()
        }
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

    func setFinderDeleteEnabledFromUser(_ enabled: Bool) -> Bool {
        guard enabled else {
            isFinderDeleteEnabled = false
            return false
        }

        guard checkFinderAutomationAccess() else {
            presentFinderAutomationAlertOnce()
            return false
        }

        isFinderDeleteEnabled = true
        return true
    }

    private func ensureAccessibilityPermissionRequested() -> Bool {
        if WindowDetector.isAccessibilityTrusted() {
            return true
        }

        WindowDetector.requestPermissions()
        presentAccessibilityPermissionAlert()
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
        if UserDefaults.standard.object(forKey: "EnableFinderDelete") == nil {
            UserDefaults.standard.set(false, forKey: "EnableFinderDelete")
        }
        
        Logger.shared.log("App Started. Check Permissions: \(WindowDetector.isAccessibilityTrusted())")
        self.mouseTracker = MouseTracker()
        self.windowDetector = WindowDetector()
        self.overlay = OverlayIndicator()
        
        self.mouseTracker.delegate = self
        
        setupClickMonitoring()
        setupSpaceObserver()
        setupGestures()
        setupTrackpadGestures()
        updateFinderDeleteMonitoring()
    }
    
    deinit {
        swipeTracker = nil // Stop monitoring
        TrackpadListener.shared.stop()
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = finderDeleteMonitorGlobal {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = finderDeleteMonitorLocal {
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

    // MARK: - Finder Delete (Global)
    
    private func updateFinderDeleteMonitoring() {
        guard !isSuspended else {
            if let monitor = finderDeleteMonitorGlobal {
                NSEvent.removeMonitor(monitor)
                finderDeleteMonitorGlobal = nil
            }
            if let monitor = finderDeleteMonitorLocal {
                NSEvent.removeMonitor(monitor)
                finderDeleteMonitorLocal = nil
            }
            return
        }

        if isFinderDeleteEnabled {
            if finderDeleteMonitorGlobal == nil {
                finderDeleteMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handleFinderDeleteKey(event, isLocal: false)
                }
            }
            if finderDeleteMonitorLocal == nil {
                finderDeleteMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handleFinderDeleteKey(event, isLocal: true)
                    return event
                }
            }
        } else {
            if let monitor = finderDeleteMonitorGlobal {
                NSEvent.removeMonitor(monitor)
                finderDeleteMonitorGlobal = nil
            }
            if let monitor = finderDeleteMonitorLocal {
                NSEvent.removeMonitor(monitor)
                finderDeleteMonitorLocal = nil
            }
        }
    }
    
    private func handleFinderDeleteKey(_ event: NSEvent, isLocal: Bool) {
        guard !isSuspended else { return }
        guard isDeleteKey(event), !event.modifierFlags.contains(.command) else { return }
        if isLocal && shouldIgnoreForTextInput() {
            return
        }
        
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmost != "com.apple.finder" && frontmost != Bundle.main.bundleIdentifier {
            return
        }
        
        trashFinderSelection()
    }
    
    private func isDeleteKey(_ event: NSEvent) -> Bool {
        return event.keyCode == 51 || event.keyCode == 117
    }
    
    private func shouldIgnoreForTextInput() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView {
            return textView.isFieldEditor
        }
        if responder is NSTextField {
            return true
        }
        return false
    }
    
    private func trashFinderSelection() {
        let urls = fetchFinderSelectionURLs()
        guard !urls.isEmpty else { return }
        
        for url in urls {
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            } catch {
                Logger.shared.log("Failed to trash Finder item: \(url.path). Error: \(error)")
            }
        }
    }
    
    private func fetchFinderSelectionURLs() -> [URL] {
        let scriptSource = """
        tell application "Finder"
            set sel to selection as alias list
            set out to {}
            repeat with a in sel
                set end of out to POSIX path of a
            end repeat
        end tell
        return out
        """
        
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: scriptSource)
        let result: NSAppleEventDescriptor? = runAppleScriptOnMain {
            script?.executeAndReturnError(&errorInfo)
        }
        
        guard let resultUnwrapped = result else {
            if let err = errorInfo {
                Logger.shared.log("AppleScript error getting Finder selection: \(err)")
                if let code = err[NSAppleScript.errorNumber] as? Int, code == -1743 {
                    presentFinderAutomationAlertOnce()
                }
            }
            return []
        }
        
        var urls: [URL] = []
        let count = resultUnwrapped.numberOfItems
        if count == 0 {
            Logger.shared.log("Finder selection is empty.")
            return []
        }
        
        for index in 1...count {
            guard let item = resultUnwrapped.atIndex(index),
                  let path = item.stringValue else { continue }
            urls.append(URL(fileURLWithPath: path))
        }
        
        return urls
    }

    func checkFinderAutomationAccess() -> Bool {
        let scriptSource = "tell application \"Finder\" to get name of startup disk"
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: scriptSource)
        _ = runAppleScriptOnMain {
            script?.executeAndReturnError(&errorInfo)
        }
        if let err = errorInfo,
           let code = err[NSAppleScript.errorNumber] as? Int,
           code == -1743 {
            return false
        }
        return true
    }

    private func runAppleScriptOnMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync {
            work()
        }
    }

    private func presentAccessibilityPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Needed"
            alert.informativeText = "Enable access in System Settings → Privacy & Security → Accessibility, then re-enable this feature."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    private func presentFinderAutomationAlertOnce() {
        guard !didShowFinderAutomationAlert else { return }
        didShowFinderAutomationAlert = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Finder Automation Permission Needed"
            alert.informativeText = "Enable access in System Settings → Privacy & Security → Automation, then allow this app to control Finder."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }
    
    // MARK: - Suspension Logic
    
    func suspendForDialog() {
        Logger.shared.log("Suspending for Dialog...")
        isSuspended = true
        finderDeleteWasActiveBeforeSuspend = isFinderDeleteEnabled
        TrackpadListener.shared.stop()
        mouseTracker.stopTracking()
        swipeTracker?.stop()
        stopClickMonitoring()
        updateFinderDeleteMonitoring()
        overlay.hide(animated: false)
    }
    
    func resumeFromDialog() {
        Logger.shared.log("Resuming from Dialog...")
        isSuspended = false
        updateTrackpadListenerState()
        mouseTracker.startTracking()
        swipeTracker?.start()
        startClickMonitoring()
        if finderDeleteWasActiveBeforeSuspend {
            updateFinderDeleteMonitoring()
            finderDeleteWasActiveBeforeSuspend = false
        }
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
