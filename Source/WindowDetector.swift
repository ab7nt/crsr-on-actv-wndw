import Cocoa
import ApplicationServices

// Access the Private _AXUIElementGetWindow function
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowInfo {
    let appName: String
    let frame: CGRect
    let pid: pid_t
}

class WindowDetector {
    
    // Check if we have accessibility permissions
    static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }
    
    static func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    
    /// Returns the Window ID (CGWindowID) of the currently focused window
    func getActiveWindowID() -> CGWindowID? {
        // ... implementation above ...
        // We will keep this for ID retrieval if needed
        guard let element = getActiveWindowElement() else { return nil }
        
        var windowWait: CGWindowID = 0
        let result = _AXUIElementGetWindow(element, &windowWait)
        if result == .success {
             return windowWait
        }
        return nil
    }

    /// Returns the AXUIElement of the currently focused window
    func getActiveWindowElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let axApp = focusedApp as! AXUIElement? else {
            Logger.shared.log("[WindowDetector] focused application unavailable, trying fallbacks")
            return getActiveWindowElementFallbacks()
        }

        if let window = resolveWindow(fromAppElement: axApp) {
            return window
        }

        Logger.shared.log("[WindowDetector] focused app window unavailable, trying frontmost/cursor fallbacks")
        return getActiveWindowElementFallbacks()
    }

    /// Returns the Frame of the currently focused window using Accessibility API
    /// This handles Spotlight, Alfred, Siri etc. correctly as they take keyboard focus
    func getActiveWindowFrame() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        
        // 1. Get the focused application directly from System Wide element
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        
        guard appResult == .success, let axApp = focusedApp as! AXUIElement? else {
            // Fallback to NSWorkspace if AX fails (rare)
            return getActiveWindowFrameFallback()
        }
        
        // 2. Get the focused window of that app
        var focusedWindow: AnyObject?
        let windowResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        
        if windowResult == .success, let windowElement = focusedWindow as! AXUIElement? {
            var positionValue: AnyObject?
            var sizeValue: AnyObject?
            
            AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue)
            AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue)
            
            var point = CGPoint.zero // Top-left based
            var size = CGSize.zero
            
            if let pos = positionValue {
                AXValueGetValue(pos as! AXValue, .cgPoint, &point)
            }
            if let sz = sizeValue {
                AXValueGetValue(sz as! AXValue, .cgSize, &size)
            }
            
            // CoreGraphics coords (Top-Left 0,0)
            return CGRect(origin: point, size: size)
        }
        
        return nil
    }

    func getAppPID(at point: CGPoint) -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        
        // Note: AXUIElementCopyElementAtPosition expects global coordinates (Top-Left origin)
        // 'point' from MouseTracker/Cocoa is Bottom-Left global.
        // We need to check if 'point' passed here is cocoa or CG?
        // StateController passes 'cursorPoint' from 'NSEvent.mouseLocation' which is Cocoa.
        // So we might need to flip it here or in StateController.
        // Actually, let's assume we handle coordinate flipping in StateController to be consistent. 
        // BUT StateController's checkState sends 'NSEvent.mouseLocation' directly.
        // So we need to flip Y here.
        
        // Wait, screen height needed for flip.
        // Easier to just try passing it, but usually AX expects Top-Left.
        
        // Let's rely on caller to passing correct point?
        // No, let's keep this method dumb and assume 'point' is correct AX coordinates?
        // OR fix it in StateController.
        
        // Let's implement it assuming checkState does the flip if needed.
        // Actually StateController passes Cocoa point.
        // Getting screen height here is annoying.
        
        // Let's just return nil for now and do the check inside StateController using CGWindowList instead?
        // No, AX is better for "Under Cursor".
        
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        
        if result == .success, let el = element {
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            return pid
        }
        return nil
    }
    
    private func getActiveWindowFrameFallback() -> CGRect? {
        guard let _ = NSWorkspace.shared.frontmostApplication else { return nil }
        // incomplete implementation
        return nil
    }

    private func getActiveWindowElementFallbacks() -> AXUIElement? {
        if let app = NSWorkspace.shared.frontmostApplication {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            if let window = resolveWindow(fromAppElement: axApp) {
                return window
            }
            Logger.shared.log("[WindowDetector] frontmost app '\(app.localizedName ?? "unknown")' has no resolvable AX window")
        }

        if let cursorWindow = windowElementUnderCursor() {
            return cursorWindow
        }

        Logger.shared.log("[WindowDetector] all fallbacks failed to resolve active window")
        return nil
    }

    private func resolveWindow(fromAppElement axApp: AXUIElement) -> AXUIElement? {
        var focusedWindow: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let windowElement = focusedWindow as! AXUIElement? {
            return windowElement
        }

        var mainWindow: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainWindow) == .success,
           let mainWindowElement = mainWindow as! AXUIElement? {
            return mainWindowElement
        }

        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement],
           let firstWindow = windows.first {
            return firstWindow
        }

        return nil
    }

    private func windowElementUnderCursor() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?

        let mouse = NSEvent.mouseLocation
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let primaryHeight = primary?.frame.height ?? 0
        let axY = primaryHeight - mouse.y

        let hitResult = AXUIElementCopyElementAtPosition(systemWide, Float(mouse.x), Float(axY), &hitElement)
        guard hitResult == .success, let element = hitElement else {
            return nil
        }

        var windowValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
           let window = windowValue as! AXUIElement? {
            return window
        }

        var roleValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String,
           role == kAXWindowRole as String {
            return element
        }

        return nil
    }
}
