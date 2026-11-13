import AppKit

/// 应用内自检：用真实的 TodoStore / AppSettings 走一遍核心逻辑，供回归门禁调用。
enum SelfCheck {
    static func run() -> Bool {
        var failures: [String] = []
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("desk-todo-selfcheck")
        // 每次自检从干净目录开始：残留的旧版 todos.json 会被迁移逻辑正常导入，从而污染基准计数
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("todos.sqlite")
        removeDatabase(at: url)

        let store = TodoStore(databaseURL: url)
        if let error = store.lastPersistError {
            failures.append("SQLite 存储初始化失败：\(error)")
        }

        // 新增
        let first = store.add(text: "测试条目 A")
        if store.items(for: .pending).count != 1 {
            failures.append("新增一条后「待完成」应只有 1 条")
        }

        // 编辑 + 实时落盘 + 重新加载
        store.update(id: first.id, text: "测试条目 A（已改）")
        store.flush()
        let reloaded = TodoStore(databaseURL: url)
        if reloaded.item(id: first.id)?.text != "测试条目 A（已改）" {
            failures.append("编辑后落盘/重载不一致")
        }

        // 完成切换后的过滤
        store.toggle(id: first.id)
        if store.items(for: .pending).count != 0 || store.items(for: .done).count != 1 {
            failures.append("标记完成后「待完成/已完成」过滤不对")
        }
        store.toggle(id: first.id)
        if store.items(for: .pending).count != 1 {
            failures.append("取消完成后应回到「待完成」")
        }

        // 空条目删除
        let blank = store.add(text: "   ")
        store.delete(id: blank.id)
        if store.items.contains(where: { $0.id == blank.id }) {
            failures.append("空白条目应可删除")
        }

        // 空文本条目不落盘、重载后不复活
        store.add(text: "")
        store.flush()
        let reloadedBlank = TodoStore(databaseURL: url)
        if reloadedBlank.items.contains(where: { $0.text.isEmpty }) {
            failures.append("空文本条目不应落盘")
        }

        // 日期分组：前一日 / 今日
        let cal = Calendar.current
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) else {
            failures.append("日历计算前一日失败")
            return finish(failures)
        }
        store.add(text: "昨天的事", at: yesterday)
        store.add(text: "今天的事", at: Date())
        if store.items(for: .yesterday).isEmpty {
            failures.append("「前一日」应包含昨天创建的条目")
        }
        if store.items(for: .today).isEmpty {
            failures.append("「今日」应包含今天创建的条目")
        }

        // 排序：按创建时间升序
        let ordered = store.items(for: .all)
        guard let firstDate = ordered.first?.createdAt, let lastDate = ordered.last?.createdAt else {
            failures.append("「全部」取不到条目")
            return finish(failures)
        }
        if firstDate > lastDate {
            failures.append("「全部」应按创建时间升序排列")
        }

        // 存储层：真实 SQLite 文件、旧 JSON 一次性迁移、二次启动不重复导入
        if !isSQLiteFile(at: url) {
            failures.append("待办数据文件不是 SQLite 格式")
        }
        if let error = store.lastPersistError {
            failures.append("写入过程中落库报错：\(error)")
        }

