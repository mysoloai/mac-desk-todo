# macOS 开机自启（LaunchAgent）与 Dock 常驻

## 1. ad-hoc 签名 + 用户目录的应用别用 SMAppService

- **坑**：想用 macOS 13+ 的 `SMAppService.mainApp.register()` 做开机自启，注册直接返回 `Operation not permitted`，开关看起来打开但重启后不生效。
- **根因**：`SMAppService` 面向正规签名、通常安装在 `/Applications` 的应用；本项目是 ad-hoc 签名、跑在用户目录（甚至是 worktree 的 build 目录）。
- **解法**：改用 `~/Library/LaunchAgents/<bundle-id>.plist`（`RunAtLoad=true`、`ProgramArguments` 指向 `Bundle.main.executableURL`）。登录时 launchd 自动加载目录内的 plist，不依赖签名与服务注册。
- **位置**：`src/Support/LaunchAtLogin.swift`；证据 A（真机 plist 写入 + 重启前状态核对）。

## 2. 不要在应用运行期间 `launchctl bootstrap/bootout`

- **坑**：开开关时 bootstrap 会立刻再拉起一个实例（被单实例锁挡下，但会闪一下浮窗）；关开关时 bootout 作用于已加载的 job，可能把正在运行的自己杀掉。
- **解法**：只维护 plist 文件，语义定为「下次登录生效」；`isEnabled` 用「文件存在 + Label 正确 + 可执行路径等于当前路径」判断，不用 `launchctl list`。
- **位置**：`src/Support/LaunchAtLogin.swift`；证据 A（双向开关真机验证）。

## 3. 登录项必须校验可执行路径，应用移动后自动重写

- **坑**：应用从 worktree 的 `build/` 合并到主仓 `build/`（或用户拖到 `/Applications`）后，旧 plist 仍指向已删除的路径：登录时静默失败，用户以为自启坏了。
- **解法**：`isEnabled` 比较 `ProgramArguments[0]` 与当前 `executableURL` 的标准化路径；不匹配即视为未启用，启动时 `reconcile(enabled:)` 重写。合并 worktree 后从主仓启动一次即可完成校准（已实测）。
- **位置**：`src/Support/LaunchAtLogin.swift`；验证：自检「路径变化后旧项不算启用且 reconcile 重写」。

## 4. 换 bundle id 后旧登录项会拉起旧身份

- **坑**：bundle id 从 `com.hustwsh.deskTodo` 改成 `com.pliddo.deskTodo` 后，旧的 `com.hustwsh.deskTodo.plist` 还在，登录时拉起旧名字/旧路径的实例，出现双实例与偏好分裂。
- **解法**：`reconcile` 里扫描 `legacyLabels`，把旧 plist 改名为 `*.plist.disabled-<时间戳>`（不删除用户文件），同时写新 label 的 plist。
- **位置**：`src/Support/LaunchAtLogin.swift`；证据 A（自检预置旧 plist 后归档）。

## 5. Dock 常驻图标 = 运行时激活策略 + 真实图标资源

- **坑**：`LSUIElement=true` 的纯菜单栏应用直接加 Dock 图标会显示白纸占位图；上线后用户第一眼就是「没图标」。
- **解法**：运行时 `NSApp.setActivationPolicy(.regular)`（关掉回 `.accessory`），并在 `Resources/AppIcon.icns` 提供 16~1024 全尺寸图标（`Info.plist` 的 `CFBundleIconFile` + 构建时复制进包）。加 `applicationShouldHandleReopen`，点 Dock 图标重新呼出浮窗。
- **位置**：`src/AppDelegate.swift`、`scripts/make-icon.swift`、`scripts/make-icon.sh`；验证：`lsappinfo` 显示 `Foreground`/`UIElement` 双向切换。
