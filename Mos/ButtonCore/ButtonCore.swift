//
//  ButtonCore.swift
//  Mos
//  鼠标按钮事件截取与处理核心类
//  Created by Claude on 2025/8/10.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa

class ButtonCore {

    // 单例
    static let shared = ButtonCore()
    init() { NSLog("Module initialized: ButtonCore") }

    // 执行状态
    var isActive = false

    // 拦截层
    var eventInterceptor: Interceptor?
    // 独立的倾斜/垂直滚轮拦截器 (高优先级, 在 ScrollCore 之前执行)
    var tiltEventInterceptor: Interceptor?

    // 组合的按钮事件掩码 (DOWN + UP, UP 用于单键/组合键消歧)
    let leftDown    = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    let rightDown   = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
    let otherDown   = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
    let leftUp      = CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
    let rightUp     = CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
    let otherUp     = CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
    let keyDown     = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let flagsChanged = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    var eventMask: CGEventMask {
        return leftDown | rightDown | otherDown | leftUp | rightUp | otherUp | keyDown
    }
    let tiltEventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

    // MARK: - 按钮事件处理
    let buttonEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        let utils = ButtonUtils.shared
        let bindings = utils.getButtonBindings()
        let mouseCode = event.mouseCode

        // ── MOUSE UP: 完成单键延迟执行 ──────────────────────────────────────
        if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
            guard let pending = utils.pendingHoldState[mouseCode] else {
                return Unmanaged.passUnretained(event)
            }
            utils.pendingHoldState.removeValue(forKey: mouseCode)
            // 本次按住期间未触发任何组合键 → 执行单键快捷键
            if !pending.comboTriggered {
                let sorted = bindings.sorted { ($0.holdButton != nil ? 0 : 1) < ($1.holdButton != nil ? 0 : 1) }
                if let binding = sorted.first(where: {
                    $0.triggerEvent.matches(pending.event) && $0.isEnabled && $0.holdButton == nil
                }), let shortcut = binding.targetShortcut, shortcut.type == .keyboard {
                    let code = shortcut.code
                    let flags = UInt64(shortcut.modifiers)
                    DispatchQueue.main.async {
                        ShortcutExecutor.shared.execute(code: code, flags: flags)
                    }
                }
            }
            return nil  // DOWN 已被消费, UP 同步消费
        }

        // ── MOUSE DOWN / KEY DOWN ────────────────────────────────────────────
        // 有 holdButton 的绑定优先匹配（更具体），避免单键绑定抢先触发
        let sorted = bindings.sorted { ($0.holdButton != nil ? 0 : 1) < ($1.holdButton != nil ? 0 : 1) }

        // 查找匹配的绑定 (触发事件匹配 + 已启用 + holdButton 条件满足)
        guard let binding = sorted.first(where: {
            guard $0.triggerEvent.matches(event) && $0.isEnabled else { return false }
            if let holdCode = $0.holdButton {
                // 优先检查 pendingHoldState:
                // 若 holdButton 的 DOWN 事件已被我们的 tap 消费 (因为它有单键绑定),
                // 则 NSEvent.pressedMouseButtons 在 session 层不再包含该按键,
                // 但 pendingHoldState 记录了它确实被物理按下。
                if utils.pendingHoldState[holdCode] != nil { return true }
                // 回退: holdButton 无单键绑定时 DOWN 事件未被消费, 可从 IOKit 查询
                return (NSEvent.pressedMouseButtons >> Int(holdCode)) & 1 == 1
            }
            return true
        }), let shortcut = binding.targetShortcut, shortcut.type == .keyboard else {
            return Unmanaged.passUnretained(event)
        }

        if let holdCode = binding.holdButton {
            // ── 组合键匹配: 立即执行, 并标记 holdButton 的待定状态为「已触发组合键」 ──
            // 防止 holdButton 抬起时误触发单键快捷键
            var pending = utils.pendingHoldState[holdCode]
            if pending != nil {
                pending!.comboTriggered = true
                utils.pendingHoldState[holdCode] = pending
            }
            let code = shortcut.code
            let flags = UInt64(shortcut.modifiers)
            DispatchQueue.main.async {
                ShortcutExecutor.shared.execute(code: code, flags: flags)
            }
            return nil  // 消费触发事件
        } else {
            // ── 单键匹配 ──────────────────────────────────────────────────────
            if event.isMouseEvent && utils.hasComboBindings(forHoldButton: mouseCode) {
                // 该按键同时是某组合键的 holdButton → 延迟到 UP 执行（等待可能的组合键）
                utils.pendingHoldState[mouseCode] = (event, false)
                return nil  // 消费 DOWN, UP 时判断是否执行
            }
            // 无组合冲突: 立即执行
            let code = shortcut.code
            let flags = UInt64(shortcut.modifiers)
            DispatchQueue.main.async {
                ShortcutExecutor.shared.execute(code: code, flags: flags)
            }
            return nil
        }
    }

    // MARK: - 倾斜滚轮及垂直滚轮事件处理
    // 使用独立高优先级拦截器, 在 ScrollCore 消费事件之前匹配绑定
    let tiltEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        // 仅处理滚轮事件
        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        let utils = ButtonUtils.shared
        let bindings = utils.getButtonBindings()

        // 有 holdButton 的绑定优先匹配（更具体）
        let sorted = bindings.sorted { ($0.holdButton != nil ? 0 : 1) < ($1.holdButton != nil ? 0 : 1) }

        // 查找匹配的绑定 (倾斜或垂直滚轮, 且需要满足 holdButton 条件)
        guard let binding = sorted.first(where: {
            guard $0.triggerEvent.matches(event) && $0.isEnabled else { return false }
            if let holdCode = $0.holdButton {
                // 优先检查 pendingHoldState (holdButton 的 DOWN 被 tap 消费时 pressedMouseButtons 不可靠)
                if utils.pendingHoldState[holdCode] != nil { return true }
                return (NSEvent.pressedMouseButtons >> Int(holdCode)) & 1 == 1
            }
            // 垂直滚轮不允许作为独立触发器 (仅允许倾斜滚轮独立触发)
            if event.isVerticalScrollEvent { return false }
            return true
        }), let shortcut = binding.targetShortcut, shortcut.type == .keyboard else {
            return Unmanaged.passUnretained(event)
        }

        // 滚轮触发了组合键 → 标记 holdButton 的待定状态, 防止抬起时误触发单键
        if let holdCode = binding.holdButton {
            var pending = utils.pendingHoldState[holdCode]
            if pending != nil {
                pending!.comboTriggered = true
                utils.pendingHoldState[holdCode] = pending
            }
        }

        // 异步执行目标键盘快捷键
        let code = shortcut.code
        let flags = UInt64(shortcut.modifiers)
        DispatchQueue.main.async {
            ShortcutExecutor.shared.execute(code: code, flags: flags)
        }

        // 消费事件(不再传递给 ScrollCore 或系统)
        return nil
    }

    // MARK: - 启用和禁用

    // 启用按钮监控
    func enable() {
        if !isActive {
            NSLog("ButtonCore enabled")
            do {
                // 主拦截器: 鼠标按键和键盘事件
                // 使用 cgSessionEventTap.headInsertEventTap 以确保在 Logitech 等驱动层
                // 处理按键默认动作之前抢先拦截, 从而能真正阻断原始事件
                eventInterceptor = try Interceptor(
                    event: eventMask,
                    handleBy: buttonEventCallBack,
                    listenOn: .cgSessionEventTap,
                    placeAt: .headInsertEventTap,
                    for: .defaultTap
                )
                // 倾斜/垂直滚轮拦截器: 使用 cgSessionEventTap.headInsertEventTap
                // 确保在 ScrollCore 消费滚轮事件之前优先处理绑定
                tiltEventInterceptor = try Interceptor(
                    event: tiltEventMask,
                    handleBy: tiltEventCallBack,
                    listenOn: .cgSessionEventTap,
                    placeAt: .headInsertEventTap,
                    for: .defaultTap
                )
                isActive = true
            } catch {
                NSLog("ButtonCore: Failed to create interceptor: \(error)")
            }
        }
    }

    // 禁用按钮监控
    func disable() {
        if isActive {
            NSLog("ButtonCore disabled")
            eventInterceptor?.stop()
            eventInterceptor = nil
            tiltEventInterceptor?.stop()
            tiltEventInterceptor = nil
            ButtonUtils.shared.resetPendingHoldState()
            isActive = false
        }
    }

    // 切换状态
    func toggle() {
        isActive ? disable() : enable()
    }
}