        let migrateDir = dir.appendingPathComponent("migrate-probe")
        try? fm.removeItem(at: migrateDir)
        try? fm.createDirectory(at: migrateDir, withIntermediateDirectories: true)
        let legacyURL = migrateDir.appendingPathComponent("todos.json")
        let migratedDBURL = migrateDir.appendingPathComponent("todos.sqlite")
        let legacyItems: [TodoItem] = [
            TodoItem(text: "迁移条目 1", createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            TodoItem(text: "迁移条目 2", createdAt: Date(timeIntervalSince1970: 1_700_000_100)),
        ]
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        if let data = try? legacyEncoder.encode(legacyItems) {
            try? data.write(to: legacyURL)
            let migrated = TodoStore(databaseURL: migratedDBURL)
            if migrated.items.count != legacyItems.count {
                failures.append("旧 JSON 迁移条数不对（期望 \(legacyItems.count)，实际 \(migrated.items.count)）")
            }
            if migrated.migrationNote == nil {
                failures.append("旧 JSON 迁移没有留下说明")
            }
            if fm.fileExists(atPath: legacyURL.path) {
                failures.append("迁移后旧 JSON 应改名保留，而不是留在原路径")
            }
            if let error = migrated.lastPersistError {
                failures.append("迁移过程报错：\(error)")
            }
            let secondOpen = TodoStore(databaseURL: migratedDBURL)
            if secondOpen.items.count != legacyItems.count {
                failures.append("二次启动重复导入或丢数据（实际 \(secondOpen.items.count) 条）")
            }
            if secondOpen.migrationNote != nil {
                failures.append("库非空时不应再次执行迁移")
            }
        } else {
            failures.append("构造迁移用旧 JSON 失败")
        }

        // 配置项：颜色与字号的读写往返
        let settings = AppSettings.shared
        let hadExplicitColor = settings.hasExplicitColor
        let originalColor = settings.backgroundColor
        let originalTheme = settings.themeMode
        let originalSize = settings.fontSize
        settings.backgroundColor = NSColor(hexString: "#123456") ?? .white
        settings.fontSize = 21
        if settings.backgroundColor.hexString != "#123456" {
            failures.append("浮窗颜色读写不一致")
        }
        if abs(settings.fontSize - 21) > 0.01 {
            failures.append("字号读写不一致")
        }
        // 主题：默认跟随系统；系统是深色就出深色底 + 浅色字；显式底色优先，切主题会清掉它
        if settings.themeMode != .system {
            failures.append("主题默认应为「跟随系统」")
        }
        settings.themeMode = .dark
        if !settings.isDarkBackground {
            failures.append("深色主题下底色应是深的")
        }
        if settings.textColor.usingColorSpace(.sRGB)!.redComponent < 0.5 {
            failures.append("深色主题下文字应切到浅色")
        }
        settings.themeMode = .light
        if settings.isDarkBackground || settings.backgroundColor.hexString != "#F6F5F2" {
            failures.append("浅色主题下应是暖白底 + 深色字")
        }
        settings.backgroundColor = NSColor(hexString: "#3A3A3C")!
        if !settings.hasExplicitColor {
            failures.append("选过底色后应记为显式底色")
        }
        settings.themeMode = .system
        if settings.hasExplicitColor {
            failures.append("切换主题后应清掉显式底色，让主题生效")
        }
        if settings.themePrefersDark != AppSettings.systemPrefersDark {
            failures.append("跟随系统主题没有跟随当前系统外观")
        }

        // 透明度从浮窗挪到设置页后，读写仍然生效
        let originalOpacity = settings.opacity
        settings.opacity = 0.42
        if abs(settings.opacity - 0.42) > 0.01 {
            failures.append("透明度读写不一致")
        }
        settings.opacity = originalOpacity

        settings.themeMode = originalTheme
        if hadExplicitColor {
            settings.backgroundColor = originalColor
        } else {
            settings.clearExplicitColor()
        }
        settings.fontSize = originalSize

        // 启动项与程序坞：默认开启；LaunchAgent 只写临时目录，不碰用户真实 ~/Library/LaunchAgents
        if !AppSettings.shared.launchAtLogin {
            failures.append("开机自动启动应默认开启")
        }
        if !AppSettings.shared.dockIconEnabled {
            failures.append("程序坞图标应默认常驻")
        }

        let launchDir = dir.appendingPathComponent("launch-probe")
        try? fm.removeItem(at: launchDir)
        let fakeExecutable = dir.appendingPathComponent("FakeDeskTodo")
        let login = LaunchAtLogin(agentsDirectory: launchDir, executableURL: fakeExecutable)
        if login.isEnabled {
            failures.append("尚未写入时登录项不应显示为已启用")
        }
        if let error = login.enable() {
            failures.append("写入登录项失败：\(error)")
        }
        if !login.isEnabled {
            failures.append("写入登录项后应处于启用状态")
        }
        if let data = try? Data(contentsOf: login.plistURL),
           let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let plist = object as? [String: Any] {
            if plist["RunAtLoad"] as? Bool != true {
                failures.append("登录项缺少 RunAtLoad，开机不会自启")
            }
            if (plist["ProgramArguments"] as? [String])?.first != fakeExecutable.path {
                failures.append("登录项指向的可执行路径不对")
            }
        } else {
            failures.append("登录项 plist 无法读取")
        }

        // 应用被移动后旧 plist 仍存在但路径失效，应按未启用处理并由 reconcile 重写
        let movedExecutable = dir.appendingPathComponent("MovedDeskTodo")
        let moved = LaunchAtLogin(agentsDirectory: launchDir, executableURL: movedExecutable)
        if moved.isEnabled {
            failures.append("可执行文件路径变化后旧登录项不应算启用")
        }
        if moved.reconcile(enabled: true).isEmpty || !moved.isEnabled {
            failures.append("路径失效时启动对齐应重写登录项")
        }

        // 旧 bundle id 的登录项必须失效（改名归档），否则登录会拉起旧身份
        let legacyPlist = launchDir.appendingPathComponent("com.hustwsh.deskTodo.plist")
        try? Data("legacy".utf8).write(to: legacyPlist)
        _ = moved.reconcile(enabled: true)
        if fm.fileExists(atPath: legacyPlist.path) {
            failures.append("旧 bundle id 的登录项应被改名归档")
        }

        if let error = moved.disable() {
            failures.append("移除登录项失败：\(error)")
        }
        if fm.fileExists(atPath: moved.plistURL.path) {
            failures.append("关闭后登录项文件应被移除")
        }

        // 构造设置页不应改写已有配置（曾因丢色板/颜色面板同步反写导致默认值被覆盖）
        let colorBefore = settings.backgroundColor.hexString
        let sizeBefore = settings.fontSize
        let settingsView = SettingsContentView(frame: NSRect(origin: .zero,
                                                            size: SettingsWindowController.contentSize))
        settingsView.layout()
        if settings.backgroundColor.hexString != colorBefore || abs(settings.fontSize - sizeBefore) > 0.01 {
            failures.append("构造设置页改写了浮窗颜色或字号")
        }

        // 默认视图：没选过时是「今日」，选过就记住
        let savedTab = settings.lastTab
        settings.lastTab = .today
        let freshContent = TodoContentView(store: store)
        if freshContent.canvas.tab != .today {
            failures.append("首次打开浮窗默认应停在「今日」")
        }
        settings.lastTab = .done
        let rememberedContent = TodoContentView(store: store)
        if rememberedContent.canvas.tab != .done {
            failures.append("切换过的视图没有被记住")
        }
        settings.lastTab = savedTab

        // 字号漂移后的布局：不应崩溃且行高变化
        let content = TodoContentView(store: store)
        content.frame = NSRect(origin: .zero, size: TodoPanelController.panelSize)
        content.canvas.setFrameSize(NSSize(width: TodoPanelController.panelSize.width,
                                           height: TodoPanelController.panelSize.height))
        content.canvas.setTab(.all)
        if content.canvas.contentHeight <= NoteTheme.topInset {
            failures.append("列表内容高度未随条目增长")
        }

        // 浮窗位置与尺寸记忆 + 可缩放开关
        let savedFrame = settings.panelFrame
        let savedResizable = settings.resizablePanel
        let probeFrame = NSRect(x: 120, y: 200, width: 430, height: 300)
        settings.panelFrame = probeFrame
        if settings.panelFrame != probeFrame {
            failures.append("浮窗 frame 读写往返不一致")
        }
        settings.resizablePanel = false
        if settings.resizablePanel {
            failures.append("可缩放开关读写不一致")
        }
        settings.resizablePanel = savedResizable
        settings.panelFrame = savedFrame

        // 浮窗置顶：默认关闭；开关变化后窗口层级立刻跟随（普通 ↔ 浮动）
        if UserDefaults.standard.object(forKey: "panelAlwaysOnTop") == nil && settings.alwaysOnTopPanel {
            failures.append("浮窗置顶应默认关闭")
        }
        let savedAlwaysOnTop = settings.alwaysOnTopPanel
        let topmostPanel = TodoPanelController(store: store)
        settings.alwaysOnTopPanel = false
        if topmostPanel.panel.level != .normal || topmostPanel.panel.isFloatingPanel {
            failures.append("关闭浮窗置顶时应为普通窗口层级")
        }
        settings.alwaysOnTopPanel = true
        if topmostPanel.panel.level != .floating || !topmostPanel.panel.isFloatingPanel {
            failures.append("开启浮窗置顶后浮窗应浮在其他窗口之上")
        }
        settings.alwaysOnTopPanel = savedAlwaysOnTop

        if TodoPanelController.defaultSize.height > TodoPanelController.panelSize.height + 0.5 {
            failures.append("默认浮窗高度没有下调")
        }
        if TodoPanelController.defaultSize.height != 264 {
            failures.append("默认浮窗高度应为 264（初版 528 的一半）")
        }

        // 设置窗口可构造且尺寸正确（不弹窗，避免自检干扰桌面）
        let settingsController = SettingsWindowController()
        if let window = settingsController.window {
            let contentSize = window.contentView?.frame.size ?? .zero
            if abs(contentSize.width - SettingsWindowController.contentSize.width) > 0.5
                || abs(contentSize.height - SettingsWindowController.contentSize.height) > 0.5 {
                failures.append("设置窗口内容尺寸不是 460×700（实际 \(contentSize)）")
            }
            if !(window.contentView is SettingsContentView) {
                failures.append("设置窗口内容视图类型不对")
            }
        } else {
            failures.append("设置窗口未创建")
        }

        // 单实例锁：同一目录第二次 claim 必须失败
        let lockDir = dir.appendingPathComponent("lock-probe")
        if !SingleInstance.claim(directory: lockDir) {
            failures.append("单实例锁首次获得失败")
        }
        if SingleInstance.claim(directory: lockDir) {
            failures.append("单实例锁没有阻止第二个实例")
        }

        interactionChecks(&failures)
        return finish(failures)
    }

