import Foundation

/// 开机自启：写 `~/Library/LaunchAgents/com.pliddo.deskTodo.plist`，登录时由 launchd 加载。
///
/// 为什么不用 SMAppService：本项目是 ad-hoc 签名、安装在用户目录而不是 /Applications，
/// `SMAppService.mainApp.register()` 对这类包常返回 Operation not permitted。
/// LaunchAgent 只依赖一个 plist 文件，本地自建应用上最稳，也便于用户手工移除。
///
/// 为什么不在当前会话里 `launchctl bootstrap/bootout`：
/// 应用此刻本来就在运行——bootstrap 会再拉起一个进程（被单实例锁挡下但会闪一下浮窗），
/// bootout 反而可能把正在运行的自己杀掉。开关语义是「下次登录时生效」，只维护文件即可。
final class LaunchAtLogin {
    static let label = "com.pliddo.deskTodo"
    /// 历史 bundle id 的登录项，升级后必须让它们失效，否则登录时会拉起旧身份的二进制
    static let legacyLabels = ["com.hustwsh.deskTodo"]

    private let agentsDirectory: URL
    private let executableURL: URL
    private let fm = FileManager.default

    /// agentsDirectory / executableURL 可注入：自检用临时目录验证，不碰用户真实登录项
    init(agentsDirectory: URL? = nil, executableURL: URL? = nil) {
        let home = fm.homeDirectoryForCurrentUser
        self.agentsDirectory = agentsDirectory
            ?? home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.executableURL = executableURL
            ?? Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    }

    var plistURL: URL {
        agentsDirectory.appendingPathComponent("\(Self.label).plist")
    }

    /// 登录项是否真的指向「这个」可执行文件。应用被移动后旧 plist 仍存在但路径失效，
    /// 这种情况按未启用处理，交给 reconcile 重写。
    var isEnabled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any],
              plist["Label"] as? String == Self.label,
              let arguments = plist["ProgramArguments"] as? [String],
              let program = arguments.first else { return false }
        return URL(fileURLWithPath: program).standardizedFileURL
            == executableURL.standardizedFileURL
    }

    @discardableResult
    func enable() -> String? {
        do {
            try fm.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": Self.label,
                "ProgramArguments": [executableURL.path],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            return nil
        } catch {
            return "写入开机登录项失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func disable() -> String? {
        guard fm.fileExists(atPath: plistURL.path) else { return nil }
        do {
            try fm.removeItem(at: plistURL)
            return nil
        } catch {
            return "移除开机登录项失败：\(error.localizedDescription)"
        }
    }

    /// 启动时对齐：开关要与磁盘状态一致；顺手让旧 bundle id 的登录项失效（改名归档，不删除）。
    @discardableResult
    func reconcile(enabled: Bool) -> [String] {
        var notes: [String] = []

        for legacy in Self.legacyLabels {
            let legacyURL = agentsDirectory.appendingPathComponent("\(legacy).plist")
            guard fm.fileExists(atPath: legacyURL.path) else { continue }
            let stamp = Self.timestamp()
            let archived = agentsDirectory.appendingPathComponent("\(legacy).plist.disabled-\(stamp)")
            if (try? fm.moveItem(at: legacyURL, to: archived)) != nil {
                notes.append("旧登录项已归档：\(archived.lastPathComponent)")
            } else {
                notes.append("旧登录项归档失败：\(legacyURL.lastPathComponent)")
            }
        }

        if enabled {
            if !isEnabled {
                if let error = enable() {
                    notes.append(error)
                } else {
                    notes.append("已写入登录项：\(plistURL.lastPathComponent)")
                }
            }
        } else if fm.fileExists(atPath: plistURL.path) {
            if let error = disable() {
                notes.append(error)
            } else {
                notes.append("已移除登录项：\(plistURL.lastPathComponent)")
            }
        }
        return notes
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
