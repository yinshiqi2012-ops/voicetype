import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics

/// 三类系统权限的查询与申请。
enum Permissions {
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var hasMicrophone: Bool { microphoneStatus == .authorized }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static var canPostEvents: Bool { CGPreflightPostEventAccess() }
    static var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// 弹出系统引导（把本应用加入辅助功能列表），需用户手动开启。
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool { CGRequestListenEventAccess() }

    @discardableResult
    static func requestPostEvents() -> Bool { CGRequestPostEventAccess() }

    static func microphoneLabel() -> String {
        switch microphoneStatus {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未决定"
        @unknown default: return "未知"
        }
    }

    static let accessibilitySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let inputMonitoringSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    static let microphoneSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    static func openSettings(for urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
