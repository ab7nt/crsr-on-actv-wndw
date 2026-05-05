import Cocoa
import ApplicationServices

class DisplayMover {
    static let shared = DisplayMover()
    private typealias WindowCoverage = (width: CGFloat, height: CGFloat, area: CGFloat)
    private typealias OversizeSample = (widthOverflow: CGFloat, heightOverflow: CGFloat)
    private let coverageInitialCheckDelay: TimeInterval = 0.10
    private let coverageRecheckDelay: TimeInterval = 0.08
    private let maxLowCoverageChecksBeforeZoom = 3
    
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

        // 4. Calculate target bounds in AX space
        let currentVisibleAXFrame = convertCocoaFrameToAX(currentScreen.visibleFrame, primaryHeight: primaryHeight)
        let targetVisibleFrame = targetScreen.visibleFrame
        let targetAXFrame = convertCocoaFrameToAX(targetVisibleFrame, primaryHeight: primaryHeight)

        let targetWidth = targetAXFrame.width
        let targetHeight = targetAXFrame.height

        // 5. Calculate constrained size
        let isZoomedLike = isZoomedLikeWindow(currentAXFrame, visibleAXFrame: currentVisibleAXFrame)
        let oldSize = currentAXFrame.size
        let newWidth = min(oldSize.width, targetWidth)
        let newHeight = min(oldSize.height, targetHeight)
        let requestedSize = CGSize(width: newWidth, height: newHeight)
        let sizeChanged = (requestedSize.width != oldSize.width || requestedSize.height != oldSize.height)

        if isZoomedLike {
            let sourceCoverage = screenCoverage(currentAXFrame, visibleAXFrame: currentVisibleAXFrame)
            moveZoomedLikeWindowAndPreserveCoverage(
                windowElement: windowElement,
                targetAXFrame: targetAXFrame,
                requestedSize: requestedSize,
                sourceCoverage: sourceCoverage
            )
            return
        }

        // 6. Position first, then size (size is the last operation).
        let desiredX = isZoomedLike ? targetAXFrame.minX : targetAXFrame.minX + (targetWidth - requestedSize.width) / 2
        let desiredY = isZoomedLike ? targetAXFrame.minY : targetAXFrame.minY + (targetHeight - requestedSize.height) / 2
        let maxX = targetAXFrame.maxX - requestedSize.width
        let maxY = targetAXFrame.maxY - requestedSize.height

        let clampedX = max(targetAXFrame.minX, min(desiredX, maxX))
        let clampedY = max(targetAXFrame.minY, min(desiredY, maxY))
        let finalPoint = CGPoint(x: clampedX, y: clampedY)
        _ = setWindowPosition(windowElement, point: finalPoint)

        if sizeChanged || !isZoomedLike {
            _ = setWindowSize(windowElement, size: requestedSize)
        }

        var needsDelayedRetry = false
        if let finalAXFrame = getWindowAXFrame(windowElement) {
            let overflowW = finalAXFrame.width - targetWidth
            let overflowH = finalAXFrame.height - targetHeight
            let outOfBounds = finalAXFrame.minX < targetAXFrame.minX ||
                              finalAXFrame.maxX > targetAXFrame.maxX ||
                              finalAXFrame.minY < targetAXFrame.minY ||
                              finalAXFrame.maxY > targetAXFrame.maxY

            if overflowW > 0.5 || overflowH > 0.5 || outOfBounds {
                let correctedWidth = min(finalAXFrame.width, targetWidth)
                let correctedHeight = min(finalAXFrame.height, targetHeight)
                let correctedSize = CGSize(width: correctedWidth, height: correctedHeight)
                let correctedX = targetAXFrame.minX + (targetWidth - correctedWidth) / 2
                let correctedY = targetAXFrame.minY + (targetHeight - correctedHeight) / 2
                let correctedPoint = CGPoint(x: correctedX, y: correctedY)
                _ = setWindowPosition(windowElement, point: correctedPoint)
                _ = setWindowSize(windowElement, size: correctedSize)

                if let afterCorrectiveFrame = getWindowAXFrame(windowElement) {
                    needsDelayedRetry = isOutOfBounds(afterCorrectiveFrame, targetAXFrame: targetAXFrame)
                }
            } else {
                needsDelayedRetry = false
            }
        }

