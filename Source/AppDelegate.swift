import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    
    var stateController: StateController?
    var window: NSWindow!
    var settingsViewController: SettingsViewController!

    // STRONG REFERENCE IS CRITICAL.
    // If this is weak or optional and gets nil'd, the item vanishes.
    var statusItem: NSStatusItem!
    
    // Preference Key
    private let kHideDockIcon = "HideDockIcon"
    private let kStartupDefaultsInitialized = "StartupDefaultsInitialized"

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if AppMoveHelper.shared.promptToMoveIfNeeded() {
            return
        }

        if !UserDefaults.standard.bool(forKey: kStartupDefaultsInitialized) {
            LaunchManager.shared.isLaunchAtLoginEnabled = false
            UserDefaults.standard.set(false, forKey: kHideDockIcon)
            UserDefaults.standard.set(true, forKey: kStartupDefaultsInitialized)
        }

        updateActivationPolicy()

        // 1. Initialize logic
        stateController = StateController()
        
        // 2. Create status item
        setupStatusItem()
        
        // 3. Setup Main Window
        setupMainWindow()
    }
    
    func updateActivationPolicy() {
         let shouldHide = UserDefaults.standard.bool(forKey: kHideDockIcon)
         let currentPolicy = NSApp.activationPolicy()
         
         if shouldHide {
             if currentPolicy != .accessory {
                 NSApp.setActivationPolicy(.accessory)
             }
         } else {
             if currentPolicy != .regular {
                 NSApp.setActivationPolicy(.regular)
                 NSApp.activate(ignoringOtherApps: true)
             }
         }
         
         DispatchQueue.main.async {
             if !shouldHide && self.window != nil && self.window.isVisible {
                 NSApp.activate(ignoringOtherApps: true)
             }
         }
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem.button else {
            Logger.shared.log("Failed to get status item button")
            return
        }

        // Set Image (Standard 18x18 template)
        if let img = NSImage(named: "MenuBarIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            button.image = img
        } else if let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
                  let img = NSImage(contentsOfFile: path) {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            button.image = img
        } else {
            button.title = "⚡"
        }
        
        button.action = #selector(statusItemClicked)
        button.target = self
        
        // Construct Menu
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLoginFromMenu(_:)), keyEquivalent: "")
        menu.addItem(launchItem)
        
        let hideItem = NSMenuItem(title: "Hide Dock Icon", action: #selector(toggleDockIconFromMenu(_:)), keyEquivalent: "")
        menu.addItem(hideItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
        
        // Ensure Visible
        statusItem.isVisible = true
    }
    
    func menuWillOpen(_ menu: NSMenu) {
         if let launchItem = menu.items.first(where: { $0.action == #selector(toggleLaunchAtLoginFromMenu(_:)) }) {
             launchItem.state = LaunchManager.shared.isLaunchAtLoginEnabled ? .on : .off
         }
         if let hideItem = menu.items.first(where: { $0.action == #selector(toggleDockIconFromMenu(_:)) }) {
             hideItem.state = isDockIconHidden ? .on : .off
         }
    }

    @objc func toggleLaunchAtLoginFromMenu(_ sender: NSMenuItem) {
        LaunchManager.shared.isLaunchAtLoginEnabled = (sender.state == .off)
        settingsViewController?.refresh()
    }

    @objc func toggleDockIconFromMenu(_ sender: NSMenuItem) {
        setDockIconHidden(sender.state == .off)
        settingsViewController?.refresh()
    }
    
    @objc func statusItemClicked() {
        statusItem?.button?.performClick(nil)
    }
    
    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if window == nil {
            setupMainWindow()
        }
        window.makeKeyAndOrderFront(nil)
    }
    
    func setDockIconHidden(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: kHideDockIcon)
        updateActivationPolicy()
    }
    
    var isDockIconHidden: Bool {
        return UserDefaults.standard.bool(forKey: kHideDockIcon)
    }

    func setupMainWindow() {
        let windowSize = NSSize(width: 420, height: 450)
        let screenSize = NSScreen.main?.frame.size ?? .zero
        let rect = NSRect(x: (screenSize.width - windowSize.width) / 2,
                          y: (screenSize.height - windowSize.height) / 2,
                          width: windowSize.width,
                          height: windowSize.height)
        
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered,
                          defer: false)
        window.title = "Absentweaks"
        window.isReleasedWhenClosed = false
        window.delegate = self
        
        // Dark theme
        window.backgroundColor = NSColor(red: 20/255.0, green: 22/255.0, blue: 36/255.0, alpha: 1.0)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        
        window.minSize = NSSize(width: 420, height: 500)
        window.maxSize = NSSize(width: 420, height: 500)
        
        settingsViewController = SettingsViewController()
        settingsViewController.stateController = stateController
        
        window.contentViewController = settingsViewController
        window.makeKeyAndOrderFront(nil)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        updateActivationPolicy()
        if window != nil {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        updateActivationPolicy()
        if window == nil {
            setupMainWindow()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
    
    func windowWillClose(_ notification: Notification) {
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

final class AppMoveHelper {
    static let shared = AppMoveHelper()
    
    private var isSystemRussian: Bool {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("ru")
    }

    @discardableResult
    func promptToMoveIfNeeded() -> Bool {
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)

        guard bundleURL.pathExtension == "app" else {
            return false
        }
        guard !isInApplicationsFolder(bundleURL) else {
            return false
        }

        let alert = NSAlert()
        if isSystemRussian {
            alert.messageText = "Переместить в папку Applications?"
            alert.informativeText = "Absentweaks корректно работает только из папки Applications. Переместить сейчас?"
            alert.addButton(withTitle: "Переместить")
            alert.addButton(withTitle: "Не сейчас")
        } else {
            alert.messageText = "Move to Applications folder?"
            alert.informativeText = "Absentweaks works correctly only when launched from Applications. Move it now?"
            alert.addButton(withTitle: "Move to Applications")
            alert.addButton(withTitle: "Not Now")
        }
        alert.alertStyle = .informational

        if alert.runModal() != .alertFirstButtonReturn {
            return false
        }

        do {
            let destinationURL = try moveAppToApplications(from: bundleURL)
            relaunch(at: destinationURL)
            NSApp.terminate(nil)
            return true
        } catch {
            presentMoveFailedAlert(error: error)
            return false
        }
    }

    private func isInApplicationsFolder(_ bundleURL: URL) -> Bool {
        let resolvedPath = bundleURL.resolvingSymlinksInPath().path
        return resolvedPath.hasPrefix("/Applications/") || resolvedPath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private func moveAppToApplications(from sourceURL: URL) throws -> URL {
        let destinationURL = URL(fileURLWithPath: "/Applications").appendingPathComponent(sourceURL.lastPathComponent)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func relaunch(at bundleURL: URL) {
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func presentMoveFailedAlert(error: Error) {
        let alert = NSAlert()
        if isSystemRussian {
            alert.messageText = "Не удалось переместить приложение"
            alert.addButton(withTitle: "ОК")
        } else {
            alert.messageText = "Unable to move app"
            alert.addButton(withTitle: "OK")
        }
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
