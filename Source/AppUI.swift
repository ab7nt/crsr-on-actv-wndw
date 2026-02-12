import Cocoa
import UniformTypeIdentifiers

// MARK: - Localization
enum Language {
    case en, ru
}

struct L10n {
    static var current: Language = .en
    
    static func get(_ key: String) -> String {
        switch current {
        case .en: return en[key] ?? key
        case .ru: return ru[key] ?? key
        }
    }
    
    private static let en: [String: String] = [
        "title": "Absentweaks",
        "lock_title": "Show the cursor lock icon",
        "lock_subtitle": "(above the inactive window)",
        "swipe_title": "Swipe window to another screen",
        "swipe_subtitle": "⌘ + Scroll",
        "middle_title": "Middle mouse button click",
        "middle_subtitle": "3-Finger Tap",
        "app_title": "Quick launch application",
        "app_subtitle": "3-Finger Double Tap",
        "select_app": "Select App...",
        "selected_prefix": "Selected: ",
        "dialog_title": "Select application to launch",
        "launch_start": "Launch on Start",
        "hide_dock": "Hide Dock Icon",
        "quit": "Quit App"
    ]
    
    private static let ru: [String: String] = [
        "title": "Absentweaks",
        "lock_title": "Показывать иконку рядом с курсором",
        "lock_subtitle": "(над неактивным окном)",
        "swipe_title": "Перемещение окна на другой экран",
        "swipe_subtitle": "⌘ + Скролл",
        "middle_title": "Клик средней кнопкой мыши",
        "middle_subtitle": "Касание 3 пальцами",
        "app_title": "Быстрый запуск приложения",
        "app_subtitle": "Двойное касание 3 пальцами",
        "select_app": "Выбрать приложение...",
        "selected_prefix": "Выбрано: ",
        "dialog_title": "Выберите приложение для запуска",
        "launch_start": "Запускать при старте",
        "hide_dock": "Убрать иконку из Dock",
        "quit": "Завершить"
    ]
}

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
    
    private func rebuildUI() {
        view.subviews.forEach { $0.removeFromSuperview() }
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
        // top: 50, bottom: 40
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
        
        let appAuthorLabel = NSTextField(labelWithString: "by ab7nt")
        appAuthorLabel.font = NSFont.systemFont(ofSize: 10)
        appAuthorLabel.textColor = NSColor.gray
        mainStack.addArrangedSubview(appAuthorLabel)
        
        mainStack.setCustomSpacing(0, after: appNameLabel)
        mainStack.setCustomSpacing(5, after: appAuthorLabel)
        
        // Отступ между иконкой и названием: 4
        mainStack.setCustomSpacing(4, after: iconView)
        
        mainStack.addArrangedSubview(createSpacer(height: 10))
        
        // --- Main Settings (Switches) ---
        
        // 1. Show the lock icon
        mainStack.addArrangedSubview(createSwitchRow(
            title: L10n.get("lock_title"),
            subtitle: L10n.get("lock_subtitle"),
            switchObj: &lockSwitch,
            action: #selector(toggleLockIcon(_:))
        ))
        
        // 2. Swipe window to another screen (Cmd + Scroll)
        mainStack.addArrangedSubview(createSwitchRow(
            title: L10n.get("swipe_title"),
            subtitle: L10n.get("swipe_subtitle"),
            switchObj: &swipeSwitch,
            action: #selector(toggleSwipe(_:))
        ))
        
        // 3. Middle mouse button (3-Finger Tap)
        mainStack.addArrangedSubview(createSwitchRow(
            title: L10n.get("middle_title"),
            subtitle: L10n.get("middle_subtitle"),
            switchObj: &middleClickSwitch,
            action: #selector(toggleMiddleClick(_:))
        ))
        
        // 4. Open App (3-Finger Double Tap)
        let appLaunchRow = createSwitchRow(
            title: L10n.get("app_title"),
            subtitle: L10n.get("app_subtitle"),
            switchObj: &appLaunchSwitch,
            action: #selector(toggleAppLaunch(_:))
        )
        mainStack.addArrangedSubview(appLaunchRow)
        
        // Reduced spacing between title/switch and the button
        mainStack.setCustomSpacing(4, after: appLaunchRow)
        
        // App Selection Button Container (Left Aligned)
        let buttonContainer = NSStackView()
        buttonContainer.orientation = .horizontal
        buttonContainer.alignment = .leading
        buttonContainer.widthAnchor.constraint(equalToConstant: 350).isActive = true
        
        appSelectionButton = NSButton(title: "", target: self, action: #selector(selectApp(_:)))
        appSelectionButton.bezelStyle = .rounded
        appSelectionButton.imagePosition = .imageLeft
        buttonContainer.addArrangedSubview(appSelectionButton)
        
        mainStack.addArrangedSubview(buttonContainer)
        
        // Отступ перед чекбоксами
        mainStack.addArrangedSubview(createSpacer(height: 15))
        
        // --- Secondary Settings (Checkboxes) ---
        
        let secondaryStack = NSStackView()
        secondaryStack.orientation = .vertical
        secondaryStack.alignment = .leading
        secondaryStack.spacing = 10
        
        // Launch on Start
        launchCheckbox = createCheckbox(title: L10n.get("launch_start"), action: #selector(toggleLaunchAtLogin(_:)))
        secondaryStack.addArrangedSubview(launchCheckbox)
        
        // Hide Dock Icon
        dockCheckbox = createCheckbox(title: L10n.get("hide_dock"), action: #selector(toggleDockIcon(_:)))
        secondaryStack.addArrangedSubview(dockCheckbox)
        
        // Align secondary stack matches the switch row width
        secondaryStack.widthAnchor.constraint(equalToConstant: 350).isActive = true
        mainStack.addArrangedSubview(secondaryStack)
        
        mainStack.addArrangedSubview(createSpacer(height: 15))
        
        // --- Footer (Language & Quit) ---
        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.distribution = .fill
        footerStack.widthAnchor.constraint(equalToConstant: 350).isActive = true
        
        // Language Switcher
        let langStack = NSStackView()
        langStack.orientation = .horizontal
        langStack.spacing = 10
        
        let enBtn = createLangButton(title: "EN", lang: .en)
        let ruBtn = createLangButton(title: "RU", lang: .ru)
        
        langStack.addArrangedSubview(enBtn)
        langStack.addArrangedSubview(ruBtn)
        
        footerStack.addArrangedSubview(langStack)
        
        // Spacer to push Quit button to the right
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerStack.addArrangedSubview(footerSpacer)
        
        let quitBtn = NSButton(title: L10n.get("quit"), target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitBtn.bezelStyle = .rounded
        quitBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        footerStack.addArrangedSubview(quitBtn)
        
        mainStack.addArrangedSubview(footerStack)
    }
    
    private func createLangButton(title: String, lang: Language) -> NSButton {
        let btn = NSButton(title: title, target: self, action: #selector(changeLanguage(_:)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.tag = (lang == .en) ? 0 : 1
        
        if L10n.current == lang {
            btn.contentTintColor = .white
            btn.font = NSFont.boldSystemFont(ofSize: 13)
        } else {
            btn.contentTintColor = .gray
            btn.font = NSFont.systemFont(ofSize: 13)
        }
        return btn
    }

    @objc func changeLanguage(_ sender: NSButton) {
        let newLang: Language = (sender.tag == 0) ? .en : .ru
        if L10n.current != newLang {
            L10n.current = newLang
            rebuildUI()
        }
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
        
        row.widthAnchor.constraint(equalToConstant: 350).isActive = true
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
        dialog.title = L10n.get("dialog_title")
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
             
             // Clear standard image
             appSelectionButton.image = nil
             
             // Attributed Text
             let fullString = NSMutableAttributedString()
             
             // 1. Prefix ("Selected: ")
             let prefix = NSAttributedString(string: L10n.get("selected_prefix"), attributes: [
                .foregroundColor: NSColor.lightGray,
                .font: NSFont.systemFont(ofSize: 12)
             ])
             fullString.append(prefix)
             
             // 2. Icon (as Text Attachment)
             let icon = NSWorkspace.shared.icon(forFile: path)
             icon.size = NSSize(width: 14, height: 14)
             
             let attachment = NSTextAttachment()
             attachment.image = icon
             // Adjust y to align with text baseline
             attachment.bounds = CGRect(x: 0, y: -3, width: 14, height: 14)
             fullString.append(NSAttributedString(attachment: attachment))
             
             // 3. Space
             fullString.append(NSAttributedString(string: " "))
             
             // 4. App Name
             let appName = NSAttributedString(string: name, attributes: [
                .foregroundColor: NSColor.white, // Highlighted
                .font: NSFont.boldSystemFont(ofSize: 12)
             ])
             fullString.append(appName)
             
             appSelectionButton.attributedTitle = fullString
        } else {
             appSelectionButton.image = nil
             appSelectionButton.title = ""
             // Reset to plain text style look for "Select App..."
             appSelectionButton.attributedTitle = NSAttributedString(
                string: L10n.get("select_app"), 
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.controlTextColor]
             )
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
