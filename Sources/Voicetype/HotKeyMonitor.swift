import CoreGraphics
import Foundation

/// 基于 CGEventTap 的「按一下开始 / 再按一下结束」热键。
///
/// 触发条件：**Option + Command 同时按下**（左右 Option / 左右 Command 均可）。
/// 只在一对键刚刚被同时按下时触发一次；按住不放不会连续触发。
///
/// 监听其他应用的键盘事件需要「输入监控」权限；缺失时 `start()` 返回 false。
/// 用 `.listenOnly`，不消费事件，系统自带的 ⌘⌥ 快捷键不受影响。
final class HotKeyMonitor {
    private let onToggle: () -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// 上一帧是否处于「组合键按下」状态，用于做边沿检测。
    private var comboWasDown = false

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    /// 回调在创建此 tap 的 run loop（主线程）上触发。
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        source = nil
        comboWasDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // 被系统临时禁用期间可能漏掉了抬起事件，重置边沿状态避免卡在"已按下"。
            comboWasDown = false
            return
        }
        guard type == .flagsChanged else { return }

        let flags = event.flags
        let comboDown = flags.contains(.maskAlternate) && flags.contains(.maskCommand)

        if comboDown {
            guard !comboWasDown else { return }
            comboWasDown = true
            onToggle()
        } else {
            comboWasDown = false
        }
    }
}