    /// 交互层自检：用合成鼠标事件走真实的命中测试与编辑生命周期
    private static func interactionChecks(_ failures: inout [String]) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("desk-todo-selfcheck")
        let url = dir.appendingPathComponent("interaction.sqlite")
        removeDatabase(at: url)
        let store = TodoStore(databaseURL: url)

        let size = TodoPanelController.defaultSize
        let content = TodoContentView(store: store)
        content.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        content.canvas.setFrameSize(NSSize(width: size.width, height: size.height - NoteTheme.topInset))
        content.canvas.reflow()

        // 1. 点空白 → 新建并进入编辑态
        click(in: window, view: content.canvas, viewPoint: NSPoint(x: 200, y: size.height - 70))
        if store.items.count != 1 {
            failures.append("空白处单击应新建 1 条待办（实际 \(store.items.count)）")
        }
        if !content.canvas.isEditing {
            failures.append("新建后应自动进入编辑态")
        }

        // 2. 输入内容 → 实时写入数据层
        if let editor = content.canvas.activeEditor {
            editor.string = "点出来的条目"
            content.canvas.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
            if store.items.first?.text != "点出来的条目" {
                failures.append("编辑内容未实时写入数据层")
            }
        } else {
            failures.append("编辑态下没有可用的输入框")
        }

