//
//  RecordedEvent.swift
//  Mos
//  按钮绑定数据结构, 包含三部分
//  - EventType: 事件类型枚举 (键盘/鼠标), 供 RecordedEvent 和 ScrollHotkey 共用
//  - ScrollHotkey: 滚动热键绑定, 仅存储类型和按键码
//  - RecordedEvent: 录制后的 CGEvent 事件的完整信息, 包含修饰键和展示组件
//  - ButtonBinding: 用于存储 RecordedEvent - SystemShortcut 的绑定关系
//  Created by Claude on 2025/9/27.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa

// MARK: - EventType
/// 事件类型枚举 - 键盘或鼠标
enum EventType: String, Codable {
    case keyboard = "keyboard"
    case mouse = "mouse"
}

// MARK: - ScrollHotkey
/// 滚动热键绑定 - 轻量结构，仅存储类型和按键码
/// 用于 ScrollingView 的 dash/toggle/block 热键配置
struct ScrollHotkey: Codable, Equatable {

    // MARK: - 数据字段
    let type: EventType
    let code: UInt16

    // MARK: - 初始化
    init(type: EventType, code: UInt16) {
        self.type = type
        self.code = code
    }

    init(from event: CGEvent) {
        // 键盘事件 (keyDown/keyUp) 或修饰键事件 (flagsChanged)
        if event.isKeyboardEvent || event.type == .flagsChanged {
            self.type = .keyboard
            self.code = event.keyCode
        } else {
            self.type = .mouse
            self.code = event.mouseCode
        }
    }

    /// 从旧版 Int 格式迁移 (向后兼容)
    init?(legacyCode: Int?) {
        guard let code = legacyCode else { return nil }
        self.type = .keyboard
        self.code = UInt16(code)
    }

    // MARK: - 显示名称
    var displayName: String {
        switch type {
        case .keyboard:
            return KeyCode.keyMap[code] ?? "Key \(code)"
        case .mouse:
            return KeyCode.mouseMap[code] ?? "🖱\(code)"
        }
    }

    // MARK: - 事件匹配
    func matches(_ event: CGEvent, keyCode: UInt16, mouseButton: UInt16, isMouseEvent: Bool) -> Bool {
        switch type {
        case .keyboard:
            // 键盘按键或修饰键
            guard !isMouseEvent else { return false }
            return code == keyCode
        case .mouse:
            // 鼠标按键
            guard isMouseEvent else { return false }
            return code == mouseButton
        }
    }

    /// 是否为修饰键
    var isModifierKey: Bool {
        return type == .keyboard && KeyCode.modifierKeys.contains(code)
    }

    /// 获取修饰键掩码 (仅对键盘修饰键有效)
    var modifierMask: CGEventFlags {
        guard type == .keyboard else { return CGEventFlags(rawValue: 0) }
        return KeyCode.getKeyMask(code)
    }
}

// MARK: - RecordedEvent
/// 录制的事件数据 - 可序列化的事件信息 (完整版，包含修饰键)
struct RecordedEvent: Codable, Equatable {

    // MARK: - 数据字段
    let type: EventType // 事件类型
    let code: UInt16 // 按键代码
    let modifiers: UInt // 修饰键
    let displayComponents: [String] // 展示用名称组件

    // MARK: - 计算属性