        if needsDelayedRetry {
            scheduleMoveRetries(
                windowElement: windowElement,
                targetAXFrame: targetAXFrame,
                requestedSize: requestedSize,
                shouldRestoreZoomedSize: isZoomedLike
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

    private func pressWindowMenuItem(for windowElement: AXUIElement, itemTitles: [String]) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(windowElement, &pid) == .success, pid != 0 else {
            Logger.shared.log("[DisplayMove] window menu unavailable: cannot resolve window pid")
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        var menuBarValue: AnyObject?
        let menuBarResult = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue)
        guard menuBarResult == .success, let menuBar = menuBarValue as! AXUIElement? else {
            Logger.shared.log("[DisplayMove] window menu unavailable: menu bar result=\(menuBarResult.rawValue)")
            return false
        }

        guard let windowMenu = menuBarItem(in: menuBar, titles: ["Window", "Окно"]) else {
            Logger.shared.log("[DisplayMove] window menu unavailable: Window/Oкно menu not found")
            return false
        }

        if let menuItem = menuItemDescendant(in: windowMenu, titles: itemTitles),
           pressMenuItemIfEnabled(menuItem, itemTitles: itemTitles) {
            return true
        }

        AXUIElementPerformAction(windowMenu, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.05)

        guard let menuItem = menuItemDescendant(in: windowMenu, titles: itemTitles) else {
            Logger.shared.log("[DisplayMove] window menu item unavailable: \(itemTitles.joined(separator: "/")) not found")
            return false
        }

        return pressMenuItemIfEnabled(menuItem, itemTitles: itemTitles)
    }

    private func pressMenuItemIfEnabled(_ menuItem: AXUIElement, itemTitles: [String]) -> Bool {
        var enabledValue: AnyObject?
        if AXUIElementCopyAttributeValue(menuItem, kAXEnabledAttribute as CFString, &enabledValue) == .success,
           let isEnabled = enabledValue as? Bool,
           !isEnabled {
            Logger.shared.log("[DisplayMove] window menu item unavailable: \(itemTitles.joined(separator: "/")) disabled")
            return false
        }

        let pressResult = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        return pressResult == .success
    }

    private func menuBarItem(in menuBar: AXUIElement, titles: [String]) -> AXUIElement? {
        children(of: menuBar).first { item in
            guard let title = title(of: item) else { return false }
            return titles.contains(title)
        }
    }

    private func menuItemDescendant(in element: AXUIElement, titles: [String]) -> AXUIElement? {
        for child in children(of: element) {
            if let title = title(of: child), titles.contains(where: { title == $0 || title.hasPrefix($0 + " ") }) {
                return child
            }

            if let found = menuItemDescendant(in: child, titles: titles) {
                return found
            }
        }

        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return []
        }
        return children
    }

    private func title(of element: AXUIElement) -> String? {
        var titleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success else {
            return nil
        }
        return titleValue as? String
    }

    private func moveCursorToWindowCenterLater(windowElement: AXUIElement, fallbackPoint: CGPoint, fallbackSize: CGSize) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            let frame = self?.getWindowAXFrame(windowElement) ?? CGRect(origin: fallbackPoint, size: fallbackSize)
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    private func moveZoomedLikeWindowAndPreserveCoverage(windowElement: AXUIElement, targetAXFrame: CGRect, requestedSize: CGSize, sourceCoverage: WindowCoverage) {
        if requestedSize.width < targetAXFrame.width - 1 || requestedSize.height < targetAXFrame.height - 1 {
            let initialPoint = centeredPoint(for: requestedSize, in: targetAXFrame)
            _ = setWindowPosition(windowElement, point: initialPoint)

            DispatchQueue.main.asyncAfter(deadline: .now() + coverageInitialCheckDelay) { [weak self] in
                guard let self = self else { return }
                self.checkZoomedLikeMoveAndCoverage(
                    windowElement: windowElement,
                    targetAXFrame: targetAXFrame,
                    requestedSize: requestedSize,
                    sourceCoverage: sourceCoverage,
                    attempt: 1,
                    didSetSize: false,
                    previousOversize: nil
                )
            }
            return
        }

        _ = setWindowSize(windowElement, size: requestedSize)
        let initialPoint = centeredPoint(for: requestedSize, in: targetAXFrame)
        _ = setWindowPosition(windowElement, point: initialPoint)

        DispatchQueue.main.asyncAfter(deadline: .now() + coverageInitialCheckDelay) { [weak self] in
            guard let self = self else { return }
            self.checkZoomedLikeMoveAndCoverage(
                windowElement: windowElement,
                targetAXFrame: targetAXFrame,
                requestedSize: requestedSize,
                sourceCoverage: sourceCoverage,
                attempt: 1,
                didSetSize: true,
                previousOversize: nil
            )
        }
    }

