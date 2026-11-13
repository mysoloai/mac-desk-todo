import AppKit

/// 离屏渲染：把浮窗 / 设置页画成 PNG，用于无人值守的布局自检（不依赖录屏权限）。
enum Snapshot {
    static func outputDirectory(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--snapshot") else { return nil }
        if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
            return arguments[index + 1]
        }
        return "/tmp/desk-todo-snapshot"
    }

    private final class BackdropView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0.905, green: 0.906, blue: 0.92, alpha: 1).setFill()
            bounds.fill()
        }
    }

    @discardableResult
    static func render(_ view: NSView, size: NSSize, to path: String) -> Bool {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        // 快照要跟当前主题一致（系统深色 → 深色页）
        window.appearance = NSAppearance(named: AppSettings.shared.themePrefersDark ? .darkAqua : .aqua)

        let backdrop = BackdropView(frame: NSRect(origin: .zero, size: size))
        window.contentView = backdrop
        backdrop.addSubview(view)
        view.frame = NSRect(origin: .zero, size: size)

        backdrop.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    static func run(outputDirectory: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        let demoURL = URL(fileURLWithPath: outputDirectory).appendingPathComponent("demo-todos.sqlite")
        try? fm.removeItem(at: demoURL)
        let store = TodoStore(databaseURL: demoURL)
        let now = Date()
        store.add(text: "把本周项目周报收尾，风险项单独列一段", at: now.addingTimeInterval(-9000))
        store.add(text: "买牛奶和鸡蛋，顺路把快递取了", at: now.addingTimeInterval(-7200))
        store.add(text: "给妈妈打个电话", at: now.addingTimeInterval(-5400), completed: true)
        store.add(text: "读《战国策》秦策一，做三页读书笔记；顺手把下周复盘提纲列出来，尽量写具体一点", at: now.addingTimeInterval(-3600))
        store.add(text: "和产品对齐浮窗透明度与字的交互细节", at: now.addingTimeInterval(-600))
        store.flush()

        let content = TodoContentView(store: store)
        content.frame = NSRect(origin: .zero, size: TodoPanelController.panelSize)
        content.setChromeActive(true)
        // 快照要可复现：显式指定视图，且不写回用户的「上次视图」偏好
        content.canvas.setTab(.pending)
        content.chrome.selectedTab = .pending
        content.canvas.setFrameSize(NSSize(width: TodoPanelController.panelSize.width,
                                           height: TodoPanelController.panelSize.height))
        content.canvas.reflow()
        render(content, size: TodoPanelController.panelSize, to: outputDirectory + "/panel.png")

        // 「全部」视图：同时展示空心圆（未完成）与实心对钩（已完成）
        content.canvas.setTab(.all)
        content.chrome.selectedTab = .all
        content.canvas.reflow()
        render(content, size: TodoPanelController.panelSize, to: outputDirectory + "/panel-all.png")

        let settingsView = SettingsContentView(frame: NSRect(origin: .zero, size: SettingsWindowController.contentSize))
        render(settingsView, size: SettingsWindowController.contentSize, to: outputDirectory + "/settings.png")

        print("snapshot written to \(outputDirectory)")
    }
}
