import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// 自检 / 离屏快照是纯离线任务，不写真实数据，也不占单实例锁（否则会被正在运行的实例挡掉）
let isOfflineTask = CommandLine.arguments.contains("--selfcheck")
    || Snapshot.outputDirectory(from: CommandLine.arguments) != nil

// 已有实例在跑时：把浮窗请出来，本进程直接退出，避免两个进程写同一份数据
if !isOfflineTask, !SingleInstance.claim() {
    DistributedNotificationCenter.default().postNotificationName(SingleInstance.showRequest,
                                                                object: nil,
                                                                userInfo: nil,
                                                                deliverImmediately: true)
    usleep(80_000)
    exit(0)
}

let appDelegate = AppDelegate()
application.delegate = appDelegate

application.run()