    private func checkZoomedLikeMoveAndCoverage(windowElement: AXUIElement, targetAXFrame: CGRect, requestedSize: CGSize, sourceCoverage: WindowCoverage, attempt: Int, didSetSize: Bool, previousOversize: OversizeSample?) {
        guard let frame = getWindowAXFrame(windowElement) else {
            return
        }

        let centerAligned = isWindowCenterAlignedWithTarget(frame, targetAXFrame: targetAXFrame)
        let currentCoverage = screenCoverage(frame, visibleAXFrame: targetAXFrame)

        if (frame.width > targetAXFrame.width + 1 || frame.height > targetAXFrame.height + 1) {
            let oversize = OversizeSample(
                widthOverflow: max(0, frame.width - targetAXFrame.width),
                heightOverflow: max(0, frame.height - targetAXFrame.height)
            )
            if let previousOversize,
               isOversizeDecreasing(current: oversize, previous: previousOversize),
               attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + coverageRecheckDelay) { [weak self] in
                    self?.checkZoomedLikeMoveAndCoverage(
                        windowElement: windowElement,
                        targetAXFrame: targetAXFrame,
                        requestedSize: requestedSize,
                        sourceCoverage: sourceCoverage,
                        attempt: attempt + 1,
                        didSetSize: didSetSize,
                        previousOversize: oversize
                    )
                }
                return
            }

