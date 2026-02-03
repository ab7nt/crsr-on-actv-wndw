import Cocoa
import QuartzCore

class OverlayIndicator: NSWindow {
    
    // UI Constants
    private let size: CGFloat = 20.0 
    
    // Offsets
    private let lockedOffset = CGPoint(x: 3, y: -6)
    private let unlockedOffset = CGPoint(x: 5, y: -6) // Shift right when open
    
    private var imageView: NSImageView!
    private(set) var isLocked: Bool = true
    private var lastCursorLocation: CGPoint = .zero
    
    // Public getter for compatibility if needed, though private(set) handles read access
    var isLockedState: Bool {
        return isLocked
    }
    
    init() {
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        
        super.init(contentRect: frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        
        setupContentView()
    }
    
    private func setupContentView() {
        // Squish the height a bit (size * 0.8) to make it look less tall
        let viewRect = NSRect(x: 0, y: size * 0.1, width: size, height: size * 0.8)
        imageView = NSImageView(frame: viewRect)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        
        // Fix for stretched icon: disable scaling (let pointSize dictate size) and center it
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        
        self.contentView = imageView
        self.contentView?.wantsLayer = true
        
        // Ensure anchor point is center for animations
        imageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageView.layer?.position = CGPoint(x: size/2, y: size/2)
        
        // VISUAL SQUASH: Apply a scale transform to the layer itself to squash vertically
        // This is the only way to distort the vector symbol
        imageView.layer?.transform = CATransform3DMakeScale(1.0, 0.75, 1.0)
        
        // Default state
        setLocked(true)
    }
    
    func setLocked(_ locked: Bool) {
        self.isLocked = locked
        let name = locked ? "lock.fill" : "lock.open.fill"
        imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        // Цвета: 0.8 alpha (чуть поярче, чтобы было видно)
        imageView.contentTintColor = locked 
            ? NSColor.systemRed.withAlphaComponent(0.8) 
            : NSColor.systemGreen.withAlphaComponent(0.8)
            
        // Force update position to apply jump immediately if cursor is stationary
        if lastCursorLocation != .zero {
            updatePosition(to: lastCursorLocation)
        }
    }
    
    func updatePosition(to cursorLocation: CGPoint) {
        self.lastCursorLocation = cursorLocation
        
        // Choose offset based on state
        let currentOffset = isLocked ? lockedOffset : unlockedOffset
        
        // Apply offset. Note: y is up in Cocoa origin, but visual offset is down.
        // cursorLocation is Bottom-Left based.
        // We want to move RIGHT (+) and DOWN (-).
        let newOrigin = CGPoint(x: cursorLocation.x + currentOffset.x, y: cursorLocation.y + currentOffset.y - size) 
        // Note: - size because window origin is its bottom-left, so to place TOP of window at cursor, we need to shift down by height.
        
        self.setFrameOrigin(newOrigin)
    }
    
    func show() {
        // Always reset alpha, in case we caught it in the middle of fading out
        self.alphaValue = 1.0
        if !self.isVisible {
            self.orderFront(nil)
        }
    }
    
    func hide(animated: Bool = false) {
        if !animated {
            self.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.animator().alphaValue = 0.0
            } completionHandler: {
                self.orderOut(nil)
                self.alphaValue = 1.0 // Reset for next show
            }
        }
    }
}
// IndicatorView removed as we use NSImageView directly

