# 应用外壳与数据流

## 模块

| 模块 | 职责 | 入口 |
|---|---|---|
| 启动与菜单栏 | 应用生命周期、状态项、菜单动作、单实例 | `src/main.swift`、`src/AppDelegate.swift` |
| 全局热键 | Carbon 注册 ⌥⌘N，回调切换浮窗 | `src/HotKeyManager.swift` |
| 浮窗 | 无边框 NSPanel、层级/跨 Space、位置持久化 | `src/Panel/TodoPanel.swift` |
| 浮窗内容 | 圆角底板、滚动列表、悬停浮层组装 | `src/Panel/TodoContentView.swift` |
| 列表画布 | 行布局、圆圈/文字/时间戳绘制、命中测试、行内编辑 | `src/Panel/TodoCanvasView.swift` |
| 顶部浮层 | 6 个视图 tab、关闭按钮、竖向透明度滑条 | `src/Panel/ChromeOverlayView.swift` |
| 数据层 | 条目模型、JSON 持久化、按视图过滤 | `src/TodoStore.swift` |
| 设置页 | 颜色/字号/实时样例 | `src/Settings/SettingsContentView.swift`、`SettingsWindowController.swift` |
| 配置 | 颜色、字号、透明度、tab、窗口位置 | `src/AppSettings.swift` |
| 自检 | `--selfcheck` 逻辑+交互断言；`--snapshot` 离屏渲染 | `src/Support/SelfCheck.swift`、`src/Support/Snapshot.swift` |

## 调用链

```
⌥⌘N → HotKeyManager → AppDelegate → TodoPanelController.toggle()
                                        ├─ show(): 激活 + makeKeyAndOrderFront + canvas.reflow
                                        └─ hide(): canvas.endEditing(commit) + 保存位置 + orderOut

鼠标 → ChromeOverlayView.hitTest（tab/关闭/滑条）
      → TodoCanvasView.mouseDown：圆圈=完成、行内=编辑、空白=拖动或新建
      → TodoCanvasView.endEditing → TodoStore.flush

设置页控件 → AppSettings（UserDefaults）→ 广播 .didChange
          → TodoContentView.applySettings → 浮窗重绘 + window.alphaValue
```

## 数据流

- 单条待办：`id(UUID) / text / createdAt / completed / completedAt`。
- 落盘：SQLite `~/Library/Application Support/DeskTodo/todos.sqlite`（WAL；表 `todos(id, text, created_at, completed, completed_at)`）。启动全量载入内存，变更只写单行；旧版 `todos.json` 在空库时一次性导入后改名 `*.legacy.bak`。
- 视图过滤：待完成 = 未完成；已完成 = 完成；全部 = 全量；今日/前一日/后一日 = 按 `Calendar` 自然日。
- 排序：一律按 `createdAt` 升序，新条目追加在末尾。

## 线程

全部 UI 与数据变更在主线程；`TodoStore` 把受影响的行标记为脏，`DispatchWorkItem` 合并 0.18s 后单行写 SQLite，`flush()` 立即落库。

## 启动参数

| 参数 | 作用 |
|---|---|
| `--show` | 启动后立即展示浮窗（调试/自动化） |
| `--selfcheck` | 跑逻辑与交互自检，退出码即结果 |
| `--snapshot <dir>` | 离屏渲染 `panel.png` / `settings.png` |
| `--settings` | 启动后直接打开设置窗口（调试） |

## 单实例

- Info.plist 的 `LSMultipleInstancesProhibited` 只在 LaunchServices 启动时生效；直接执行包内二进制时会被绕过。
- 因此 `main.swift` 启动即用 `flock` 抢 `~/Library/Application Support/DeskTodo/instance.lock`：
  抢到则正常启动，抢不到说明已有实例，此时用分布式通知让已有实例弹出浮窗，本进程退出。
- `--selfcheck` / `--snapshot` 属于离线任务，跳过抢锁，否则会被正在运行的实例挡掉而静默返回 0。

## 标识

- Bundle id：`com.pliddo.deskTodo`（组织前缀 `com.pliddo`）。历史版本用 `com.hustwsh.deskTodo`，`AppSettings` 首次启动会把旧偏好域里缺的键搬过来，旧域保留不删。
