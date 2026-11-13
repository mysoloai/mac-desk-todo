# 使用与维护手册（v1）

> 面向日常使用与维护。架构与设计取舍见 [架构说明](architecture/app-shell.md) 与 [方案对比](design/app-v1-proposal.md)，
> 踩坑记录见 [lessons](lessons/)。

## 1. 安装与启动

```bash
bash scripts/build.sh   # 产出 build/DeskTodo.app（裸 swiftc，不依赖 Xcode 工程）
bash scripts/run.sh     # 先退旧实例，再整包替换并启动
```

- 常驻菜单栏；程序坞（Dock）图标默认常驻、可在设置页关闭；`⌥⌘N` 随时呼出/收起浮窗。
- 首次以新版本启动时，若同目录存在旧版 `todos.json`，会自动导入 SQLite 并改名归档（见第 3 节）。
- 单实例保护：`~/Library/Application Support/DeskTodo/instance.lock` 文件锁，重复启动会被拒绝。

## 2. 日常使用

| 操作 | 方式 |
|---|---|
| 新建 | 点列表空白处，直接输入 |
| 编辑 | 点条目文字，回车提交并自动进入下一条 |
| 完成 | 点左侧空心圆 → 实心对钩；再点一次取消 |
| 查创建时间 | 鼠标悬停在圆圈上，圆圈左侧弹出日期气泡 |
| 切视图 | 顶部 tab：待完成 / 全部 / 已完成 / 今日 / 前一日 / 后一日（记住上次选择，首次为「今日」） |
| 调整大小 | 拖拽浮窗左右边缘（贴边 7pt 内），支持设置页开关 |
| 外观 | 设置页：颜色色板 + 圆盘取色、字号滑条、主题（跟随系统/浅色/深色）、透明度、浮窗大小 |

数据变更即时生效，无需「保存」。偏好（颜色/字号/透明度/上次 tab/窗口位置）在 `UserDefaults`，
域为 `com.pliddo.deskTodo`。

### 开机自启与程序坞

- 两个开关都在设置页「启动与程序坞」区块，默认开启。
- 开机自启 = 一个登录项文件：`~/Library/LaunchAgents/com.pliddo.deskTodo.plist`（`RunAtLoad=true`，`ProgramArguments` 指向当前应用可执行文件）。**下一次登录生效**，当前会话不会额外拉起进程。
- 关闭自启：设置页取消勾选（应用会删掉该 plist）。只删文件但不开着再启动的话，下次启动会按「开关仍开启」重建。
- 应用被移动/重装到别的路径后，旧 plist 指向失效路径；下次启动会自动重写为当前路径（日志里搜 `DeskTodo 启动项`）。
- 从旧 bundle id 升级：`com.hustwsh.deskTodo.plist` 会被改名为 `*.plist.disabled-<时间戳>` 留在原目录，不删除。
- 程序坞图标：开启时为常规应用（`ApplicationType=Foreground`，可 Cmd+Tab）；关闭后回到纯菜单栏（`UIElement`）。点 Dock 图标等价于「显示待办」。

## 3. 数据与备份恢复

- 数据库：`~/Library/Application Support/DeskTodo/todos.sqlite`（WAL 模式，运行时会同时存在
  `todos.sqlite-wal` 与 `todos.sqlite-shm`）。
- 表：`todos(id TEXT PK, text, created_at REAL, completed INTEGER, completed_at REAL)`，
  `created_at` 建索引；`meta` 表存 `schema_version`。
- 备份（推荐，在线安全）：

```bash
sqlite3 ~/Library/Application\ Support/DeskTodo/todos.sqlite \
  "VACUUM INTO '/tmp/desk-todo-backup.sqlite'"
```

直接 `cp` 三个文件也可，但必须在应用退出后做（否则可能拷到不一致的 WAL 快照）。

- 恢复：退出应用 → 用备份覆盖 `todos.sqlite`（并删掉残留 `-wal`/`-shm`）→ 重新启动。
- 旧 JSON 迁移产物：`todos.json.legacy.bak`（原名保留，若重复迁移会带时间戳后缀）。
- 排查「条目莫名多出几条」：先看同目录是否还有 `todos.json` 被再次导入，以及 `.legacy.bak`。

## 4. 常见维护操作

```bash
# 只读查看全部条目（不改库）
sqlite3 ~/Library/Application\ Support/DeskTodo/todos.sqlite \
  "SELECT created_at, completed, text FROM todos ORDER BY created_at;"

# 导出为可读 SQL（先按第 3 节备份）
sqlite3 ~/Library/Application\ Support/DeskTodo/todos.sqlite .dump > /tmp/desk-todo-dump.sql
```

- 清理历史已完成条目属于破坏性操作，本版没有 UI 入口；如确需执行，先备份、停应用，再手工 `DELETE ... WHERE completed = 1`。
- 数据库结构变更（DDL）属非代码变更，需在 PR 说明与 CHANGELOG 中明确记录。

## 5. 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 启动后无菜单栏图标 | 已有一个实例在跑（文件锁） | `pgrep -x DeskTodo`；退出旧实例后重启 |
| 编辑后重启内容丢失 | 落库失败 | Console 搜索 `DeskTodo 落库失败`；检查磁盘空间与文件权限 |
| 「跟随系统」切了没变化 | 用户曾显式选过底色 | 切换主题会清除显式底色；选色后主题分段显示未选中属预期 |
| 浮窗被全屏 App 挡住 | 全屏辅助层行为开关 | 见 `docs/lessons/` 相关条目 |
| 包覆盖后启动即被杀 | ad-hoc 签名缓存失配 | 用 `scripts/run.sh` 整包替换，不要原地覆盖 |

## 6. 升级与回退

- 日常升级：`scripts/run.sh` 重新构建并整包替换；bundle id 固定 `com.pliddo.deskTodo`。
- 改 bundle id 时需同步 `Resources/Info.plist`、单实例通知名、偏好域迁移映射（见 `docs/lessons/` 与 AGENTS 约束），否则会出现双实例或偏好丢失。
- 回退到旧 JSON 版本：把 `todos.json.legacy.bak` 改回 `todos.json`，切回旧代码后启动即可（旧版只认 JSON）。

## 7. 已知限制与排除项（v1 明确不做）

- 无云同步、无账号、无多设备；数据只在本机。
- 无提醒/通知、无日历集成、无到期时间字段。
- 无导出 UI、无搜索、无标签；批量维护需手工 SQL（见第 4 节）。
- 单实例、单进程假设；不支持多进程并发写同一库。
- 开机自启只维护登录项文件，下一次登录才生效；不在当前会话热拉起。
- 无自动更新；升级靠重新构建/替换。

## 8. 开发与发布

```bash
bash scripts/build.sh
bash scripts/make-icon.sh                                # 改 Dock 图标时重新生成 AppIcon.icns
build/DeskTodo.app/Contents/MacOS/DeskTodo --selfcheck   # 逻辑 + 交互断言
build/DeskTodo.app/Contents/MacOS/DeskTodo --snapshot /tmp/dtd
bash scripts/regression.sh                               # 合并前必须通过
```

- 改动建议开分支、跑 `bash scripts/regression.sh` 后再合并；回归失败保留现场。
- 仓库：<https://github.com/mysoloai/mac-desk-todo>
