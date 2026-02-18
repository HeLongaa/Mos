//
//  ButtonUtils.swift
//  Mos
//  按钮绑定工具类 - 获取配置和管理绑定
//  Created by Claude on 2025/8/10.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa

class ButtonUtils {

    // 单例
    static let shared = ButtonUtils()
    init() {}

    // MARK: - 获取按钮绑定配置

    /// 获取当前应用的按钮绑定配置
    /// - Returns: 按钮绑定列表
    func getButtonBindings() -> [ButtonBinding] {
        // 预留: 未来支持分应用配置
        // if let app = getTargetApplication(),
        //    let appBindings = app.buttons?.binding {
        //     return appBindings
        // }

        // 使用全局配置
        return Options.shared.buttons.binding
    }

    // MARK: - 组合键/单键消歧状态
    // 用于解决「同一按键既有单键绑定又有组合键绑定」时的优先级问题
    // 当按键按下时，若该按键也是某组合键的 holdButton，则延迟单键执行到按键抬起时

    /// 待定状态: 按下但尚未执行的按键 (等待判断是单键还是组合键 holdButton)
    /// Key: 鼠标按键码, Value: (原始事件, 本次按下期间是否已触发了组合键)
    var pendingHoldState: [UInt16: (event: CGEvent, comboTriggered: Bool)] = [:]

    /// 检查指定按键是否被任何已启用的组合键绑定用作 holdButton
    func hasComboBindings(forHoldButton code: UInt16) -> Bool {
        return getButtonBindings().contains {
            $0.holdButton == code && $0.isEnabled && $0.targetShortcut != nil
        }
    }

    /// 重置待定状态（ButtonCore 停用时调用）
    func resetPendingHoldState() {
        pendingHoldState = [:]
    }

    // MARK: - 分应用支持 (预留接口)

    /// 获取当前焦点应用的配置对象 (预留)
    /// - Returns: Application 对象或 nil
    private func getTargetApplication() -> Application? {
        // 预留: 未来实现类似 ScrollUtils.getTargetApplication 的逻辑
        // let runningApp = NSWorkspace.shared.frontmostApplication
        // return Options.shared.application.applications.first { $0.bundleId == runningApp?.bundleIdentifier }
        return nil
    }
}
