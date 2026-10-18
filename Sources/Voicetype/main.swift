import AppKit

// SPM 的 main.swift 顶层代码是非隔离上下文，而 NSApplication 与 AppDelegate 都在主 actor 上。
// 进程启动即运行在主线程，用 assumeIsolated 显式声明这一事实。
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
