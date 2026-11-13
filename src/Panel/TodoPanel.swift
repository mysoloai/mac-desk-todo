import AppKit

/// 无边框、可成 key window 的浮窗（是否置顶由设置决定）
final class TodoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TodoPanelController: NSObject, NSWindowDelegate {
    let store: TodoStore
    let panel: TodoPanel
    let content: TodoContentView

    /// 默认尺寸：高度为初版 528 的一半，列表依旧从顶栏下方开始滚动
    static let defaultSize = NSSize(width: 400, height: 264)
    /// 面板允许的最小尺寸（再小顶栏 tab 会挤在一起）
    static let minSize = NSSize(width: 340, height: 200)
    /// 兼容旧代码里的 panelSize 语义（= 默认尺寸）
    static let panelSize = defaultSize

    init(store: TodoStore) {
        self.store = store
        panel = TodoPanel(contentRect: NSRect(origin: .zero, size: TodoPanelController.defaultSize),
                          styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                          backing: .buffered,
                          defer: false)
        content = TodoContentView(store: store)
        super.init()

        panel.delegate = self
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = AppSettings.shared.opacity
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.minSize = TodoPanelController.minSize
        panel.setFrame(restoredFrame(), display: false)

        content.onClose = { [weak self] in self?.hide() }
        content.onResizePolicyChange = { [weak self] in self?.applyResizePolicy() }
        applyResizePolicy()
        applyWindowLevelPolicy()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsChanged),
                                               name: AppSettings.didChange,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 显示 / 隐藏

    func show() {
        clampIntoVisibleScreen()
        panel.alphaValue = AppSettings.shared.opacity
        content.applySettings()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        content.focus()
        content.canvas.reflow()
    }

    func hide() {
        content.canvas.endEditing(commit: true)
        content.canvas.hideDateBubble()
        saveFrame()
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - 尺寸 / 位置

    /// 是否允许鼠标拖拽改变大小（AppKit 的边框窗口默认靠边框拖拽，borderless 需要自己接管）
    func applyResizePolicy() {
        let resizable = AppSettings.shared.resizablePanel
        var mask = panel.styleMask
        if resizable {
            mask.insert(.resizable)
        } else {
            mask.remove(.resizable)
        }
        panel.styleMask = mask
        content.resizingEnabled = resizable
    }

    /// 窗口层级：默认普通层级（不压住别的窗口），开启「浮窗置顶」后浮到其他窗口之上
    func applyWindowLevelPolicy() {
        let onTop = AppSettings.shared.alwaysOnTopPanel
        panel.level = onTop ? .floating : .normal
        panel.isFloatingPanel = onTop
    }

    @objc private func settingsChanged() {
        applyWindowLevelPolicy()
    }

    /// 默认位置：贴着屏幕左侧中上部，不再右边角
    static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = TodoPanelController.defaultSize
        return NSRect(x: screen.minX + 24,
                      y: screen.maxY - size.height - 24,
                      width: size.width,
                      height: size.height)
    }

    private func restoredFrame() -> NSRect {
        guard let stored = AppSettings.shared.panelFrame else { return TodoPanelController.defaultFrame() }
        let size = NSSize(width: max(stored.width, TodoPanelController.minSize.width),
                          height: max(stored.height, TodoPanelController.minSize.height))
        return NSRect(origin: stored.origin, size: size)
    }

    private func clampIntoVisibleScreen() {
        var frame = panel.frame
        frame.size.width = max(frame.width, TodoPanelController.minSize.width)
        frame.size.height = max(frame.height, TodoPanelController.minSize.height)

        let isVisible = NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(frame)
            return !intersection.isNull && intersection.width > 80 && intersection.height > 80
        }
        if !isVisible {
            frame = TodoPanelController.defaultFrame()
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func saveFrame() {
        guard panel.isVisible || panel.frame.size.width > 0 else { return }
        let frame = panel.frame
        let onScreen = NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(frame)
            return !intersection.isNull && intersection.width > 60 && intersection.height > 60
        }
        guard onScreen else { return }
        AppSettings.shared.panelFrame = frame
        AppSettings.shared.panelOrigin = frame.origin
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible else { return }
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        guard panel.isVisible else { return }
        saveFrame()
    }
}
