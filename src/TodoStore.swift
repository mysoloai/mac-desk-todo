import Foundation

/// 浮窗顶部可切换的视图范围。
enum TodoTab: String, CaseIterable {
    case pending, all, done, today, yesterday, tomorrow

    var title: String {
        switch self {
        case .pending: return "待完成"
        case .all: return "全部"
        case .done: return "已完成"
        case .today: return "今日"
        case .yesterday: return "前一日"
        case .tomorrow: return "后一日"
        }
    }

    var emptyHint: String {
        switch self {
        case .pending: return "待办都清完了，点击空白处记一条"
        case .all: return "还没有待办，点击空白处开始记录"
        case .done: return "还没有已完成的待办"
        case .today: return "今天还没有记录"
        case .yesterday: return "前一日没有记录"
        case .tomorrow: return "后一日没有记录"
        }
    }
}

struct TodoItem: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var completed: Bool
    var completedAt: Date?

    init(id: UUID = UUID(),
         text: String,
         createdAt: Date = Date(),
         completed: Bool = false,
         completedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.completed = completed
        self.completedAt = completedAt
    }
}

/// 待办数据源：SQLite 落盘（按行增量写），内存保留全量副本供 UI 同步读取与过滤。
///
/// 与旧 JSON 实现的差别：不再整表重写文件，变更只写受影响的单行；
/// 编辑仍保留 0.18s 合并窗口，避免每次按键都触发一次 I/O。
final class TodoStore {
    static let databaseFileName = "todos.sqlite"
    private static let legacyFileName = "todos.json"

    private(set) var items: [TodoItem] = []
    let databaseURL: URL
    /// 最近一次落库/载入错误。旧实现用 `try?` 静默吞错，这里保留可观测句柄供应用与自检读取。
    private(set) var lastPersistError: String?
    /// 一次性迁移说明（有旧 JSON 被导入时填写），便于日志与自检断言
    private(set) var migrationNote: String?

    private let database: TodoDatabase?
    private var dirtyIDs: Set<UUID> = []
    private var pendingSave: DispatchWorkItem?

    init(databaseURL: URL? = nil) {
        let resolved = databaseURL ?? TodoStore.defaultDatabaseURL()
        self.databaseURL = resolved

        var opened: TodoDatabase?
        do {
            opened = try TodoDatabase(fileURL: resolved)
        } catch {
            lastPersistError = "\(error)"
            NSLog("DeskTodo 存储初始化失败：\(error)")
        }
        self.database = opened

        if let db = opened {
            do {
                migrationNote = try migrateLegacyJSONIfNeeded(into: db)
            } catch {
                lastPersistError = "\(error)"
                NSLog("DeskTodo 旧 JSON 迁移失败：\(error)")
            }
        }
        reload()
    }

    // MARK: - 路径

    static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("DeskTodo", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func defaultDatabaseURL() -> URL {
        defaultDirectory().appendingPathComponent(databaseFileName)
    }

    // MARK: - 查询

    func item(id: UUID) -> TodoItem? {
        items.first { $0.id == id }
    }

    func items(for tab: TodoTab) -> [TodoItem] {
        let cal = Calendar.current
        let now = Date()
        switch tab {
        case .pending:
            return sorted(items.filter { !$0.completed })
        case .done:
            return sorted(items.filter { $0.completed })
        case .all:
            return sorted(items)
        case .today:
            return sorted(items.filter { cal.isDate($0.createdAt, inSameDayAs: now) })
        case .yesterday:
            guard let d = cal.date(byAdding: .day, value: -1, to: now) else { return [] }
            return sorted(items.filter { cal.isDate($0.createdAt, inSameDayAs: d) })
        case .tomorrow:
            guard let d = cal.date(byAdding: .day, value: 1, to: now) else { return [] }
            return sorted(items.filter { cal.isDate($0.createdAt, inSameDayAs: d) })
        }
    }

    private func sorted(_ list: [TodoItem]) -> [TodoItem] {
        list.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - 变更

    @discardableResult
    func add(text: String, at date: Date = Date(), completed: Bool = false) -> TodoItem {
        let item = TodoItem(text: text,
                            createdAt: date,
                            completed: completed,
                            completedAt: completed ? date : nil)
        items.append(item)
        scheduleSave(id: item.id)
        return item
    }

    func update(id: UUID, text: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].text != text else { return }
        items[idx].text = text
        scheduleSave(id: id)
    }

    func toggle(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].completed.toggle()
        items[idx].completedAt = items[idx].completed ? Date() : nil
        scheduleSave(id: id)
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        dirtyIDs.remove(id)
        guard let database = database else { return }
        do {
            try database.delete(id: id)
        } catch {
            reportPersistError(error)
        }
    }

