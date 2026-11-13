import AppKit
import Darwin

/// 单实例约束：同一份 JSON 不能被两个进程同时写。
/// 直接用 `DeskTodo.app/Contents/MacOS/DeskTodo` 启动时会绕过 LaunchServices，
/// Info.plist 里的 LSMultipleInstancesProhibited 不生效，因此这里用 flock 文件锁兜底。
enum SingleInstance {
    /// 已有实例收到此通知后把浮窗弹出来（跨进程投递）
    static let showRequest = Notification.Name("com.pliddo.deskTodo.showRequest")

    private static var lockHandle: FileHandle?

    /// 返回 true 表示当前进程拿到了锁；false 表示已有实例在跑，调用方应退出。
    static func claim(directory: URL? = nil) -> Bool {
        let fm = FileManager.default
        let dir = directory ?? defaultDirectory()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("instance.lock")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return true }
        if flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            lockHandle = handle
            return true
        }
        try? handle.close()
        return false
    }

    private static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DeskTodo", isDirectory: true)
    }
}