            if previousOversize == nil && didSetSize && attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + coverageRecheckDelay) { [weak self] in
                    self?.checkZoomedLikeMoveAndCoverage(
                        windowElement: windowElement,
                        targetAXFrame: targetAXFrame,
                        requestedSize: requestedSize,
                        sourceCoverage: sourceCoverage,
                        attempt: attempt + 1,
                        didSetSize: didSetSize,
                        previousOversize: oversize
                    )
                }
                return
            }

            _ = setWindowSize(windowElement, size: targetAXFrame.size)

            DispatchQueue.main.asyncAfter(deadline: .now() + coverageRecheckDelay) { [weak self] in
                guard let self = self else { return }
                let centerPoint = self.centeredPoint(for: targetAXFrame.size, in: targetAXFrame)
                _ = self.setWindowPosition(windowElement, point: centerPoint)

                DispatchQueue.main.asyncAfter(deadline: .now() + self.coverageRecheckDelay) { [weak self] in
                    self?.checkZoomedLikeMoveAndCoverage(
                        windowElement: windowElement,
                        targetAXFrame: targetAXFrame,
                        requestedSize: requestedSize,
                        sourceCoverage: sourceCoverage,
                        attempt: attempt + 1,
                        didSetSize: true,
                        previousOversize: nil
                    )
                }
            }
            return
        }

        if !centerAligned && attempt < 6 {
            let centerPoint = centeredPoint(for: frame.size, in: targetAXFrame)
            _ = setWindowPosition(windowElement, point: centerPoint)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.checkZoomedLikeMoveAndCoverage(
                    windowElement: windowElement,
                    targetAXFrame: targetAXFrame,
                    requestedSize: requestedSize,
                    sourceCoverage: sourceCoverage,
                    attempt: attempt + 1,
                    didSetSize: didSetSize,
                    previousOversize: nil
                )
            }
            return
        }

        guard centerAligned else {
            moveCursorToWindowCenterLater(windowElement: windowElement, fallbackPoint: targetAXFrame.origin, fallbackSize: requestedSize)
            return
        }

        if isCoveragePreserved(currentCoverage, comparedTo: sourceCoverage) {
            moveCursorToWindowCenterLater(windowElement: windowElement, fallbackPoint: targetAXFrame.origin, fallbackSize: requestedSize)
            return
        }

        if attempt < maxLowCoverageChecksBeforeZoom {
            DispatchQueue.main.asyncAfter(deadline: .now() + coverageRecheckDelay) { [weak self] in
                self?.checkZoomedLikeMoveAndCoverage(
                    windowElement: windowElement,
                    targetAXFrame: targetAXFrame,
                    requestedSize: requestedSize,
                    sourceCoverage: sourceCoverage,
                    attempt: attempt + 1,
                    didSetSize: didSetSize,
                    previousOversize: nil
                )
            }
            return
        }

        AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, true as CFTypeRef)
        let zoomResult = pressWindowMenuItem(for: windowElement, itemTitles: ["Zoom", "Масштаб", "Масштабировать"])

        if zoomResult {
            moveCursorToWindowCenterLater(windowElement: windowElement, fallbackPoint: targetAXFrame.origin, fallbackSize: requestedSize)
            return
        }

        _ = setWindowPosition(windowElement, point: targetAXFrame.origin)
        _ = setWindowSize(windowElement, size: targetAXFrame.size)
        moveCursorToWindowCenterLater(windowElement: windowElement, fallbackPoint: targetAXFrame.origin, fallbackSize: targetAXFrame.size)
    }

    private func scheduleMoveRetries(windowElement: AXUIElement, targetAXFrame: CGRect, requestedSize: CGSize, shouldRestoreZoomedSize: Bool) {
        let delays: [TimeInterval] = [0.12, 0.30, 0.60, 1.00]
        let retryX = shouldRestoreZoomedSize ? targetAXFrame.minX : targetAXFrame.minX + (targetAXFrame.width - requestedSize.width) / 2
        let retryY = shouldRestoreZoomedSize ? targetAXFrame.minY : targetAXFrame.minY + (targetAXFrame.height - requestedSize.height) / 2
        let retryPoint = CGPoint(x: retryX, y: retryY)

        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                guard let frameBefore = self.getWindowAXFrame(windowElement) else { return }
                if !self.isOutOfBounds(frameBefore, targetAXFrame: targetAXFrame) {
                    return
                }

                // Retry focuses on position, because size is usually already applied.
                _ = self.setWindowPosition(windowElement, point: retryPoint)

                if shouldRestoreZoomedSize {
                    _ = self.setWindowSize(windowElement, size: targetAXFrame.size)
                } else if frameBefore.width - targetAXFrame.width > 0.5 || frameBefore.height - targetAXFrame.height > 0.5 {
                    let retrySize = CGSize(
                        width: min(frameBefore.width, targetAXFrame.width),
                        height: min(frameBefore.height, targetAXFrame.height)
                    )
                    _ = self.setWindowSize(windowElement, size: retrySize)
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

    private func centeredPoint(for size: CGSize, in targetAXFrame: CGRect) -> CGPoint {
        CGPoint(
            x: targetAXFrame.midX - size.width / 2,
            y: targetAXFrame.midY - size.height / 2
        )
    }

    private func centerDelta(_ frame: CGRect, targetAXFrame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX - targetAXFrame.midX, y: frame.midY - targetAXFrame.midY)
    }

    private func isWindowCenterAlignedWithTarget(_ frame: CGRect, targetAXFrame: CGRect) -> Bool {
        let delta = centerDelta(frame, targetAXFrame: targetAXFrame)
        return abs(delta.x) <= 24 && abs(delta.y) <= 24
    }

    private func screenCoverage(_ frame: CGRect, visibleAXFrame: CGRect) -> WindowCoverage {
        (
            width: frame.width / visibleAXFrame.width,
            height: frame.height / visibleAXFrame.height,
            area: (frame.width * frame.height) / (visibleAXFrame.width * visibleAXFrame.height)
        )
    }

    private func isCoveragePreserved(_ current: WindowCoverage, comparedTo source: WindowCoverage) -> Bool {
        let lowerTolerance: CGFloat = 0.08
        let upperTolerance: CGFloat = 0.06
        let expectedWidth = min(1, source.width)
        let expectedHeight = min(1, source.height)
        let expectedArea = min(1, source.area)

        return current.width >= expectedWidth - lowerTolerance &&
               current.height >= expectedHeight - lowerTolerance &&
               current.area >= expectedArea - lowerTolerance &&
               current.width <= expectedWidth + upperTolerance &&
               current.height <= expectedHeight + upperTolerance
    }

    private func isOversizeDecreasing(current: OversizeSample, previous: OversizeSample) -> Bool {
        current.widthOverflow < previous.widthOverflow - 8 ||
        current.heightOverflow < previous.heightOverflow - 8
    }

    private func isZoomedLikeWindow(_ frame: CGRect, visibleAXFrame: CGRect) -> Bool {
        let edgeTolerance: CGFloat = 64
        let widthCoverage = frame.width / visibleAXFrame.width
        let heightCoverage = frame.height / visibleAXFrame.height
        let areaCoverage = (frame.width * frame.height) / (visibleAXFrame.width * visibleAXFrame.height)

        let hugsVisibleEdges = abs(frame.minX - visibleAXFrame.minX) <= edgeTolerance &&
                               abs(frame.maxX - visibleAXFrame.maxX) <= edgeTolerance &&
                               abs(frame.minY - visibleAXFrame.minY) <= edgeTolerance &&
                               abs(frame.maxY - visibleAXFrame.maxY) <= edgeTolerance

        return hugsVisibleEdges && widthCoverage >= 0.90 && heightCoverage >= 0.90 && areaCoverage >= 0.85
    }

    private func formatRect(_ rect: CGRect) -> String {
        String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    private func formatSize(_ size: CGSize) -> String {
        String(format: "w=%.1f h=%.1f", size.width, size.height)
    }

    private func formatPoint(_ point: CGPoint) -> String {
        String(format: "x=%.1f y=%.1f", point.x, point.y)
    }

    private func formatCoverage(_ coverage: WindowCoverage) -> String {
        String(format: "w=%.2f h=%.2f area=%.2f", coverage.width, coverage.height, coverage.area)
    }

    private func formatOversize(_ oversize: OversizeSample) -> String {
        String(format: "overflowW=%.1f overflowH=%.1f", oversize.widthOverflow, oversize.heightOverflow)
    }
}
