# 本地 SQLite 存储踩坑

## 1. 旧 JSON 迁移会让「干净环境」的测试基准失真

- **坑**：把 JSON 换成 SQLite 并加了「库空则从旧 JSON 导入」后，自检首次跑就失败「新增一条后待完成应只有 1 条」——探针目录里残留上一版测试写的 `todos.json`，迁移被正常触发。
- **根因**：迁移是产品正确行为，测试环境没清干净；失败信息看起来像业务 bug，判断方向容易被带偏。
- **解法**：自检/快照这类探针在开始时清空整个探针目录（而不只是删目标 db 文件）；迁移用例单独用一个子目录端到端造数据。看到「计数多出未知条目」时先查同目录旧数据文件与 `.legacy.bak`。
- **位置**：`src/Support/SelfCheck.swift`（`removeItem(at: dir)` + `migrate-probe` 子目录）；证据 A。

## 2. 删 SQLite 库文件要连 `-wal` / `-shm` 一起删

- **坑**：只 `removeItem(at: dbURL)` 后重开，偶尔还能读到上一轮的数据或残留状态。
- **根因**：WAL 模式下数据可能还在 `todos.sqlite-wal` 里，主库文件被删但日志仍在，新的同名库打开时会尝试恢复。
- **解法**：删除时对 `${path}`、`${path}-wal`、`${path}-shm` 一起清理；只做测试清理，不动用户数据。
- **位置**：`src/Support/SelfCheck.swift` 的 `removeDatabase(at:)`；证据 A。

## 3. `sqlite3_bind_text` 不传 `SQLITE_TRANSIENT` 会留下悬垂指针

- **坑**：绑定的 Swift `String` 在 `step` 前被释放，写入偶发乱码或崩溃，或错误只在 Release 下出现。
- **根因**：SQLite 默认按「静态字符串」处理，不拷贝；Swift 临时字符串生命周期不可控。
- **解法**：每个文本绑定都传 `unsafeBitCast(-1, to: sqlite3_destructor_type.self)`，让 SQLite 自己拷贝。
- **位置**：`src/Storage/TodoDatabase.swift`（`TodoDatabase.transient`）；证据 A（编译检查 + 自检写读往返）。

## 4. 不要用 `try?` 吞掉落库错误

- **坑**：旧 JSON 实现 `guard let data = try? encoder.encode(...) else { return }` 后静默 return，写盘失败完全不可见，表现为「编辑过的条目重启后消失」。
- **解法**：持久层抛出带 SQL 片段与 `sqlite3_errmsg` 的错误；`TodoStore` 捕获后写 `NSLog` 并暴露 `lastPersistError`，自检断言其为 nil。
- **位置**：`src/Storage/TodoDatabase.swift`（`DBError`）、`src/TodoStore.swift`（`reportPersistError`）；证据 A。
