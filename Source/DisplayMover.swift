import Cocoa
import ApplicationServices

class DisplayMover {
    static let shared = DisplayMover()
    
    // Move window between physical displays (Monitors)
    
    func moveActiveWindowToNextDisplay() {
        moveActiveWindow(direction: 1)
    }
    
    func moveActiveWindowToPrevDisplay() {
        moveActiveWindow(direction: -1)
    }
    
    private func moveActiveWindow(direction: Int) {
        guard let windowElement = WindowDetector().getActiveWindowElement() else {
            return
        }
        
        // 1. Get Current Window Frame
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        
        AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue)
        AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue)
        
        var point = CGPoint.zero
        var size = CGSize.zero
        
        if let pos = positionValue { AXValueGetValue(pos as! AXValue, .cgPoint, &point) }
        if let sz = sizeValue { AXValueGetValue(sz as! AXValue, .cgSize, &size) }
        
        // 2. Validate Screens
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            return
        }
        
        // 3. Identify Current Screen
        let currentFrame = CGRect(origin: point, size: size)
        
        // Convert to Cocoa Coordinates for Screen Detection
        let primaryHeight = screens.first?.frame.height ?? 0
        let windowCenterY_Cocoa = primaryHeight - (currentFrame.midY)
        let windowCenterX_Cocoa = currentFrame.midX
        let windowCenterCocoa = CGPoint(x: windowCenterX_Cocoa, y: windowCenterY_Cocoa)
        
        guard let currentScreen = screens.first(where: { NSPointInRect(windowCenterCocoa, $0.frame) }) else {
            return
        }
        
        guard let currentIndex = screens.firstIndex(of: currentScreen) else { return }
        
        // 4. Calculate Target Screen
        var targetIndex = (currentIndex + direction) % screens.count
        if targetIndex < 0 { targetIndex += screens.count }
        
        let targetScreen = screens[targetIndex]
        
        // 5. Calculate New Frame
        let targetVisibleFrame = targetScreen.visibleFrame
        let targetAXFrame = convertCocoaFrameToAX(targetVisibleFrame)
        
        let targetWidth = targetAXFrame.width
        let targetHeight = targetAXFrame.height
        
        // 6. Calculate Constrained Size
        let oldSize = size
        let newWidth = min(oldSize.width, targetWidth)
        let newHeight = min(oldSize.height, targetHeight)
        var finalSize = CGSize(width: newWidth, height: newHeight)
        
        let sizeChanged = (newWidth != oldSize.width || newHeight != oldSize.height)
        
        // 7. Calculate New Origin (Center based on NEW size)
        let newX = targetAXFrame.minX + (targetWidth - newWidth) / 2
        let newY = targetAXFrame.minY + (targetHeight - newHeight) / 2
        var newPoint = CGPoint(x: newX, y: newY)
        
        // 8. Move to Position
        // Move first so the window is on the correct screen
        if let valPos = AXValueCreate(.cgPoint, &newPoint) {
           _ = AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, valPos)
        }
        
        // 9. Resize (if needed)
        if sizeChanged {
            if let valSize = AXValueCreate(.cgSize, &finalSize) {
                _ = AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, valSize)
            }
            
            // Re-apply Position (Fix layout shifts after resize)
            if let valPos = AXValueCreate(.cgPoint, &newPoint) {
                _ = AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, valPos)
            }
        }
        
        // 10. Ensure Focus
        AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, true as CFTypeRef)
        
        // 11. Move Cursor to Window Center
        let centerX = newPoint.x + (finalSize.width / 2)
        let centerY = newPoint.y + (finalSize.height / 2)
        CGWarpMouseCursorPosition(CGPoint(x: centerX, y: centerY))
    }
    
    private func convertCocoaFrameToAX(_ frame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        let h = primary.frame.height
        return CGRect(x: frame.origin.x, y: h - (frame.origin.y + frame.height), width: frame.width, height: frame.height)
    }
}
