import Foundation
import ServiceManagement

/// 开机自启动项（`SMAppService.mainApp`）：登录后自动启动本 App，
/// 让右 Option 热键常驻可用，无需每次手动打开。
enum LoginItem {
    enum State {
        case enabled
        case disabled
        /// 已注册，但还需用户在「系统设置 → 通用 → 登录项」中允许。
        case requiresApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        default:
            return .disabled
        }
    }

    /// 注册 / 注销开机自启；操作失败时抛错，由调用方转成菜单提示。
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}
