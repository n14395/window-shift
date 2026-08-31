import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DragController()
    private var eventTap: EventTap?

    // Menu views
    private let headerView = MenuHeaderView()
    private let captionView = WrappingTextView()
    private let lastDragView = WrappingTextView()
    private var lastDragItem: NSMenuItem!
    private var chipsView: ModifierChipsView!
    private let conflictView = WrappingTextView()
    private var conflictItem: NSMenuItem!
    private let loginRow = SettingRowView(title: "Launch at Login", symbol: "power")
    private let hideIconRow = SettingRowView(title: "Hide Menu Bar Icon", symbol: "eye.slash")
    private let screenRecordingRow = SettingRowView(title: "Grant Screen Recording",
                                                    symbol: "rectangle.dashed.badge.record")
    private var screenRecordingItem: NSMenuItem!
    private let footerRow = AboutQuitRowView()
    private var iconVisibilityObservation: NSKeyValueObservation?
    private let settingsHeader = SectionHeaderView(title: "Settings", collapsible: true)
    private var settingsItems: [NSMenuItem] = []
    private var settingsExpanded = false
    // Choice submenus: defaults key -> (option row, encoded value)
    private var choiceRows: [String: [(row: OptionRowView, value: String)]] = [:]
    private let disabledAppsMenu = NSMenu()

    /// Defaults keys the app observes; any change (menu or external
    /// `defaults write`) reloads the live config automatically.
    private static let observedKeys = [
        "enabled", "modifiers", "magneticSnapDistance", "resizeInset",
        "disabledApps", "showMenuBarIcon",
    ]

    private static let modifierChoices: [(title: String, name: String)] = [
        ("\u{2303}", "ctrl"),
        ("\u{2325}", "opt"),
        ("\u{21E7}", "shift"),
        ("\u{2318}", "cmd"),
        ("fn", "fn"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["enabled": true, "showMenuBarIcon": true])
        // One-time cleanup of keys left behind by removed features. The
        // handoff/title-bar settings went with the move mechanism they tuned:
        // the drag is bound to a window ID now, so there is no grab offset to
        // reconcile and no title bar to aim at.
        for dead in ["perAppGrabX", "dragMode", "edgeSnapProximity", "handoffRelease",
                     "titleBarInset", "trafficLightMargin"] {
            UserDefaults.standard.removeObject(forKey: dead)
        }
        controller.enabled = UserDefaults.standard.bool(forKey: "enabled")

        setupStatusItem()
        observeSessionSwitching()
        observePermissionLoss()
        for key in Self.observedKeys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil)
        }

        Permissions.waitUntilTrusted { [weak self] in
            self?.startTap()
            // Ask once, now that the app is otherwise ready. Declining is
            // survivable — moves fall back to Accessibility — and the menu
            // keeps an entry for granting it later.
            if SkyLight.available, !Permissions.screenRecordingGranted {
                Permissions.requestScreenRecording()
            }
        }
        if !Permissions.trusted {
            captionView.setText("Waiting for Accessibility permission…")
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.controller.reloadConfig()
            self.controller.enabled = UserDefaults.standard.bool(forKey: "enabled")
            self.applyIconVisibility()
            self.refreshMenuState()
        }
    }

    private func startTap() {
        let tap = EventTap(controller: controller)
        if tap.start() {
            eventTap = tap
            refreshMenuState()
        } else {
            captionView.setText("Failed to create event tap")
            let alert = NSAlert()
            alert.messageText = "WindowShift could not create its event tap"
            alert.informativeText = "Check that WindowShift is allowed under System Settings > Privacy & Security > Accessibility, then relaunch."
            alert.runModal()
        }
    }

    // MARK: - Menu construction

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.image?.accessibilityDescription = "WindowShift"
        statusItem.autosaveName = "WindowShift"
        statusItem.behavior = .removalAllowed  // ⌘-drag off the menu bar
        statusItem.isVisible = UserDefaults.standard.bool(forKey: "showMenuBarIcon")
        // Fires for ⌘-drag removal as well as programmatic changes; the
        // handler only acts when the defaults key disagrees.
        iconVisibilityObservation = statusItem.observe(\.isVisible, options: []) { [weak self] item, _ in
            let visible = item.isVisible
            DispatchQueue.main.async {
                self?.iconVisibilityChanged(to: visible)
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        headerView.onToggle = { [weak self] on in
            self?.controller.enabled = on
            UserDefaults.standard.set(on, forKey: "enabled")
        }
        menu.addItem(viewItem(headerView))
        menu.addItem(viewItem(captionView))
        lastDragItem = viewItem(lastDragView)
        lastDragItem.isHidden = true
        menu.addItem(lastDragItem)
        menu.addItem(.separator())

        menu.addItem(viewItem(SectionHeaderView(title: "Trigger On", collapsible: false)))
        chipsView = ModifierChipsView(choices: Self.modifierChoices)
        chipsView.onToggle = { [weak self] name in self?.toggleModifier(named: name) }
        menu.addItem(viewItem(chipsView))
        conflictItem = viewItem(conflictView)
        conflictItem.isHidden = true
        menu.addItem(conflictItem)
        menu.addItem(.separator())

        // Settings section: collapsible, collapsed by default
        settingsHeader.onToggleCollapse = { [weak self] in
            guard let self else { return }
            self.settingsExpanded.toggle()
            self.applySettingsCollapse()
        }
        menu.addItem(viewItem(settingsHeader))

        loginRow.onClick = { [weak self] in self?.toggleLaunchAtLogin() }
        let loginItem = viewItem(loginRow)
        settingsItems.append(loginItem)
        menu.addItem(loginItem)

        hideIconRow.onClick = { [weak self] in self?.hideMenuBarIconRequested() }
        let hideIconItem = viewItem(hideIconRow)
        settingsItems.append(hideIconItem)
        menu.addItem(hideIconItem)

        // Shown only while the grant is missing. Not filed under Settings: it
        // is not a preference, it is the difference between moves that tile and
        // moves that do not.
        screenRecordingRow.onClick = { [weak self] in
            Permissions.requestScreenRecording()
            self?.controller.reloadConfig()   // re-arm the drag path
        }
        screenRecordingItem = viewItem(screenRecordingRow)
        menu.addItem(screenRecordingItem)

        let disabledRow = SettingRowView(title: "Disabled Apps", symbol: "nosign", showsSubmenuChevron: true)
        let disabledItem = viewItem(disabledRow)
        disabledItem.submenu = disabledAppsMenu
        settingsItems.append(disabledItem)
        menu.addItem(disabledItem)

        menu.addItem(.separator())

        footerRow.onAbout = { [weak self] in
            self?.statusItem.menu?.cancelTracking()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        footerRow.onQuit = { NSApp.terminate(nil) }
        menu.addItem(viewItem(footerRow))

        statusItem.menu = menu
        applySettingsCollapse()
        refreshMenuState()
    }

    private func applySettingsCollapse() {
        for item in settingsItems {
            item.isHidden = !settingsExpanded
        }
        settingsHeader.setExpanded(settingsExpanded)
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func addChoiceRow(
        to menu: NSMenu, title: String, symbol: String, description: String, key: String,
        options: [(title: String, value: String)]
    ) {
        let row = SettingRowView(title: title, symbol: symbol, showsSubmenuChevron: true)
        let item = viewItem(row)
        let submenu = NSMenu()
        submenu.addItem(viewItem(WrappingTextView.description(description)))
        submenu.addItem(.separator())
        var rows: [(row: OptionRowView, value: String)] = []
        for option in options {
            let optionRow = OptionRowView(title: option.title)
            optionRow.onClick = { [weak self] in self?.applyChoice(key: key, value: option.value) }
            submenu.addItem(viewItem(optionRow))
            rows.append((optionRow, option.value))
        }
        item.submenu = submenu
        choiceRows[key] = rows
        settingsItems.append(item)
        menu.addItem(item)
    }

    // MARK: - Menu state

    func menuWillOpen(_ menu: NSMenu) {
        // Collapsed by default on every open.
        settingsExpanded = false
        applySettingsCollapse()
        Permissions.refreshScreenRecording()
        rebuildDisabledAppsMenu()
        if let status = controller.lastStatus {
            lastDragView.setText("Last drag: \(status)", color: .tertiaryLabelColor)
            lastDragItem.isHidden = false
        } else {
            lastDragItem.isHidden = true
        }
        refreshMenuState()
    }

    private func rebuildDisabledAppsMenu() {
        disabledAppsMenu.removeAllItems()
        let disabled = controller.currentConfig.disabledApps
        disabledAppsMenu.addItem(viewItem(WrappingTextView.description(
            "WindowShift ignores modifier-drags in checked apps. The top entry toggles whichever app was frontmost when this menu opened."
        )))
        disabledAppsMenu.addItem(.separator())

        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier, bid != Bundle.main.bundleIdentifier {
            let name = front.localizedName ?? bid
            let row = OptionRowView(title: "Disable for \(name)")
            row.isSelected = disabled.contains(bid)
            row.onClick = { [weak self, weak row] in
                self?.toggleDisabledApp(bid)
                row?.isSelected.toggle()
            }
            disabledAppsMenu.addItem(viewItem(row))
            disabledAppsMenu.addItem(.separator())
        }

        if disabled.isEmpty {
            disabledAppsMenu.addItem(NSMenuItem(title: "No disabled apps", action: nil, keyEquivalent: ""))
        } else {
            for bid in disabled.sorted() {
                let row = OptionRowView(title: appName(for: bid))
                row.isSelected = true
                row.onClick = { [weak self, weak row] in
                    self?.toggleDisabledApp(bid)
                    row?.isSelected.toggle()
                }
                disabledAppsMenu.addItem(viewItem(row))
            }
        }
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func refreshMenuState() {
        let config = controller.currentConfig
        headerView.toggle.isOnSwitch = controller.enabled
        statusItem.button?.appearsDisabled = !(controller.enabled && eventTap != nil)
        updateConflictWarning(config)
        if eventTap != nil {
            var caption = "\(config.modifierDescription) + left-drag moves the window, "
                + "right-drag resizes it. Double-click fills the screen, "
                + "right-double-click centers. Esc cancels a drag."
            if SkyLight.available, !Permissions.screenRecordingGranted {
                caption += " Grant Screen Recording for real drag sessions — without it"
                    + " windows still move, but nothing tiles or snaps. Nothing is ever"
                    + " recorded: it is the permission macOS checks before one app may"
                    + " drag another's windows."
            } else if !SkyLight.available {
                caption += " Warning: this macOS no longer offers the window-server drag"
                    + " call WindowShift uses, so windows move without tiling or snapping."
            } else if !DragController.windowManagerFlag("EnableTilingByEdgeDrag"),
                      !DragController.windowManagerFlag("EnableTopTilingByEdgeDrag") {
                caption += " Note: native drag-tiling is off in System Settings > Desktop & Dock."
            }
            captionView.setText(caption)
        }
        for chip in chipsView.chips {
            guard let name = chip.identifier?.rawValue,
                  let flag = Config.modifierNames[name] else { continue }
            chip.isOnChip = config.modifierFlags.contains(flag)
        }
        loginRow.isOn = SMAppService.mainApp.status == .enabled
        screenRecordingItem?.isHidden =
            !SkyLight.available || (Permissions.screenRecordingGranted && !controller.dragSessionsRefused)
        for (key, rows) in choiceRows {
            let value = UserDefaults.standard.double(forKey: key)
            for entry in rows {
                entry.row.isSelected = abs((Double(entry.value) ?? .nan) - value) < 0.01
            }
        }
    }

    /// Warn (in orange, under the chips) about modifier combos that collide
    /// with system gestures.
    private func updateConflictWarning(_ config: Config) {
        var warning: String?
        if config.modifierFlags.contains(.maskAlternate), optionTilingAcceleratorOn() {
            warning = "⌥ is also macOS's hold-to-tile key, so every drag will show native tiling zones. Drop ⌥, or turn off \"Hold ⌥ key while dragging windows to tile\" in System Settings > Desktop & Dock."
        } else if config.modifierFlags == .maskCommand {
            warning = "⌘ alone collides with macOS's built-in ⌘-drag, which moves background windows without focusing them."
        }
        if let warning {
            conflictView.setText(warning, color: .systemOrange)
        }
        conflictItem.isHidden = warning == nil
    }

    private func optionTilingAcceleratorOn() -> Bool {
        DragController.windowManagerFlag("EnableTilingOptionAccelerator")
    }

    // MARK: - Actions

    private func applyChoice(key: String, value: String) {
        UserDefaults.standard.set(Double(value) ?? 0, forKey: key)
        controller.reloadConfig()
        refreshMenuState()
    }

    private func toggleModifier(named name: String) {
        guard let flag = Config.modifierNames[name] else { return }
        var flags = controller.currentConfig.modifierFlags
        if flags.contains(flag) {
            flags.remove(flag)
        } else {
            flags.insert(flag)
        }
        guard !flags.isEmpty else {
            // At least one modifier must stay selected, or every plain drag
            // would grab windows.
            NSSound.beep()
            return
        }
        UserDefaults.standard.set(Config.spec(from: flags), forKey: "modifiers")
        controller.reloadConfig()
        refreshMenuState()
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("WindowShift: launch-at-login toggle failed: \(error)")
        }
        refreshMenuState()
    }

    private func toggleDisabledApp(_ bundleID: String) {
        var disabled = controller.currentConfig.disabledApps
        if disabled.contains(bundleID) {
            disabled.remove(bundleID)
        } else {
            disabled.insert(bundleID)
        }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: "disabledApps")
        controller.reloadConfig()
        refreshMenuState()
    }

    // MARK: - Menu bar icon visibility

    /// `showMenuBarIcon` (defaults) is the source of truth; this pushes it
    /// onto the status item whenever the key changes (menu, `defaults write`).
    private func applyIconVisibility() {
        let show = UserDefaults.standard.bool(forKey: "showMenuBarIcon")
        if statusItem.isVisible != show {
            statusItem.isVisible = show
        }
    }

    /// Status-item visibility changed underneath us — the only unprompted
    /// path is the user ⌘-dragging the icon off the bar. Sync the defaults
    /// key and tell them how to get back in.
    private func iconVisibilityChanged(to visible: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "showMenuBarIcon") != visible else { return }
        defaults.set(visible, forKey: "showMenuBarIcon")
        if !visible {
            showIconHiddenNotice(offerUndo: true)
        }
    }

    /// "Hide Menu Bar Icon" row: confirm (once), then hide.
    private func hideMenuBarIconRequested() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async {
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "suppressHideIconAlert") {
                defaults.set(false, forKey: "showMenuBarIcon")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Hide the menu bar icon?"
            alert.informativeText = """
                WindowShift keeps running in the background — modifier-drags still work.

                To bring the icon back, open WindowShift again (Spotlight, \
                Launchpad, or Finder), or run:
                defaults write dev.nwf.WindowShift showMenuBarIcon -bool true
                """
            alert.addButton(withTitle: "Hide Icon")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                defaults.set(true, forKey: "suppressHideIconAlert")
            }
            guard response == .alertFirstButtonReturn else { return }
            defaults.set(false, forKey: "showMenuBarIcon")
        }
    }

    /// Shown after the icon disappears without the menu-row confirmation
    /// (⌘-drag removal), so the app doesn't just silently vanish.
    private func showIconHiddenNotice(offerUndo: Bool) {
        guard !UserDefaults.standard.bool(forKey: "suppressHideIconAlert") else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "WindowShift's menu bar icon is hidden"
        alert.informativeText = """
            WindowShift keeps running in the background — modifier-drags still work.

            To bring the icon back, open WindowShift again (Spotlight, \
            Launchpad, or Finder), or run:
            defaults write dev.nwf.WindowShift showMenuBarIcon -bool true
            """
        alert.addButton(withTitle: "OK")
        if offerUndo {
            alert.addButton(withTitle: "Show Icon Again")
        }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "suppressHideIconAlert")
        }
        if response == .alertSecondButtonReturn {
            UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
        }
    }

    /// Launching the app while it's already running (Finder, Spotlight,
    /// `open -a WindowShift`) lands here — the standard way back in when the
    /// icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !UserDefaults.standard.bool(forKey: "showMenuBarIcon") {
            UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
        }
        return false
    }

    // MARK: - System events

    private func observeSessionSwitching() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.controller.sessionActive = false
        }
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.controller.sessionActive = true
        }
    }

    private func observePermissionLoss() {
        NotificationCenter.default.addObserver(
            forName: EventTap.permissionLostNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.captionView.setText("Accessibility permission lost — re-grant and relaunch")
            let alert = NSAlert()
            alert.messageText = "WindowShift lost its Accessibility permission"
            alert.informativeText = "Re-enable WindowShift under System Settings > Privacy & Security > Accessibility, then relaunch the app."
            alert.runModal()
        }
    }
}
