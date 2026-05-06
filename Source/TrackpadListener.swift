import Cocoa

typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var normalizedPosition: MTPoint
    var devicePosition: MTPoint
    var zero2: Int32
    var zero3: Int32
    var unknown: Float
}

class TrackpadListener {
    static let shared = TrackpadListener()
    
    var onThreeFingerTap: (() -> Void)?
    var onThreeFingerDoubleTap: (() -> Void)?
    var isEnabled = false
    
    // Double Tap Logic
    private var pendingSingleTapWorkItem: DispatchWorkItem?
    private let doubleTapThreshold: TimeInterval = 0.3
    private var lastTapTimestamp: TimeInterval = 0
    
    private var isRunning = false
    private var devices: [UnsafeMutableRawPointer] = []
    
    // Tap Detection State
    private var lastFingerCount = 0
    private var touchActiveStartTs: TimeInterval?
    private var firstThreeFingerTs: TimeInterval?
    private var maxFingersSeenInTouch = 0
    private var initialThreeFingerCentroid: CGPoint?
    private var lastThreeFingerCentroid: CGPoint?
    private var accumulatedThreeFingerMovement: CGFloat = 0
    private var validThreeFingerCentroidFrames = 0
    private var didMoveTooMuchForTap = false
    
    // Tunables
    private let maxTapDuration: TimeInterval = 0.35
    private let maxTapMovement: CGFloat = 0.035
    private let maxTapFrameMovement: CGFloat = 0.025
    private let maxTapPathMovement: CGFloat = 0.07
    
    // Paths and Framework Handles
    private var frameworkHandle: UnsafeMutableRawPointer?
    
    // Function Pointers
    private var mtDeviceCreateList: (@convention(c) () -> Unmanaged<CFArray>)?
    private var mtRegisterContactFrameCallback: (@convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void)?
    private var mtDeviceStart: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void)?
    private var mtDeviceStop: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void)?
    
    init() {
        loadFramework()
    }
    
    // MARK: - Framework Loading
    
    private func loadFramework() {
        let paths = [
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport",
            "MultitouchSupport.framework/MultitouchSupport"
        ]
        
        for path in paths {
            if let handle = dlopen(path, RTLD_LAZY) {
                self.frameworkHandle = handle
                // success
                break
            }
        }
        
        guard let handle = self.frameworkHandle else {
            Logger.shared.log("[TrackpadListener] Failed to load MultitouchSupport framework from any path")
            return
        }
        
        // Resolve Symbols
        if let sym = dlsym(handle, "MTDeviceCreateList") {
            mtDeviceCreateList = unsafeBitCast(sym, to: (@convention(c) () -> Unmanaged<CFArray>).self)
        } else {
            Logger.shared.log("[TrackpadListener] Failed to link MTDeviceCreateList")
        }
        
        if let sym = dlsym(handle, "MTRegisterContactFrameCallback") {
            mtRegisterContactFrameCallback = unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void).self)
        }
        
        if let sym = dlsym(handle, "MTDeviceStart") {
            mtDeviceStart = unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
        }
        
        if let sym = dlsym(handle, "MTDeviceStop") {
            mtDeviceStop = unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
        }
    }
    
    // MARK: - Public Control
    
    func start() {
        guard !isRunning else { return }
        
        guard let createList = mtDeviceCreateList else {
            Logger.shared.log("[TrackpadListener] Cannot start: MTDeviceCreateList is nil")
            return
        }
        
        let unmanagedDevices = createList()
        let deviceArray = unmanagedDevices.takeRetainedValue()
        let count = CFArrayGetCount(deviceArray)
        
        Logger.shared.log("[TrackpadListener] MTDeviceCreateList found \(count) devices")
        
        self.devices.removeAll()
        
        for i in 0..<count {
            if let rawDevice = CFArrayGetValueAtIndex(deviceArray, i) {
                let device = UnsafeMutableRawPointer(mutating: rawDevice)
                self.devices.append(device)
                registerCallback(for: device)
                mtDeviceStart?(device, 0)
            }
        }
        
        isRunning = true
    }
    
    func stop() {
        guard isRunning else { return }
        for device in devices {
            mtDeviceStop?(device, 0)
        }
        devices.removeAll()
        isRunning = false
    }
    
    // MARK: - Callback Handling: UnsafeMutableRawPointer
    
    private func registerCallback(for device: UnsafeMutableRawPointer) {
        mtRegisterContactFrameCallback?(device, globalContactCallback)
    }
}

private func globalContactCallback(device: UnsafeMutableRawPointer, frameData: UnsafeMutableRawPointer?, numFingers: Int32, timestamp: Double, frameID: Int32) {
    TrackpadListener.shared.handleCallback(fingers: Int(numFingers), timestamp: timestamp, frameData: frameData)
}

