import Cocoa
import ApplicationServices

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
    
    private func getActiveWindowFrameFallback() -> CGRect? {
        guard let activeApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = activeApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var focusedWindow: AnyObject?
        // ... (previous logic)
        return nil
    }

}
