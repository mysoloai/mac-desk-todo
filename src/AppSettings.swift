import AppKit

/// 全局配置：浮窗颜色、字号、透明度、窗口位置等，持久化到 UserDefaults。
final class AppSettings {
    static let shared = AppSettings()
    static let didChange = Notification.Name("AppSettingsDidChange")

    private let defaults: UserDefaults

    private init() {
        defaults = .standard
        migrateLegacyDefaultsIfNeeded()
        migrateLegacyThemeIfNeeded()
    }

    /// 老版本 bundle id 是 com.hustwsh.deskTodo，换域后把用户已有设置搬过来（只补新域缺的键）
    private func migrateLegacyDefaultsIfNeeded() {
        // 只迁一次：否则用户后来清掉的键会被旧域反复搬回来
        guard !defaults.bool(forKey: "legacyDomainMigrated") else { return }
        guard let legacy = UserDefaults(suiteName: "com.hustwsh.deskTodo") else {
            defaults.set(true, forKey: "legacyDomainMigrated")
            return
        }
        let keys = ["bgColor", "fontSize", "opacity", "lastTab",
                    "panelFrame", "panelOrigin", "panelResizable", "themeMode"]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "legacyDomainMigrated")
    }

    /// v2 及更早：底色默认值被当成用户选择写进了 bgColor，导致升级后「跟随系统」看不出效果。
    /// 首次带主题版本启动时，如果 bgColor 恰好是旧默认值，就清掉它。
    private func migrateLegacyThemeIfNeeded() {
        guard defaults.object(forKey: "themeMode") == nil else { return }
        if let hex = defaults.string(forKey: "bgColor"), ["#FFFFFF", "#F6F5F2"].contains(hex.uppercased()) {
            defaults.removeObject(forKey: "bgColor")
        }
        defaults.set(ThemeMode.system.rawValue, forKey: "themeMode")
    }

    private func notify() {
        NotificationCenter.default.post(name: AppSettings.didChange, object: nil)
    }

    /// 没选过自定义底色时，底色由主题决定：浅色 → 暖白，深色 → 近黑
    var backgroundColor: NSColor {
        get {
            if let hex = defaults.string(forKey: "bgColor"), let c = NSColor(hexString: hex) { return c }
            return themePrefersDark ? NSColor(hexString: "#1F1F22")! : NSColor(hexString: "#F6F5F2")!
        }
        set {
            defaults.set(newValue.hexString, forKey: "bgColor")
            notify()
        }
    }

    enum ThemeMode: String {
        case system, light, dark
    }

    /// 主题：跟随系统（默认）/ 浅色 / 深色
    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: defaults.string(forKey: "themeMode") ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "themeMode")
            // 主题是整体基调，切主题时放弃之前的自定义底色，否则切了也看不到变化
            defaults.removeObject(forKey: "bgColor")
            notify()
        }
    }

    /// 用户是否显式挑过底色（挑过就优先于主题）
    var hasExplicitColor: Bool { defaults.string(forKey: "bgColor") != nil }

    static var systemPrefersDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    var themePrefersDark: Bool {
        switch themeMode {
        case .system: return AppSettings.systemPrefersDark
        case .light: return false
        case .dark: return true
        }
    }

    /// 回到主题底色（清掉自定义色）
    func clearExplicitColor() {
        defaults.removeObject(forKey: "bgColor")
        notify()
    }

    var fontSize: CGFloat {
        get {
            let v = defaults.double(forKey: "fontSize")
            return v > 0 ? CGFloat(v) : 15
        }
        set {
            defaults.set(Double(newValue), forKey: "fontSize")
            notify()
        }
    }

    var opacity: CGFloat {
        get {
            let v = defaults.double(forKey: "opacity")
            return v > 0 ? CGFloat(min(max(v, 0.3), 1.0)) : 0.97
        }
        set {
            defaults.set(Double(min(max(newValue, 0.3), 1.0)), forKey: "opacity")
            notify()
        }
    }

    /// 上次停留的视图；默认「今日」，用户切过就记住
    var lastTab: TodoTab {
        get { TodoTab(rawValue: defaults.string(forKey: "lastTab") ?? "") ?? .today }
        set { defaults.set(newValue.rawValue, forKey: "lastTab") }
    }

    /// 浮窗整体 frame（位置 + 尺寸），下次启动原样恢复
    var panelFrame: NSRect? {
        get {
            if let s = defaults.string(forKey: "panelFrame") {
                let restored = NSRectFromString(s)
                if restored.width > 80, restored.height > 80 {
                    return restored
                }
            }
            // 兼容旧版只存 origin 的配置
            if let s = defaults.string(forKey: "panelOrigin") {
                let p = NSPointFromString(s)
                if p.x != 0 || p.y != 0 {
                    return NSRect(origin: p, size: TodoPanelController.defaultSize)
                }
            }
            return nil
        }
        set {
            if let value = newValue {
                defaults.set(NSStringFromRect(value), forKey: "panelFrame")
            } else {
                defaults.removeObject(forKey: "panelFrame")
            }
        }
    }

    /// 是否允许用鼠标拖拽改变浮窗大小
    var resizablePanel: Bool {
        get {
            if defaults.object(forKey: "panelResizable") == nil { return true }
            return defaults.bool(forKey: "panelResizable")
        }
        set {
            defaults.set(newValue, forKey: "panelResizable")
            notify()
        }
    }

    /// 浮窗是否始终置顶（悬浮在其他窗口之上）。默认关闭：需要时在设置页打开。
    var alwaysOnTopPanel: Bool {
        get {
            if defaults.object(forKey: "panelAlwaysOnTop") == nil { return false }
            return defaults.bool(forKey: "panelAlwaysOnTop")
        }
        set {
            defaults.set(newValue, forKey: "panelAlwaysOnTop")
            notify()
        }
    }

    /// 开机自动启动（默认开启）。真正的登录项文件由 LaunchAtLogin 维护。
    var launchAtLogin: Bool {
        get {
            if defaults.object(forKey: "launchAtLogin") == nil { return true }
            return defaults.bool(forKey: "launchAtLogin")
        }
        set {
            defaults.set(newValue, forKey: "launchAtLogin")
            notify()
        }
    }

    /// 程序坞（Dock）常驻图标（默认开启）。关闭后回到纯菜单栏形态。
    var dockIconEnabled: Bool {
        get {
            if defaults.object(forKey: "dockIconEnabled") == nil { return true }
            return defaults.bool(forKey: "dockIconEnabled")
        }
        set {
            defaults.set(newValue, forKey: "dockIconEnabled")
            notify()
        }
    }

    var panelOrigin: NSPoint? {
        get {
            guard let s = defaults.string(forKey: "panelOrigin") else { return nil }
            let p = NSPointFromString(s)
            return (p.x == 0 && p.y == 0) ? nil : p
        }
        set {
            if let v = newValue { defaults.set(NSStringFromPoint(v), forKey: "panelOrigin") }
        }
    }

    // MARK: - 主题色

    /// 是否深色底（用于自动切换文字颜色）
    var isDarkBackground: Bool {
        guard let c = backgroundColor.usingColorSpace(.sRGB) else { return false }
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum < 0.45
    }

    var textColor: NSColor {
        isDarkBackground ? NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
                          : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
    }

    var secondaryTextColor: NSColor {
        isDarkBackground ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0.35, alpha: 0.55)
    }

    var hairlineColor: NSColor {
        isDarkBackground ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.10)
    }

    var chromeFillColor: NSColor {
        isDarkBackground ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.05)
    }

    var borderColor: NSColor {
        isDarkBackground ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.12)
    }

    /// 10 个默认预设底色
    static let presetColors: [NSColor] = [
        NSColor(hexString: "#F6F5F2")!,   // 暖白（默认，替代刺眼纯白）
        NSColor(hexString: "#FFF9F0")!,   // 象牙
        NSColor(hexString: "#FFF1DE")!,   // 米黄
        NSColor(hexString: "#FFECEF")!,   // 樱花
        NSColor(hexString: "#EAF7EF")!,   // 薄荷
        NSColor(hexString: "#E8F1FB")!,   // 天蓝
        NSColor(hexString: "#F0ECFA")!,   // 薰衣草
        NSColor(hexString: "#EDEFF3")!,   // 浅灰
        NSColor(hexString: "#3A3A3C")!,   // 石墨
        NSColor(hexString: "#1C1C1E")!    // 深空
    ]
}

extension NSColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                  green: CGFloat((v >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(v & 0xFF) / 255.0,
                  alpha: 1.0)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    func blended(over other: NSColor, fraction: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: a.redComponent * fraction + b.redComponent * (1 - fraction),
                       green: a.greenComponent * fraction + b.greenComponent * (1 - fraction),
                       blue: a.blueComponent * fraction + b.blueComponent * (1 - fraction),
                       alpha: 1)
    }
}