extension TrackpadListener {
    func handleCallback(fingers: Int, timestamp: Double, frameData: UnsafeMutableRawPointer? = nil) {
        guard isEnabled else { return }
        
        // Prefer the provided MT timestamp if it looks sane; fall back to wall clock.
        let nowTs: TimeInterval = (timestamp > 0) ? timestamp : Date().timeIntervalSince1970
        
        // Start of a touch sequence (first finger down)
        if lastFingerCount == 0, fingers > 0 {
            touchActiveStartTs = nowTs
            firstThreeFingerTs = nil
            maxFingersSeenInTouch = fingers
            initialThreeFingerCentroid = nil
            lastThreeFingerCentroid = nil
            accumulatedThreeFingerMovement = 0
            validThreeFingerCentroidFrames = 0
            didMoveTooMuchForTap = false
        }
        
        // Update max fingers observed in this touch sequence
        if fingers > 0 {
            maxFingersSeenInTouch = max(maxFingersSeenInTouch, fingers)
        }
        
        // First moment we reached 3 fingers in this touch sequence
        if fingers == 3, firstThreeFingerTs == nil {
            firstThreeFingerTs = nowTs
            if let centroid = threeFingerCentroid(from: frameData, fingers: fingers) {
                initialThreeFingerCentroid = centroid
                lastThreeFingerCentroid = centroid
                validThreeFingerCentroidFrames += 1
            }
        }
        
        if fingers == 3 {
            if let currentCentroid = threeFingerCentroid(from: frameData, fingers: fingers) {
                validThreeFingerCentroidFrames += 1

                if initialThreeFingerCentroid == nil {
                    initialThreeFingerCentroid = currentCentroid
                    lastThreeFingerCentroid = currentCentroid
                }

                if let initialThreeFingerCentroid {
                    let dx = currentCentroid.x - initialThreeFingerCentroid.x
                    let dy = currentCentroid.y - initialThreeFingerCentroid.y
                    if hypot(dx, dy) > maxTapMovement {
                        didMoveTooMuchForTap = true
                    }
                }

                if let lastThreeFingerCentroid {
                    let frameMovement = hypot(
                        currentCentroid.x - lastThreeFingerCentroid.x,
                        currentCentroid.y - lastThreeFingerCentroid.y
                    )
                    accumulatedThreeFingerMovement += frameMovement

                    if frameMovement > maxTapFrameMovement || accumulatedThreeFingerMovement > maxTapPathMovement {
                        didMoveTooMuchForTap = true
                    }
                }

                lastThreeFingerCentroid = currentCentroid
            }
        }
        
        // End of touch sequence (all fingers up)
        if fingers == 0, lastFingerCount > 0 {
            let first3 = firstThreeFingerTs
            
            if let first3 {
                let threeToRelease = nowTs - first3
                
                // Consider it a 3-finger tap if we reached exactly 3 fingers
                // and released soon after that moment.
                if maxFingersSeenInTouch == 3, threeToRelease <= maxTapDuration, !didMoveTooMuchForTap {
                    let validCentroidFrames = validThreeFingerCentroidFrames
                    DispatchQueue.main.async {
                        // If double tap is not configured, fire single tap immediately
                        guard self.onThreeFingerDoubleTap != nil else {
                            self.onThreeFingerTap?()
                            return
                        }

                        guard validCentroidFrames > 0 else {
                            self.lastTapTimestamp = 0
                            return
                        }

                        // Check for double tap
                        let now = Date().timeIntervalSince1970
                        let sinceLastTap = now - self.lastTapTimestamp
                        if sinceLastTap < self.doubleTapThreshold {
                            // Double Tap detected!
                            self.pendingSingleTapWorkItem?.cancel()
                            self.pendingSingleTapWorkItem = nil
                            self.onThreeFingerDoubleTap?()
                            self.lastTapTimestamp = 0 // Reset
                        } else {
                            // Potentially a single tap. Schedule it.
                            self.lastTapTimestamp = now
                            
                            let workItem = DispatchWorkItem { [weak self] in
                                self?.onThreeFingerTap?()
                            }
                            self.pendingSingleTapWorkItem = workItem
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + self.doubleTapThreshold, execute: workItem)
                        }
                    }
                }
            }
            
            // Reset touch sequence state
            touchActiveStartTs = nil
            firstThreeFingerTs = nil
            maxFingersSeenInTouch = 0
            initialThreeFingerCentroid = nil
            lastThreeFingerCentroid = nil
            accumulatedThreeFingerMovement = 0
            validThreeFingerCentroidFrames = 0
            didMoveTooMuchForTap = false
        }
        
        lastFingerCount = fingers
    }
    
    private func threeFingerCentroid(from frameData: UnsafeMutableRawPointer?, fingers: Int) -> CGPoint? {
        guard fingers == 3, let frameData else { return nil }
        
        let contacts = frameData.assumingMemoryBound(to: MTContact.self)
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        
        for index in 0..<fingers {
            guard let point = normalizedPoint(for: contacts[index]) else {
                return nil
            }

            sumX += point.x
            sumY += point.y
        }
        
        return CGPoint(x: sumX / CGFloat(fingers), y: sumY / CGFloat(fingers))
    }

    private func normalizedPoint(for contact: MTContact) -> CGPoint? {
        let candidates = [
            contact.normalizedPosition,
            contact.normalizedVector.position
        ]

        for position in candidates {
            let x = CGFloat(position.x)
            let y = CGFloat(position.y)

            if x.isFinite, y.isFinite, (-0.1...1.1).contains(x), (-0.1...1.1).contains(y) {
                return CGPoint(x: x, y: y)
            }
        }

        return nil
    }
}
