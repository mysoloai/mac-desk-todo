# AppKit 浮窗实现踩坑

## 1. 自建 NSClipView 默认白底，把深色浮窗盖掉

- **坑**：为让滚动从顶部开始，用 `FlippedClipView` 替换 `scrollView.contentView` 后，深色底浮窗下半部分变成白底、浅色文字不可见。
- **根因**：`NSClipView.drawsBackground` 默认 true；`scrollView.drawsBackground = false` 只作用于它自己，不会同步到替换进来的 clip view。
- **解法**：替换 clip view 后显式 `clip.drawsBackground = false`。
- **位置**：`src/Panel/TodoContentView.swift`；证据 A（深色底快照复现并修复）。

## 2. 无边框透明窗口的 ad-hoc 包覆盖安装会被 taskgated 杀掉

- **坑**：对已运行的 `.app` 做原地文件覆盖，新进程启动即被 SIGKILL，`codesign -v` 却仍显示有效。
- **根因**：系统签名缓存与包内文件 inode 绑定，原地覆盖导致缓存失配。
- **解法**：编译到 `build/.stage-DeskTodo.app`，签名后再整包替换（`rm -rf 旧包` + `mv`），并在启动脚本里先退出旧实例。
- **位置**：`scripts/build.sh`、`scripts/run.sh`；证据 A。

## 3. 非激活面板的第一次点击会被吞掉

- **坑**：浮窗从其他应用唤出后，第一次点击圆圈/文字没有反应，要再点一次。
- **根因**：应用不在前台时，NSView 默认 `acceptsFirstMouse` 返回 false。
- **解法**：画布与顶部浮层都实现 `acceptsFirstMouse(for:) -> true`。
- **位置**：`src/Panel/TodoCanvasView.swift`、`src/Panel/ChromeOverlayView.swift`；证据 B（API 语义确定，未逐帧录屏）。

## 4. 滚动区与顶部浮层必须分层

- **坑**：列表滚动到顶部时文字穿透半透明顶栏，压在圆角上。
- **解法**：`NSScrollView` 整体下移到 `topInset` 之下，浮层独立成 `ChromeOverlayView` 覆盖在窗口坐标上；画布自身只保留 10pt 顶部内边距。
- **位置**：`src/Panel/TodoContentView.swift`；证据 A（快照）。

## 空文本待办会被写进 JSON

- 坑：新建条目先 `add(text:)` 再进入编辑，若进程被强杀在编辑中，JSON 里留下「只有时间戳没有文字」的行，重启后表现为一个空圆圈行。
- 解法：`writeToDisk()` 过滤空白文本（空条目只存在于内存），`load()` 再过滤一次兜底；断言写进 `--selfcheck`。
- 位置：`src/TodoStore.swift`；验证：`DeskTodo --selfcheck` 中「空文本条目不应落盘」。

## borderless 浮窗的缩放要自己做

- 坑：给无边框 NSPanel 加 `styleMask.insert(.resizable)` 后拖边缘仍然不变大——系统只在有边框的窗口上提供边缘缩放热区。
- 解法：加一层 `ResizeEdgeView` 覆盖全窗口，`hitTest` 只在离边缘 7pt 内返回自己，其余返回 nil 让事件下传；`mouseDragged` 按 `NSEvent.mouseLocation` 的位移改 frame，并对 `minSize` 做钳制；`resetCursorRects` 画双向箭头光标。
- 位置：`src/Panel/ResizeEdgeView.swift`；验证：真机拖右边缘/左边缘，`windowDidResize` 里落盘 frame。

## 行内日期气泡必须是独立窗口

- 坑：圆圈在 x=34，圆圈左侧根本放不下日期文本；如果画在卡片内会被裁掉，或者为了放气泡把左留白撑大，列表就不再紧凑。
- 解法：日期用独立的小 NSPanel（level = floating+1、`ignoresMouseEvents = true`、不抢 key），把圆圈的屏幕坐标换算出来放在它左侧；左边界放不下时翻到圆圈右侧。
- 位置：`src/Panel/DateBubbleController.swift`；触发：`TodoCanvasView.updateHover` 命中圆圈外扩 4pt；滚动/切视图/编辑/移出都要主动收起，否则气泡会停在旧位置。

## 「跟随系统主题」要跟显式配色解耦

- 坑：主题切换（跟随系统/浅色/深色）和「用户挑过的底色」是两个来源，如果都写同一个 `bgColor`，升级后旧默认值会一直盖住主题，看起来「跟随系统没反应」。
- 解法：`bgColor` 只表示显式选择；没写过就按 `themeMode` 派生底色（浅色 `#F6F5F2` / 深色 `#1F1F22`）。切换主题时移除 `bgColor`，用户挑色时写入 `bgColor` 并把主题分段显示为未选中。首次带主题的版本启动时，若 `bgColor` 恰是旧默认（`#FFFFFF`/`#F6F5F2`）就清掉，做一次性迁移。
- 系统深浅变化用 `AppleInterfaceThemeChangedNotification`（DistributedNotificationCenter）触发重绘；只在 `themeMode == .system` 时响应。
- 位置：`src/AppSettings.swift`、`src/Settings/SettingsContentView.swift`、`src/AppDelegate.swift`。