        // 2.5 回车 → 当前条目落盘，光标跳到新条目；不应出现换行
        if let editor = content.canvas.activeEditor as? TodoTextEditor {
            editor.insertNewline(nil)
            if let committed = store.items.first(where: { $0.text == "点出来的条目" }) {
                if committed.text.contains("\n") {
                    failures.append("回车不应在条目里插入换行")
                }
            } else {
                failures.append("回车后当前条目没有落盘")
            }
            if !content.canvas.isEditing {
                failures.append("回车后应自动进入下一条的输入状态")
            }
            if store.items.count != 2 {
                failures.append("回车后应新增一条待输入条目（实际 \(store.items.count) 条）")
            }
        } else {
            failures.append("回车测试拿不到输入框")
        }

        // 3. 点圆圈 → 标记完成
        content.canvas.endEditing(commit: true)
        content.canvas.reflow()
        if let circle = content.canvas.circleRectForRow(at: 0) {
            click(in: window, view: content.canvas, viewPoint: NSPoint(x: circle.midX, y: circle.midY))
            if store.items.first?.completed != true {
                failures.append("单击空心圆未切换为已完成")
            }
        } else {
            failures.append("定位不到第一行圆圈")
        }

        // 4. 切 tab → 浮层选中态与列表同步
        content.setTab(.done)
        if content.chrome.selectedTab != .done {
            failures.append("切换 tab 后浮层选中态未同步")
        }
        if store.items(for: .done).isEmpty {
            failures.append("「已完成」视图应能看到刚标记完成的条目")
        }
    }

    private static func click(in window: NSWindow, view: NSView, viewPoint: NSPoint) {
        let windowPoint = view.convert(viewPoint, to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [],
                                    timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        if let down = down { view.mouseDown(with: down) }
        if let up = up { view.mouseUp(with: up) }
    }

    /// 删库时要连 -wal / -shm 一起清掉，否则残留日志会让新连接读到旧数据
    private static func removeDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }

    /// 校验文件头是否为 SQLite 3 数据库（前 16 字节固定为 "SQLite format 3\0"）
    private static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = Data([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
                          0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00])
        let head = handle.readData(ofLength: magic.count)
        return head == magic
    }

    private static func finish(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("SELF-CHECK PASS")
            return true
        }
        print("SELF-CHECK FAIL:")
        failures.forEach { print("  - \($0)") }
        return false
    }
}
