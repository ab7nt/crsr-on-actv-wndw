import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var stateController: StateController?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Initialize the core logic
        stateController = StateController()
        
        setupStatusBar()
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // Using lock.circle to match the app theme
            button.image = NSImage(systemSymbolName: "lock.circle", accessibilityDescription: "Cursor overlay")
        }
        
        let menu = NSMenu()
        
        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.state = LaunchManager.shared.isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)
        
        // Swipe Toggle
        if let controller = stateController {
            let swipeItem = NSMenuItem(title: "Enable Window Swipes (Cmd + Scroll)", action: #selector(toggleSwipes), keyEquivalent: "")
            swipeItem.state = controller.isSpacesSwipeEnabled ? .on : .off
            menu.addItem(swipeItem)
            
            let overlayItem = NSMenuItem(title: "Show Safety Lock", action: #selector(toggleOverlay), keyEquivalent: "")
            overlayItem.state = controller.isOverlayEnabled ? .on : .off
            menu.addItem(overlayItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    @objc func toggleSwipes(_ sender: NSMenuItem) {
        guard let controller = stateController else { return }
        let newState = !controller.isSpacesSwipeEnabled
        controller.isSpacesSwipeEnabled = newState
        sender.state = newState ? .on : .off
    }
    
    @objc func toggleOverlay(_ sender: NSMenuItem) {
        guard let controller = stateController else { return }
        let newState = !controller.isOverlayEnabled
        controller.isOverlayEnabled = newState
        sender.state = newState ? .on : .off
    }
    
    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !LaunchManager.shared.isLaunchAtLoginEnabled
        LaunchManager.shared.isLaunchAtLoginEnabled = newState
        sender.state = newState ? .on : .off
    }
    
    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Tear down
    }
}

class LaunchManager {
    static let shared = LaunchManager()
    
    var isLaunchAtLoginEnabled: Bool {
        get {
            return FileManager.default.fileExists(atPath: plistPath.path)
        }
        set {
            if newValue {
                enableLaunchAtLogin()
            } else {
                disableLaunchAtLogin()
            }
        }
    }
    
    private var plistPath: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library.appendingPathComponent("LaunchAgents/com.user.absentweaks.plist")
    }
    
    private func enableLaunchAtLogin() {
        let appPath = Bundle.main.bundlePath + "/Contents/MacOS/Absentweaks"
        
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.user.absentweaks</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(appPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
        
        do {
            let directory = plistPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to enable launch at login: \(error)")
        }
    }
    
    private func disableLaunchAtLogin() {
        try? FileManager.default.removeItem(at: plistPath)
    }
}
