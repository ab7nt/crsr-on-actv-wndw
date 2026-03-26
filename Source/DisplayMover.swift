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
            Logger.shared.log("[DisplayMove] no active window element")
            return
        }

        // 1. Validate Screens
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            Logger.shared.log("[DisplayMove] skipped: only one screen")
            return
        }

        guard let currentAXFrame = getWindowAXFrame(windowElement) else {
            Logger.shared.log("[DisplayMove] failed: cannot read current window frame")
            return
        }

        guard let primaryScreen = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else {
            Logger.shared.log("[DisplayMove] failed: cannot detect primary screen")
            return
        }
        let primaryHeight = primaryScreen.frame.height

        // 2. Identify Current Screen from window center
        let windowCenterCocoa = convertAXPointToCocoa(
            CGPoint(x: currentAXFrame.midX, y: currentAXFrame.midY),
            primaryHeight: primaryHeight
        )

        guard let currentScreen = screens.first(where: { NSPointInRect(windowCenterCocoa, $0.frame) }) else {
            Logger.shared.log("[DisplayMove] failed: cannot detect current screen for center=\(windowCenterCocoa)")
            return
        }

        guard let currentIndex = screens.firstIndex(of: currentScreen) else { return }

        // 3. Calculate Target Screen
        var targetIndex = (currentIndex + direction) % screens.count
        if targetIndex < 0 { targetIndex += screens.count }
        let targetScreen = screens[targetIndex]
        Logger.shared.log("[DisplayMove] direction=\(direction), currentIndex=\(currentIndex), targetIndex=\(targetIndex)")
        Logger.shared.log("[DisplayMove] currentAXFrame=\(formatRect(currentAXFrame))")
        Logger.shared.log("[DisplayMove] targetVisible(cocoa)=\(formatRect(targetScreen.visibleFrame))")

        // 4. Calculate target bounds in AX space
        let targetVisibleFrame = targetScreen.visibleFrame
        let targetAXFrame = convertCocoaFrameToAX(targetVisibleFrame, primaryHeight: primaryHeight)

        let targetWidth = targetAXFrame.width
        let targetHeight = targetAXFrame.height

        // 5. Calculate constrained size
        let oldSize = currentAXFrame.size
        let newWidth = min(oldSize.width, targetWidth)
        let newHeight = min(oldSize.height, targetHeight)
        let requestedSize = CGSize(width: newWidth, height: newHeight)
        let sizeChanged = (newWidth != oldSize.width || newHeight != oldSize.height)
        Logger.shared.log("[DisplayMove] targetAXFrame=\(formatRect(targetAXFrame)), requestedSize=\(formatSize(requestedSize)), sizeChanged=\(sizeChanged)")

        // 6. Position first, then size (size is the last operation).
        let desiredX = targetAXFrame.minX + (targetWidth - requestedSize.width) / 2
        let desiredY = targetAXFrame.minY + (targetHeight - requestedSize.height) / 2
        let maxX = targetAXFrame.maxX - requestedSize.width
        let maxY = targetAXFrame.maxY - requestedSize.height

        let clampedX = max(targetAXFrame.minX, min(desiredX, maxX))
        let clampedY = max(targetAXFrame.minY, min(desiredY, maxY))
        let finalPoint = CGPoint(x: clampedX, y: clampedY)
        let positionResult = setWindowPosition(windowElement, point: finalPoint)
        Logger.shared.log("[DisplayMove] set position(final pre-size) finalPoint=\(finalPoint), result=\(positionResult.rawValue)")

        let sizeResult = setWindowSize(windowElement, size: requestedSize)
        Logger.shared.log("[DisplayMove] set size(final) requested=\(formatSize(requestedSize)), result=\(sizeResult.rawValue)")

        var needsDelayedRetry = false
        if let finalAXFrame = getWindowAXFrame(windowElement) {
            Logger.shared.log("[DisplayMove] finalAXFrame=\(formatRect(finalAXFrame))")

            let overflowW = finalAXFrame.width - targetWidth
            let overflowH = finalAXFrame.height - targetHeight
            let outOfBounds = finalAXFrame.minX < targetAXFrame.minX ||
                              finalAXFrame.maxX > targetAXFrame.maxX ||
                              finalAXFrame.minY < targetAXFrame.minY ||
                              finalAXFrame.maxY > targetAXFrame.maxY

            if overflowW > 0.5 || overflowH > 0.5 || outOfBounds {
                Logger.shared.log("[DisplayMove] corrective pass: overflowW=\(String(format: "%.1f", overflowW)), overflowH=\(String(format: "%.1f", overflowH)), outOfBounds=\(outOfBounds)")

                let correctedWidth = min(finalAXFrame.width, targetWidth)
                let correctedHeight = min(finalAXFrame.height, targetHeight)
                let correctedSize = CGSize(width: correctedWidth, height: correctedHeight)
                let correctedX = targetAXFrame.minX + (targetWidth - correctedWidth) / 2
                let correctedY = targetAXFrame.minY + (targetHeight - correctedHeight) / 2
                let correctedPoint = CGPoint(x: correctedX, y: correctedY)
                let correctedPosResult = setWindowPosition(windowElement, point: correctedPoint)
                let correctedSizeResult = setWindowSize(windowElement, size: correctedSize)

                Logger.shared.log("[DisplayMove] corrective set point=\(correctedPoint), posResult=\(correctedPosResult.rawValue), size=\(formatSize(correctedSize)), sizeResult=\(correctedSizeResult.rawValue)")

                if let afterCorrectiveFrame = getWindowAXFrame(windowElement) {
                    Logger.shared.log("[DisplayMove] after corrective finalAXFrame=\(formatRect(afterCorrectiveFrame))")
                    needsDelayedRetry = isOutOfBounds(afterCorrectiveFrame, targetAXFrame: targetAXFrame)
                }
            } else {
                needsDelayedRetry = false
            }
        }

        if needsDelayedRetry {
            Logger.shared.log("[DisplayMove] scheduling multi-step delayed retries")
            scheduleMoveRetries(
                windowElement: windowElement,
                targetAXFrame: targetAXFrame,
                requestedSize: requestedSize
            )
        }

        // 8. Ensure Focus
        AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, true as CFTypeRef)

        // 9. Move Cursor to Window Center
        let centerX = finalPoint.x + (requestedSize.width / 2)
        let centerY = finalPoint.y + (requestedSize.height / 2)
        CGWarpMouseCursorPosition(CGPoint(x: centerX, y: centerY))
    }

    private func convertAXPointToCocoa(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private func convertCocoaFrameToAX(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func getWindowAXFrame(_ windowElement: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue)
        AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue)

        guard let rawPos = positionValue, let rawSize = sizeValue else {
            return nil
        }
        let pos = rawPos as! AXValue
        let sz = rawSize as! AXValue

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pos, .cgPoint, &point)
        AXValueGetValue(sz, .cgSize, &size)

        return CGRect(origin: point, size: size)
    }

    private func setWindowPosition(_ windowElement: AXUIElement, point: CGPoint) -> AXError {
        var mutablePoint = point
        if let valPos = AXValueCreate(.cgPoint, &mutablePoint) {
            return AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, valPos)
        }
        return .failure
    }

    private func setWindowSize(_ windowElement: AXUIElement, size: CGSize) -> AXError {
        var mutableSize = size
        if let valSize = AXValueCreate(.cgSize, &mutableSize) {
            return AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, valSize)
        }
        return .failure
    }

    private func scheduleMoveRetries(windowElement: AXUIElement, targetAXFrame: CGRect, requestedSize: CGSize) {
        let delays: [TimeInterval] = [0.12, 0.30, 0.60, 1.00]
        let retryX = targetAXFrame.minX + (targetAXFrame.width - requestedSize.width) / 2
        let retryY = targetAXFrame.minY + (targetAXFrame.height - requestedSize.height) / 2
        let retryPoint = CGPoint(x: retryX, y: retryY)

        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                guard let frameBefore = self.getWindowAXFrame(windowElement) else { return }
                if !self.isOutOfBounds(frameBefore, targetAXFrame: targetAXFrame) {
                    Logger.shared.log("[DisplayMove] retry#\(index + 1) skipped: already in bounds")
                    return
                }

                // Retry focuses on position, because size is usually already applied after unzoom.
                let retryPosResult = self.setWindowPosition(windowElement, point: retryPoint)
                Logger.shared.log("[DisplayMove] retry#\(index + 1) set point=\(retryPoint), posResult=\(retryPosResult.rawValue)")

                if frameBefore.width - targetAXFrame.width > 0.5 || frameBefore.height - targetAXFrame.height > 0.5 {
                    let retrySize = CGSize(
                        width: min(frameBefore.width, targetAXFrame.width),
                        height: min(frameBefore.height, targetAXFrame.height)
                    )
                    let retrySizeResult = self.setWindowSize(windowElement, size: retrySize)
                    Logger.shared.log("[DisplayMove] retry#\(index + 1) set size=\(self.formatSize(retrySize)), sizeResult=\(retrySizeResult.rawValue)")
                }

                if let afterRetryFrame = self.getWindowAXFrame(windowElement) {
                    Logger.shared.log("[DisplayMove] retry#\(index + 1) finalAXFrame=\(self.formatRect(afterRetryFrame))")
                }
            }
        }
    }

    private func isOutOfBounds(_ frame: CGRect, targetAXFrame: CGRect) -> Bool {
        frame.minX < targetAXFrame.minX ||
        frame.maxX > targetAXFrame.maxX ||
        frame.minY < targetAXFrame.minY ||
        frame.maxY > targetAXFrame.maxY
    }

    private func formatRect(_ rect: CGRect) -> String {
        String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    private func formatSize(_ size: CGSize) -> String {
        String(format: "w=%.1f h=%.1f", size.width, size.height)
    }
}