    /// 新条目是否落在当前视图范围内（不在则切到「待完成」）
    func contains(tab: TodoTab, item: TodoItem) -> Bool {
        items(for: tab).contains(where: { $0.id == item.id })
    }

    // MARK: - 持久化

    private func reload() {
        guard let database = database else {
            items = []
            return
        }
        do {
            items = try database.loadAll().filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        } catch {
            reportPersistError(error)
            items = []
        }
    }

    /// 编辑中的条目合并 0.18s 写一次；只标记受影响的行，不再整表重写
    private func scheduleSave(id: UUID) {
        dirtyIDs.insert(id)
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitDirty() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// 立即落库（结束编辑、退出应用、测试前调用）
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        commitDirty()
    }

    private func commitDirty() {
        guard let database = database else {
            dirtyIDs.removeAll()
            return
        }
        let pending = dirtyIDs
        dirtyIDs.removeAll()
        for id in pending {
            // 条目已被删除时无需再写：delete(id:) 已同步删行
            guard let item = items.first(where: { $0.id == id }) else { continue }
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                if trimmed.isEmpty {
                    // 编辑清空后库里也删掉，避免重载时「只有时间戳没有字」的行复活
                    try database.delete(id: id)
                } else {
                    try database.upsert(item)
                }
            } catch {
                reportPersistError(error)
            }
        }
    }

    private func reportPersistError(_ error: Error) {
        lastPersistError = "\(error)"
        NSLog("DeskTodo 落库失败：\(error)")
    }

    // MARK: - 旧数据迁移

    /// 旧版把待办存在同目录 todos.json。库还是空的且 JSON 有内容时导入一次，
    /// 成功后把 JSON 改名保留（绝不删除用户数据）。
    private func migrateLegacyJSONIfNeeded(into database: TodoDatabase) throws -> String? {
        let fm = FileManager.default
        let legacyURL = databaseURL.deletingLastPathComponent().appendingPathComponent(Self.legacyFileName)
        guard fm.fileExists(atPath: legacyURL.path) else { return nil }
        guard try database.rowCount() == 0 else { return nil }

        guard let data = try? Data(contentsOf: legacyURL) else {
            return "旧 JSON 无法读取，已跳过迁移"
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([TodoItem].self, from: data) else {
            return "旧 JSON 解析失败，已跳过迁移（文件保留）"
        }
        let usable = decoded.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !usable.isEmpty {
            try database.replaceAll(usable)
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var backupURL = legacyURL.appendingPathExtension("legacy.bak")
        if fm.fileExists(atPath: backupURL.path) {
            backupURL = legacyURL.deletingPathExtension()
                .appendingPathExtension("legacy-\(stamp).bak")
        }
        do {
            try fm.moveItem(at: legacyURL, to: backupURL)
        } catch {
            return "已导入 \(usable.count) 条，但旧 JSON 改名失败（文件保留在原处）：\(error)"
        }
        return "已从旧 JSON 导入 \(usable.count) 条，备份为 \(backupURL.lastPathComponent)"
    }
}
