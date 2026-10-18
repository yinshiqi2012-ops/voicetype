import CoreGraphics
import Foundation

/// 基于 CGEventTap 的「按住说话」热键监听。
///
/// 只监听 `flagsChanged`（修饰键按下/抬起），据此区分右 Option 的按下与松开。
/// 监听其他应用的键盘事件需要「输入监控」权限；缺失时 `start()` 返回 false。
final class HotKeyMonitor {
    private let onDown: () -> Void
    private let onUp: () -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isPressed = false

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.onDown = onDown
        self.onUp = onUp
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
        isPressed = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Config.pushToTalkKeyCode else { return }

        let pressed = event.flags.contains(.maskAlternate)
        if pressed, !isPressed {
            isPressed = true
            onDown()
        } else if !pressed, isPressed {
            isPressed = false
            onUp()
        }
    }
}
