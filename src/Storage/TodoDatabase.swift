import Foundation
import SQLite3

/// 待办条目的 SQLite 持久层。
///
/// 职责边界：只负责「库里的行 ⟷ TodoItem」的搬运、库结构维护与事务；
/// 过滤、排序、空文本清洗等业务口径仍留在 TodoStore。
/// 单进程单连接（FULLMUTEX），条量级是几十～几百行，同步写开销可忽略。
final class TodoDatabase {
    enum DBError: Error, CustomStringConvertible {
        case open(path: String, code: Int32, message: String)
        case exec(code: Int32, message: String, sql: String)
        case prepare(code: Int32, message: String, sql: String)
        case step(code: Int32, message: String, sql: String)

        var description: String {
            switch self {
            case let .open(path, code, message):
                return "SQLite 打开失败(\(code)) \(path): \(message)"
            case let .exec(code, message, sql):
                return "SQLite 执行失败(\(code)): \(message) [\(sql.prefix(120))]"
            case let .prepare(code, message, sql):
                return "SQLite 预编译失败(\(code)): \(message) [\(sql.prefix(120))]"
            case let .step(code, message, sql):
                return "SQLite 读写失败(\(code)): \(message) [\(sql.prefix(120))]"
            }
        }
    }

    /// 绑定字符串时声明「SQLite 自己拷贝一份」，否则 Swift 字符串释放后游标悬垂
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let fileURL: URL
    private var handle: OpaquePointer?

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(fileURL.path,
                                 &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db = db { sqlite3_close(db) }
            throw DBError.open(path: fileURL.path, code: rc, message: message)
        }
        handle = opened
        // WAL：写入不阻塞读取，异常退出/掉电后靠 wal 日志恢复；NORMAL 在 WAL 下足够安全且更快
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA busy_timeout=5000;")
        try createSchema()
    }

    deinit {
        if let handle = handle { sqlite3_close(handle) }
    }

    // MARK: - 库结构

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS todos (
                id TEXT PRIMARY KEY NOT NULL,
                text TEXT NOT NULL,
                created_at REAL NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                completed_at REAL
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_todos_created_at ON todos(created_at);")
        try execute("INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '1');")
    }

    // MARK: - 读

    /// 全量载入（按创建时间升序）。坏行（id 不是 UUID 等）跳过，不让单行脏数据拖垮整个列表。
    func loadAll() throws -> [TodoItem] {
        let sql = "SELECT id, text, created_at, completed, completed_at FROM todos ORDER BY created_at ASC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            throw DBError.prepare(code: sqlite3_errcode(handle), message: currentMessage(), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }

        var items: [TodoItem] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DBError.step(code: rc, message: currentMessage(), sql: sql)
            }
            guard let idPointer = sqlite3_column_text(stmt, 0),
                  let textPointer = sqlite3_column_text(stmt, 1),
                  let id = UUID(uuidString: String(cString: idPointer)) else { continue }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let completed = sqlite3_column_int(stmt, 3) != 0
            let completedAt: Date? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            items.append(TodoItem(id: id,
                                  text: String(cString: textPointer),
                                  createdAt: createdAt,
                                  completed: completed,
                                  completedAt: completedAt))
        }
        return items
    }

    /// 当前行数（迁移判定与自检用）
    func rowCount() throws -> Int {
        let sql = "SELECT COUNT(*) FROM todos;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            throw DBError.prepare(code: sqlite3_errcode(handle), message: currentMessage(), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - 写

    func upsert(_ item: TodoItem) throws {
        let sql = """
            INSERT INTO todos(id, text, created_at, completed, completed_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                text = excluded.text,
                created_at = excluded.created_at,
                completed = excluded.completed,
                completed_at = excluded.completed_at;
            """
        try withStatement(sql) { stmt in
            _ = sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, Self.transient)
            _ = sqlite3_bind_text(stmt, 2, item.text, -1, Self.transient)
            _ = sqlite3_bind_double(stmt, 3, item.createdAt.timeIntervalSince1970)
            _ = sqlite3_bind_int(stmt, 4, item.completed ? 1 : 0)
            if let completedAt = item.completedAt {
                _ = sqlite3_bind_double(stmt, 5, completedAt.timeIntervalSince1970)
            } else {
                _ = sqlite3_bind_null(stmt, 5)
            }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DBError.step(code: rc, message: currentMessage(), sql: sql)
            }
        }
    }

    func delete(id: UUID) throws {
        let sql = "DELETE FROM todos WHERE id = ?;"
        try withStatement(sql) { stmt in
            _ = sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.transient)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DBError.step(code: rc, message: currentMessage(), sql: sql)
            }
        }
    }

    /// 批量写入（迁移导入用，包在一次事务里）
    func replaceAll(_ items: [TodoItem]) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("DELETE FROM todos;")
            for item in items {
                try upsert(item)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - 基础封装

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) } ?? currentMessage()
        if let errorMessage = errorMessage { sqlite3_free(errorMessage) }
        guard rc == SQLITE_OK else {
            throw DBError.exec(code: rc, message: message, sql: sql)
        }
    }

    private func withStatement(_ sql: String, body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            throw DBError.prepare(code: sqlite3_errcode(handle), message: currentMessage(), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }

    private func currentMessage() -> String {
        guard let handle = handle else { return "database closed" }
        return String(cString: sqlite3_errmsg(handle))
    }
}
