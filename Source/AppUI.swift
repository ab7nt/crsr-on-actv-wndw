import Cocoa
import UniformTypeIdentifiers

class SettingsViewController: NSViewController {
    
    var stateController: StateController?
    
    // Switch UI Elements
    private var lockSwitch: NSSwitch!
    private var swipeSwitch: NSSwitch!
    private var middleClickSwitch: NSSwitch!
    private var appLaunchSwitch: NSSwitch!
    private var appSelectionButton: NSButton!
    
    // Checkbox UI Elements
    private var launchCheckbox: NSButton!
    private var dockCheckbox: NSButton!
    
    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refresh()
    }
    
    func refresh() {
        // 1. Lock Icon (Overlay)
        if let controller = stateController {
            lockSwitch.state = controller.isOverlayEnabled ? .on : .off
            swipeSwitch.state = controller.isSpacesSwipeEnabled ? .on : .off
            middleClickSwitch.state = controller.isMiddleClickGestureEnabled ? .on : .off
            appLaunchSwitch.state = controller.isAppLaunchEnabled ? .on : .off
            updateAppButtonTitle()
        }
        
        // 2. Secondary Settings
        // Launch at Login
        launchCheckbox.state = LaunchManager.shared.isLaunchAtLoginEnabled ? .on : .off
        
        // Hide Dock Icon
        dockCheckbox.state = UserDefaults.standard.bool(forKey: "HideDockIcon") ? .on : .off
    }
    
    private func setupUI() {
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 20
        // Устанавливаем отступы от краев контейнера. 
        // top: 50, bottom: 40 (увеличили нижний отступ, чтобы версия не прилипала)
        mainStack.edgeInsets = NSEdgeInsets(top: 50, left: 0, bottom: 40, right: 0)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            mainStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            mainStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            mainStack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -40)
        ])
        
        // --- Header ---
        let iconImg = NSImage(named: NSImage.applicationIconName)
        let iconView = NSImageView(image: iconImg ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 70).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 70).isActive = true
        mainStack.addArrangedSubview(iconView)
        
        let appNameLabel = NSTextField(labelWithString: "Absentweaks")
        appNameLabel.font = NSFont.boldSystemFont(ofSize: 18)
        appNameLabel.textColor = .white
        mainStack.addArrangedSubview(appNameLabel)
        
        // Отступ между иконкой и названием: 4
        mainStack.setCustomSpacing(4, after: iconView)
        
        mainStack.addArrangedSubview(createSpacer(height: 10))
        
        // --- Main Settings (Switches) ---
        
        // 1. Show the lock icon
        mainStack.addArrangedSubview(createSwitchRow(
            title: "Show the lock icon",
            subtitle: "(above the inactive window)",
            switchObj: &lockSwitch,
            action: #selector(toggleLockIcon(_:))
        ))
        
        // 2. Swipe window to another screen (Cmd + Scroll)
        mainStack.addArrangedSubview(createSwitchRow(
            title: "Swipe window to another screen",
            subtitle: "⌘ + Scroll",
            switchObj: &swipeSwitch,
            action: #selector(toggleSwipe(_:))
        ))
        
        // 3. Middle mouse button (3-Finger Tap)
        mainStack.addArrangedSubview(createSwitchRow(
            title: "Middle mouse button",
            subtitle: "3-Finger Tap",
            switchObj: &middleClickSwitch,
            action: #selector(toggleMiddleClick(_:))
        ))
        
        // 4. Open App (3-Finger Double Tap)
        mainStack.addArrangedSubview(createSwitchRow(
            title: "Open Application",
            subtitle: "3-Finger Double Tap",
            switchObj: &appLaunchSwitch,
            action: #selector(toggleAppLaunch(_:))
        ))
        
        // App Selection Button
        appSelectionButton = NSButton(title: "Select App...", target: self, action: #selector(selectApp(_:)))
        appSelectionButton.bezelStyle = .rounded
        mainStack.addArrangedSubview(appSelectionButton)
        
        // Отступ перед чекбоксами
        mainStack.addArrangedSubview(createSpacer(height: 15))
        
        // --- Secondary Settings (Checkboxes) ---
        
        let secondaryStack = NSStackView()
        secondaryStack.orientation = .vertical
        secondaryStack.alignment = .leading
        secondaryStack.spacing = 10
        
        // Launch on Start
        launchCheckbox = createCheckbox(title: "Launch on Start", action: #selector(toggleLaunchAtLogin(_:)))
        secondaryStack.addArrangedSubview(launchCheckbox)
        
        // Hide Dock Icon
        dockCheckbox = createCheckbox(title: "Hide Dock Icon", action: #selector(toggleDockIcon(_:)))
        secondaryStack.addArrangedSubview(dockCheckbox)
        
        // Align secondary stack matches the switch row width
        secondaryStack.widthAnchor.constraint(equalToConstant: 280).isActive = true
        mainStack.addArrangedSubview(secondaryStack)
        
        mainStack.addArrangedSubview(createSpacer(height: 15))
        
        // --- Footer ---
        let quitBtn = NSButton(title: "Quit App", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitBtn.bezelStyle = .rounded
        quitBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        mainStack.addArrangedSubview(quitBtn)
    }
    
    private func createSwitchRow(title: String, subtitle: String?, switchObj: inout NSSwitch!, action: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 15
        row.alignment = .centerY
        
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .white
        textStack.addArrangedSubview(titleLabel)
        
        if let sub = subtitle {
            let subLabel = NSTextField(labelWithString: sub)
            subLabel.font = NSFont.systemFont(ofSize: 11)
            subLabel.textColor = NSColor.lightGray
            textStack.addArrangedSubview(subLabel)
        }
        
        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = action
        switchObj = toggle
        
        row.addArrangedSubview(textStack)
        
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        
        row.addArrangedSubview(toggle)
        
        row.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return row
    }
    
    private func createCheckbox(title: String, action: Selector) -> NSButton {
        let cb = NSButton(checkboxWithTitle: "", target: self, action: action)
        cb.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13)
        ])
        return cb
    }
    
    private func createSpacer(height: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }
    
    // --- Actions ---
    
    @objc func toggleLockIcon(_ sender: NSSwitch) {
        stateController?.isOverlayEnabled = (sender.state == .on)
    }
    
    @objc func toggleSwipe(_ sender: NSSwitch) {
        stateController?.isSpacesSwipeEnabled = (sender.state == .on)
    }
    
    @objc func toggleMiddleClick(_ sender: NSSwitch) {
        stateController?.isMiddleClickGestureEnabled = (sender.state == .on)
    }

    @objc func toggleAppLaunch(_ sender: NSSwitch) {
         stateController?.isAppLaunchEnabled = (sender.state == .on)
         updateAppButtonTitle()
    }
    
    @objc func selectApp(_ sender: NSButton) {
        // Suspend heavy listeners to prevent UI lag
        stateController?.suspendForDialog()
        
        // Ensure the app is active so the dialog appears promptly and doesn't lag the UI
        NSApp.activate(ignoringOtherApps: true)
        
        let dialog = NSOpenPanel()
        dialog.title = "Select Application to Launch"
        if #available(macOS 11.0, *) {
            dialog.allowedContentTypes = [.application]
        } else {
            dialog.allowedFileTypes = ["app"]
        }
        dialog.directoryURL = URL(fileURLWithPath: "/Applications")
        dialog.canChooseFiles = true
        dialog.canChooseDirectories = false
        dialog.treatsFilePackagesAsDirectories = false
        
        dialog.begin { response in
            if response == .OK, let url = dialog.url {
                self.stateController?.selectedAppPath = url.path
                self.updateAppButtonTitle()
            }
            // Resume listeners
            self.stateController?.resumeFromDialog()
        }
    }
    
    func updateAppButtonTitle() {
        guard let controller = stateController else { return }
        if let path = controller.selectedAppPath {
             let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
             appSelectionButton.title = "Selected: \(name)"
        } else {
             appSelectionButton.title = "Select App..."
        }
        appSelectionButton.isEnabled = (appLaunchSwitch.state == .on)
    }
    
    @objc func toggleLaunchAtLogin(_ sender: NSButton) {
        LaunchManager.shared.isLaunchAtLoginEnabled = (sender.state == .on)
    }
    
    @objc func toggleDockIcon(_ sender: NSButton) {
        let hide = (sender.state == .on)
        let policy: NSApplication.ActivationPolicy = hide ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
        
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        UserDefaults.standard.set(hide, forKey: "HideDockIcon")
    }
}
