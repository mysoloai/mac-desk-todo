import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: TodoStore?
    private var panelController: TodoPanelController?
    private var hotKey: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?
    private let launchAtLogin = LaunchAtLogin()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selfcheck") {
            let ok = SelfCheck.run()
            exit(ok ? 0 : 1)
        }

        if let outputDirectory = Snapshot.outputDirectory(from: CommandLine.arguments) {
            Snapshot.run(outputDirectory: outputDirectory)
            exit(0)
        }

        let store = TodoStore()
        self.store = store
        panelController = TodoPanelController(store: store)

        setupStatusItem()

        // 程序坞常驻 + 开机自启（两个开关都在设置页，默认开启）
        applyDockIconPreference()
        syncLaunchAtLogin()
        NotificationCenter.default.addObserver(forName: AppSettings.didChange,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.applyDockIconPreference()
            self?.syncLaunchAtLogin()
        }

        // 再次启动时（被单实例逻辑挡下的那个进程）请已有实例把浮窗弹出来
        DistributedNotificationCenter.default().addObserver(forName: SingleInstance.showRequest,
                                                            object: nil,
                                                            queue: .main) { [weak self] _ in
            self?.panelController?.show()
        }

        // 系统外观切换（浅色/深色）时，跟随主题的浮窗要重新取色
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil,
                                                            queue: .main) { _ in
            if AppSettings.shared.themeMode == .system {
                NotificationCenter.default.post(name: AppSettings.didChange, object: nil)
            }
        }

        hotKey = HotKeyManager(keyCode: HotKeyManager.defaultKeyCode,
                               modifiers: HotKeyManager.defaultModifiers) { [weak self] in
            self?.panelController?.toggle()
        }

        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.panelController?.show()
            }
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.openSettingsAction()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flush()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// 点了 Dock 图标（没有可见窗口时）→ 重新呼出待办浮窗，而不是让应用停在「没有窗口」状态
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        return true
    }

    // MARK: - 启动项与程序坞

    /// Dock 图标由运行时激活策略决定：.regular 常驻 Dock，.accessory 回到纯菜单栏
    private func applyDockIconPreference() {
        let policy: NSApplication.ActivationPolicy = AppSettings.shared.dockIconEnabled ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// 设置开关变化时对齐登录项；应用被移动后旧 plist 指向失效路径，这里会重写
    private func syncLaunchAtLogin() {
        let notes = launchAtLogin.reconcile(enabled: AppSettings.shared.launchAtLogin)
        for note in notes {
            NSLog("DeskTodo 启动项：\(note)")
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "速签")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "速签 · ⌥⌘N 呼出待办"
        }
        statusItem = item
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            presentMenu()
        } else {
            panelController?.toggle()
        }
    }

    private func presentMenu() {
        guard let statusItem = statusItem else { return }
        let menu = NSMenu()
        menu.delegate = self

        let showItem = NSMenuItem(title: "显示待办", action: #selector(showPanelAction), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置", action: #selector(openSettingsAction), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "关于", action: #selector(showAboutAction), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出速签", action: #selector(quitAction), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    // MARK: - 菜单动作

    @objc private func showPanelAction() {
        panelController?.show()
    }

    @objc private func openSettingsAction() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "速签 DeskTodo"
        alert.informativeText = """
        版本 1.0.0

        菜单栏快速便签待办。⌥⌘N 随时呼出浮窗，点击条目即可编辑，实时保存。

        数据位置：~/Library/Application Support/DeskTodo/todos.sqlite
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quitAction() {
        store?.flush()
        NSApp.terminate(nil)
    }
}
