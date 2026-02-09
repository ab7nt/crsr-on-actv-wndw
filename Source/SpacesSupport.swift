import Cocoa

// MARK: - Private CGS API Definitions

// CoreGraphics Service Connect
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

// Spaces
@_silgen_name("CGSCopySpaces")
func CGSCopySpaces(_ cid: Int32, _ mask: Int32) -> CFArray

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: Int32) -> Int

@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ cid: Int32, _ windows: NSArray, _ spaces: NSArray) -> Int32

@_silgen_name("CGSRemoveWindowsFromSpaces")
func CGSRemoveWindowsFromSpaces(_ cid: Int32, _ windows: NSArray, _ spaces: NSArray) -> Int32

// Window
@_silgen_name("CGSGetWindowOwner")
func CGSGetWindowOwner(_ cid: Int32, _ wid: UInt32, _ connection: UnsafeMutablePointer<Int32>) -> Int32

// Constants
let kCGSSpaceCurrent: Int32 = 5
let kCGSSpaceAll: Int32 = 7

class SpacesSupport {
    static let shared = SpacesSupport()
    
    private let cid: Int32
    
    init() {
        self.cid = CGSMainConnectionID()
    }
    
    func getActiveSpaceID() -> Int {
        return CGSGetActiveSpace(cid)
    }
    
    func getAllSpaces() -> [Int] {
        // Safe bridging from CFArray -> NSArray -> [Int]
        guard let spaceInfo = CGSCopySpaces(cid, kCGSSpaceAll) as? [NSNumber] else {
            return []
        }
        // macOS CGS API often returns spaces in reverse order (e.g. [Newest, ..., Desktop 1])
        // We reverse it to match visual order [Desktop 1, ..., Newest]
        return spaceInfo.map { $0.intValue }.reversed()
    }
    
    func moveWindow(_ windowID: CGWindowID, toSpace spaceID: Int) -> Bool {
        let windows = [NSNumber(value: windowID)] as NSArray
        let spaces = [NSNumber(value: spaceID)] as NSArray
        let currentSpace = [NSNumber(value: getActiveSpaceID())] as NSArray
        
        Logger.shared.log("[Spaces] Executing CGS Move: Win:\(windowID) To:\(spaceID) From:\(getActiveSpaceID())")
        
        let errAdd = CGSAddWindowsToSpaces(cid, windows, spaces)
        let errRem = CGSRemoveWindowsFromSpaces(cid, windows, currentSpace)
        
        if errAdd != 0 || errRem != 0 {
            Logger.shared.log("[Spaces] ❌ CGS Error. Add: \(errAdd), Rem: \(errRem). (1000=Perms, 1001=Invalid)")
            return false
        } else {
            Logger.shared.log("[Spaces] ✅ CGS reported success.")
            return true
        }
    }
    
    // MARK: - Legacy / Simulation Fallback
    
    enum Direction {
        case next
        case previous
    }
    
    func simulateMove(windowFrame: CGRect, direction: Direction) {
        // Fallback: Click & Hold -> Switch Space -> Release
        Logger.shared.log("[Spaces] ⚠️ Using Fallback: Simulation (Control + Arrow)")
        
        let source = CGEventSource(stateID: .hidSystemState)
        
        // 1. Calculate safe click point (Top-Center of window - Title Bar area)
        // Assume 'windowFrame' passed here is in Global Display Coordinates (Top-Left 0,0)
        
        let clickPoint = CGPoint(x: windowFrame.midX, y: windowFrame.minY + 10) // 10px down from top
        
        // 2. Move Mouse & Click Down
        guard let mouseMove = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: clickPoint, mouseButton: .left),
              let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left) else { return }
        
        mouseMove.post(tap: .cghidEventTap)
        usleep(50000) // 50ms wait
        mouseDown.post(tap: .cghidEventTap)
        usleep(50000)
        
        // 3. Trigger Space Switch (Control + Left/Right)
        // Key Codes: Left Arrow = 123, Right Arrow = 124
        let keyCode: CGKeyCode = (direction == .previous) ? 123 : 124
        
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            // Cleanup mouse if keys fail
            mouseUp.post(tap: .cghidEventTap)
            return
        }
        
        // Set Control Modifier
        keyDown.flags = .maskControl
        keyUp.flags = .maskControl
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        
        // 4. Wait / Release Mouse
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            // Release after animation starts/finishes
            mouseUp.post(tap: .cghidEventTap)
            Logger.shared.log("[Spaces] Simulation sequence matched.")
        }
    }
    
    func moveWindowToNextSpace(_ windowID: CGWindowID, frame: CGRect?) {
        let allSpaces = getAllSpaces()
        let current = getActiveSpaceID()
        
        Logger.shared.log("[Spaces] Current: \(current), All: \(allSpaces)")
        
        guard let currentIndex = allSpaces.firstIndex(of: current) else { 
            Logger.shared.log("[Spaces] ❌ Current space ID not found in list!")
            return 
        }
        
        if currentIndex < allSpaces.count - 1 {
            let nextSpace = allSpaces[currentIndex + 1]
            if !moveWindow(windowID, toSpace: nextSpace) {
                // CGS Failed. Try fallback if frame available.
                if let f = frame { simulateMove(windowFrame: f, direction: .next) }
            } else {
                Logger.shared.log("[Spaces] -> Moving window \(windowID) to NEXT space \(nextSpace)")
            }
        } else {
            Logger.shared.log("[Spaces] ⚠️ Already at last space")
        }
    }
    
    func moveWindowToPreviousSpace(_ windowID: CGWindowID, frame: CGRect?) {
        let allSpaces = getAllSpaces()
        let current = getActiveSpaceID()
        
        Logger.shared.log("[Spaces] Current: \(current), All: \(allSpaces)")
        
        guard let currentIndex = allSpaces.firstIndex(of: current) else { 
            Logger.shared.log("[Spaces] ❌ Current space ID not found in list!")
            return 
        }
        
        if currentIndex > 0 {
            let prevSpace = allSpaces[currentIndex - 1]
            if !moveWindow(windowID, toSpace: prevSpace) {
                // CGS Failed. Try fallback if frame available.
                if let f = frame { simulateMove(windowFrame: f, direction: .previous) }
            } else {
                 Logger.shared.log("[Spaces] -> Moving window \(windowID) to PREV space \(prevSpace)")
            }
        } else {
            Logger.shared.log("[Spaces] ⚠️ Already at first space")
        }
    }
}
