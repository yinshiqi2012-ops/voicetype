import CoreGraphics
import Foundation

/// 把识别结果注入当前光标位置。
///
/// 用 `CGEvent` 合成 Unicode 键盘事件；需要「辅助功能」权限才能向其他应用投递事件。
///
/// 投放点用 `.cghidEventTap`（HID 级，等价于真实键盘），而不是
/// `.cgAnnotatedSessionEventTap` —— 后者是给「标注」用的，很多应用在有权限时
/// 依然不会把它当成真实按键，表现为「不报错但没有字」。
enum TextInjector {
    /// 单次投递的字符数上限，过长的字符串部分应用会丢字。
    private static let chunkSize = 20
    private static let chunkInterval: TimeInterval = 0.008

    @discardableResult
    static func insert(_ text: String) -> Bool {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return false }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        var index = 0
        var posted = false
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            posted = post(Array(units[index..<end]), source: source) || posted
            index = end
            if index < units.count {
                Thread.sleep(forTimeInterval: chunkInterval)
            }
        }
        return posted
    }

    private static func post(_ units: [UInt16], source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }

        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