    /// NSEvent.ModifierFlags 格式的修饰键
    var modifierFlags: NSEvent.ModifierFlags {
        return NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// 转换为 ScrollHotkey (丢弃修饰键信息)
    var asScrollHotkey: ScrollHotkey {
        return ScrollHotkey(type: type, code: code)
    }

    // MARK: - INIT
    init(from event: CGEvent) {
        // 修饰键: 只保留用户可见的4个修饰键标志位, 过滤系统内部标志
        self.modifiers = UInt(event.flags.rawValue & KeyCode.modifiersMask)
        // 倾斜滚轮事件: 使用虚拟码 21/22 表示左/右倾斜
        if event.isTiltWheelEvent {
            let deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            self.type = .mouse
            self.code = deltaX > 0 ? KeyCode.scrollWheelRight : KeyCode.scrollWheelLeft
            self.displayComponents = event.displayComponents
            return
        }
        // 垂直滚轮事件: 使用虚拟码 23/24 表示上/下滚动
        if event.isVerticalScrollEvent {
            let deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            self.type = .mouse
            self.code = deltaY < 0 ? KeyCode.scrollWheelUp : KeyCode.scrollWheelDown
            self.displayComponents = event.displayComponents
            return
        }
        // 根据事件类型匹配
        if event.isKeyboardEvent {
            self.type = .keyboard
            self.code = event.keyCode
        } else {
            self.type = .mouse
            self.code = event.mouseCode
        }
        // 展示用名称
        self.displayComponents = event.displayComponents
    }

    // MARK: - 匹配方法
    /// 检查是否与给定的 CGEvent 匹配
    func matches(_ event: CGEvent) -> Bool {
        let mask = KeyCode.modifiersMask
        switch type {
            case .keyboard:
                // 键盘触发: 修饰键精确匹配 + 按键码匹配
                guard (event.flags.rawValue & mask) == (UInt64(modifiers) & mask) else { return false }
                guard event.type == .keyDown else { return false }
                return code == Int(event.getIntegerValueField(.keyboardEventKeycode))
            case .mouse:
                // 鼠标触发: 修饰键使用「包含」检查 (录制的修饰键必须是事件修饰键的子集)
                // 部分鼠标驱动 (如 Logitech Options+) 会在 cgAnnotatedSessionEventTap 层自动注入
                // 额外的修饰键标志, 而录制时在 cgSessionEventTap 层看不到这些标志.
                // 使用子集检查: 只要录制时记录的修饰键都出现在事件中即可匹配.
                let recordedMods = UInt64(modifiers) & mask
                let eventMods = event.flags.rawValue & mask
                guard (eventMods & recordedMods) == recordedMods else { return false }
                // 虚拟滚轮倾斜码 (21=左, 22=右): 匹配倾斜滚轮方向
                if code == KeyCode.scrollWheelLeft || code == KeyCode.scrollWheelRight {
                    guard event.isTiltWheelEvent else { return false }
                    let deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                    if code == KeyCode.scrollWheelLeft { return deltaX < 0 }
                    if code == KeyCode.scrollWheelRight { return deltaX > 0 }
                    return false
                }
                // 虚拟滚轮上下码 (23=上, 24=下): 匹配垂直滚轮方向
                if code == KeyCode.scrollWheelUp || code == KeyCode.scrollWheelDown {
                    guard event.isVerticalScrollEvent else { return false }
                    let deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                    if code == KeyCode.scrollWheelUp { return deltaY < 0 }
                    if code == KeyCode.scrollWheelDown { return deltaY > 0 }
                    return false
                }
                // 普通鼠标按键: 仅匹配鼠标按键 DOWN 事件 (排除 scrollWheel —— 滚轮事件的
                // mouseEventButtonNumber 通常为 2, 会误匹配中键绑定)
                guard event.isMouseEvent else { return false }
                return code == Int(event.getIntegerValueField(.mouseEventButtonNumber))
        }
    }
    /// Equatable (修饰键使用掩码比较, 忽略系统内部标志位)
    static func == (lhs: RecordedEvent, rhs: RecordedEvent) -> Bool {
        let mask = KeyCode.modifiersMask
        return lhs.type == rhs.type &&
               lhs.code == rhs.code &&
               (UInt64(lhs.modifiers) & mask) == (UInt64(rhs.modifiers) & mask)
    }
}

// MARK: - ButtonBinding
/// 按钮绑定 - 将触发事件与键盘快捷键关联
struct ButtonBinding: Codable, Equatable {

    // MARK: - 数据字段

    /// 唯一标识符
    let id: UUID

    /// 录制的触发事件 (鼠标按键 / 倾斜滚轮)
    let triggerEvent: RecordedEvent

    /// 触发时必须已按住的第二个鼠标按键 (nil = 单键模式)
    let holdButton: UInt16?

    /// 绑定的目标键盘快捷键 (nil = 未绑定)
    let targetShortcut: RecordedEvent?

    /// 是否启用
    var isEnabled: Bool

    /// 创建时间
    let createdAt: Date

    // MARK: - 计算属性

    /// 是否已绑定目标快捷键
    var isBound: Bool { targetShortcut != nil }

    // MARK: - 初始化

    init(id: UUID = UUID(), triggerEvent: RecordedEvent, holdButton: UInt16? = nil, targetShortcut: RecordedEvent? = nil, isEnabled: Bool = false) {
        self.id = id
        self.triggerEvent = triggerEvent
        self.holdButton = holdButton
        self.targetShortcut = targetShortcut
        self.isEnabled = isEnabled
        self.createdAt = Date()
    }

    // MARK: - Equatable

    static func == (lhs: ButtonBinding, rhs: ButtonBinding) -> Bool {
        return lhs.id == rhs.id
    }
}
