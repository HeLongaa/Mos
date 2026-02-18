//
//  KeyRecorder.swift
//  Mos
//  用于录制热键
//
//  Created by Claude on 2025/8/31.
//  Copyright © 2025 Caldis. All rights reserved.
//

import Cocoa

/// 录制模式
enum KeyRecordingMode {
    /// 组合键模式：需要修饰键+普通键的组合 (用于 ButtonsView 触发键录制)
    case combination
    /// 单键模式：支持单个按键，包括单独的修饰键 (用于 ScrollingView)
    case singleKey
    /// 仅键盘模式：只接受键盘快捷键，不接受鼠标 (用于 ButtonsView 目标快捷键录制)
    case keyboardOnly
}

@objc protocol KeyRecorderDelegate: AnyObject {
    /// 录制完成回调
    /// - Parameters:
    ///   - recorder: 录制器实例
    ///   - event: 录制的事件
    ///   - isDuplicate: 是否为重复录制 (true = 重复, false = 新录制)
    func onEventRecorded(_ recorder: KeyRecorder, didRecordEvent event: CGEvent, isDuplicate: Bool)

    /// 可选方法: 验证录制的事件是否为重复
    /// - Returns: true = 新录制, false = 重复录制
    /// - Note: 如果不实现此方法,默认返回 true (视为新录制,向后兼容)
    @objc optional func validateRecordedEvent(_ recorder: KeyRecorder, event: CGEvent) -> Bool
}

class KeyRecorder: NSObject {

    // MARK: - Constants
    static let TIMEOUT: TimeInterval = 10.0
    static let HOLD_TIMEOUT: TimeInterval = 1.5  // 等待第二个按键的窗口期
    static let FLAG_CHANGE_NOTI_NAME = NSNotification.Name("RECORD_FLAG_CHANGE_NOTI_NAME")
    static let FINISH_NOTI_NAME = NSNotification.Name("RECORD_FINISH_NOTI_NAME")
    static let CANCEL_NOTI_NAME = NSNotification.Name("RECORD_CANCEL_NOTI_NAME")
    static let HOLD_START_NOTI_NAME = NSNotification.Name("RECORD_HOLD_START_NOTI_NAME")

    // Delegate
    weak var delegate: KeyRecorderDelegate?
    // Recording
    private var interceptor: Interceptor?
    private var isRecording = false
    private var isRecorded = false // 是否已经记录过 (每次启动只记录一个按键
    private var recordTimeoutTimer: Timer? // 超时保护定时器
    private var invalidKeyPressCount = 0 // 无效按键计数
    private let invalidKeyThreshold = 5 // 显示 ESC 提示的阈值
    private var recordingMode: KeyRecordingMode = .combination // 当前录制模式
    // UI 组件
    private var keyPopover: KeyPopover?
    // 组合按键检测: 触发时已按住的第二个鼠标按键 (nil = 单键模式)
    private(set) var detectedHoldButton: UInt16?
    // 待定 Hold 状态: 第一个鼠标按键按下后等待第二个按键的状态机
    private var pendingHoldCode: UInt16? = nil      // 待定的 holdButton 按键码
    private var pendingHoldEvent: CGEvent? = nil    // 待定的 holdButton 原始事件
    private var pendingHoldTimer: Timer? = nil      // 超时后回退为单键录制
    
    // MARK: - Life Cycle
    deinit {
        stopRecording()
    }
    
    // MARK: - Event Masks
    // 事件掩码 (支持鼠标和键盘事件，包括修饰键变化)
    // 组合键模式下额外监听滚轮事件以支持倾斜滚轮录制
    private var eventMask: CGEventMask {
        let leftDown = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let rightDown = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        let otherDown = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        let keyDown = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let flagsChanged = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        var mask = leftDown | rightDown | otherDown | keyDown | flagsChanged
        // 仅组合键模式支持录制倾斜滚轮 (仅键盘模式不需要)
        if recordingMode == .combination {
            mask |= CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        }
        return mask
    }
    
    // MARK: - Recording Manager
    // 开始记录事件
    /// - Parameters:
    ///   - sourceView: 触发录制的视图，用于显示 Popover
    ///   - mode: 录制模式，默认为组合键模式
    func startRecording(from sourceView: NSView, mode: KeyRecordingMode = .combination) {
        // Guard: 防止重复执行
        guard !isRecording else { return }
        isRecording = true
        recordingMode = mode
        // Log
        NSLog("[EventRecorder] Starting in \(mode) mode")
        // 确保清理任何存在的录制界面
        keyPopover?.hide()
        keyPopover = nil
        // 监听事件
        do {
            // 监听回调事件通知
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRecordedEvent(_:)),
                name: KeyRecorder.FINISH_NOTI_NAME,
                object: nil
            )
            // 监听 Hold 开始通知 (第一个鼠标按键按下, 等待第二个)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleHoldStart(_:)),
                name: KeyRecorder.HOLD_START_NOTI_NAME,
                object: nil
            )
            // 监听修饰键变化通知
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleModifierFlagsChanged(_:)),
                name: KeyRecorder.FLAG_CHANGE_NOTI_NAME,
                object: nil
            )
            // 监听录制取消通知
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRecordingCancelled(_:)),
                name: KeyRecorder.CANCEL_NOTI_NAME,
                object: nil
            )
            // 启动拦截器
            interceptor = try Interceptor(
                event: eventMask,
                handleBy: { (proxy, type, event, refcon) in
                    let recordedEvent = event
                    switch type {
                    case .flagsChanged:
                        // 修饰键变化，发送通知 (单键模式下也用于完成录制)
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: KeyRecorder.FLAG_CHANGE_NOTI_NAME,
                                object: recordedEvent
                            )
                        }
                    case .scrollWheel:
                        // 倾斜滚轮: 始终作为触发器 (可以是独立触发或组合触发)
                        if recordedEvent.isTiltWheelEvent {
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: KeyRecorder.FINISH_NOTI_NAME,
                                    object: recordedEvent
                                )
                            }
                        }
                        // 垂直滚轮: 仅作为组合触发器 (在 hold 状态下才有效)
                        else if recordedEvent.isVerticalScrollEvent {
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: KeyRecorder.FINISH_NOTI_NAME,
                                    object: recordedEvent
                                )
                            }
                        }
                    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                        // 鼠标按键: 检测是否有其他按键同时按住
                        let pressedMask = NSEvent.pressedMouseButtons
                        let thisCode = Int(recordedEvent.mouseCode)
                        var holdCode: UInt16? = nil
                        for bit in 0..<20 where bit != thisCode {
                            if (pressedMask >> bit) & 1 == 1 { holdCode = UInt16(bit); break }
                        }
                        if let hold = holdCode {
                            // 已有其他按键按住 → 这是第二个按键, 作为触发器 (第一个是 holdButton)
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: KeyRecorder.FINISH_NOTI_NAME,
                                    object: recordedEvent,
                                    userInfo: ["holdButton": hold]
                                )
                            }
                        } else {
                            // 仅按下这一个键 → 进入 hold 等待状态 (可能是组合的第一键)
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: KeyRecorder.HOLD_START_NOTI_NAME,
                                    object: recordedEvent
                                )
                            }
                        }
                    case .keyDown:
                        // ESC键特殊处理：取消录制
                        if recordedEvent.keyCode == KeyCode.escape {
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: KeyRecorder.CANCEL_NOTI_NAME,
                                    object: nil
                                )
                            }
                        } else {
                            // 普通按键录制
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: KeyRecorder.FINISH_NOTI_NAME,
                                    object: recordedEvent
                                )
                            }
                        }
                    default:
                        break
                    }
                    return nil
                },
                listenOn: CGEventTapLocation.cgSessionEventTap,
                placeAt: CGEventTapPlacement.headInsertEventTap,
                for: CGEventTapOptions.defaultTap
            )
            // 展示录制界面
            keyPopover = KeyPopover()
            keyPopover?.show(at: sourceView)
            // 启动超时保护定时器
            startTimeoutTimer()
            // Log
            NSLog("[EventRecorder] Started")
        } catch {
            NSLog("[EventRecorder] Failed to start: \(error)")
            // 如果创建失败，重置状态
            isRecording = false
        }
    }
    // 修饰键变化处理
    @objc private func handleModifierFlagsChanged(_ notification: NSNotification) {
        guard isRecording && !isRecorded else { return }
        let event = notification.object as! CGEvent

        // 单键模式：修饰键按下时直接完成录制
        if recordingMode == .singleKey && event.isKeyDown && event.isModifiers {
            NSLog("[EventRecorder] Single key mode: modifier key recorded")
            // 直接触发录制完成
            NotificationCenter.default.post(
                name: KeyRecorder.FINISH_NOTI_NAME,
                object: event
            )
            return
        }

        // 组合键模式：如果有修饰键被按下，刷新超时定时器给用户更多时间
        let hasActiveModifiers = event.hasModifiers
        if hasActiveModifiers {
            startTimeoutTimer() // 重新启动定时器
            NSLog("[EventRecorder] Modifier key pressed, timeout timer refreshed")
        }
        // 实时更新录制界面显示当前已按下的修饰键
        keyPopover?.keyPreview
            .updateForRecording(from: event)
    }
    // 录制取消处理
    @objc private func handleRecordingCancelled(_ notification: NSNotification) {
        guard isRecording && !isRecorded else { return }
        NSLog("[EventRecorder] Recording cancelled by ESC key")
        stopRecording()
    }
    // 通知事件处理
    @objc private func handleRecordedEvent(_ notification: NSNotification) {
        // Guard: 需要 Recording 才进行后续处理
        guard isRecording else { return }
        // Guard: 获取 RecordedEvent
        let event = notification.object as! CGEvent
        // 提取 holdButton: 优先使用 tap 检测到的 userInfo 值, 否则使用待定 hold 状态
        let holdButtonFromUserInfo = notification.userInfo?["holdButton"] as? UInt16
        let effectiveHoldButton = holdButtonFromUserInfo ?? pendingHoldCode
        // 如果存在待定 hold 状态, 本次事件结束等待 → 清理待定状态
        if pendingHoldCode != nil {
            cancelPendingHoldTimer()
            pendingHoldCode = nil
            pendingHoldEvent = nil
        }
        // Guard: 检查事件有效性 (根据录制模式使用不同的验证规则)
        let isValid: Bool
        switch recordingMode {
        case .singleKey:
            isValid = isRecordableAsSingleKey(event)
        case .keyboardOnly:
            isValid = isRecordableAsKeyboardOnly(event)
        case .combination:
            if effectiveHoldButton != nil {
                // 有 holdButton: 任何鼠标事件(包括左右键)和滚轮事件都允许作为 trigger
                isValid = event.isMouseEvent || event.isTiltWheelEvent || event.isVerticalScrollEvent || event.isRecordable
            } else {
                // 无 holdButton: 垂直滚轮不允许作为独立触发器
                isValid = !event.isVerticalScrollEvent && event.isRecordable
            }
        }
        guard isValid else {
            NSLog("[EventRecorder] Invalid event ignored: \(event)")
            // 触发警告动画反馈
            keyPopover?.keyPreview.shakeWarning()
            // 计数无效按键，达到阈值时显示 ESC 提示
            invalidKeyPressCount += 1
            if invalidKeyPressCount >= invalidKeyThreshold {
                keyPopover?.showEscHint()
            }
            return
        }
        // 更新记录标识
        guard !isRecorded else { return }
        isRecorded = true
        // 存储检测到的 holdButton (供 delegate 读取)
        self.detectedHoldButton = effectiveHoldButton
        // 验证是否为重复录制 (如果 delegate 没实现验证方法,默认为新录制)
        let isNew = self.delegate?.validateRecordedEvent?(self, event: event) ?? true
        let isDuplicate = !isNew
        let status: KeyPreview.Status = isNew ? .recorded : .duplicate
        // 显示录制完成的按键 (组合时合并显示 holdButton 名称)
        var displayComponents = event.displayComponents
        if let holdCode = effectiveHoldButton {
            let holdName = KeyCode.mouseMap[holdCode] ?? "🖱\(holdCode)"
            displayComponents = [holdName] + displayComponents
        }
        keyPopover?.keyPreview
            .update(from: displayComponents, status: status)
        // 将结果发给 delegate (携带验证结果,避免下游重复检查)
        self.delegate?.onEventRecorded(self, didRecordEvent: event, isDuplicate: isDuplicate)
        // 停止录制 (延迟 300ms 确保能看完提示
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.stopRecording()
        }
    }

    // MARK: - Hold Start Handler
    // 第一个鼠标按键按下, 进入待定 hold 状态, 等待第二个按键
    @objc private func handleHoldStart(_ notification: NSNotification) {
        guard isRecording && !isRecorded else { return }
        guard recordingMode == .combination else {
            // 非组合模式: 转为普通 FINISH 处理
            NotificationCenter.default.post(name: KeyRecorder.FINISH_NOTI_NAME, object: notification.object)
            return
        }
        let event = notification.object as! CGEvent
        // 已有待定状态: 新来的按键是 trigger, 待定的是 holdButton → 组合录制
        if let pending = pendingHoldCode {
            cancelPendingHoldTimer()
            pendingHoldCode = nil
            pendingHoldEvent = nil
            NotificationCenter.default.post(
                name: KeyRecorder.FINISH_NOTI_NAME,
                object: event,
                userInfo: ["holdButton": pending]
            )
            return
        }
        // 进入待定状态
        pendingHoldCode = event.mouseCode
        pendingHoldEvent = event
        // 更新 UI: 显示 "🖱X + ?"
        let holdName = KeyCode.mouseMap[event.mouseCode] ?? "🖱\(event.mouseCode)"
        keyPopover?.keyPreview.update(from: [holdName, "+", "?"], status: .normal)
        NSLog("[EventRecorder] Hold start: button \(event.mouseCode), waiting for second key...")
        // 超时后退回单键录制
        cancelPendingHoldTimer()
        pendingHoldTimer = Timer.scheduledTimer(withTimeInterval: KeyRecorder.HOLD_TIMEOUT, repeats: false) { [weak self] _ in
            NSLog("[EventRecorder] Hold timeout, finalizing as solo")
            self?.finalizePendingAsSolo()
        }
    }

    // 待定 hold 状态超时 → 将第一个按键作为单键触发器录制
    private func finalizePendingAsSolo() {
        guard let event = pendingHoldEvent else { return }
        cancelPendingHoldTimer()
        pendingHoldCode = nil
        pendingHoldEvent = nil
        // 以单键模式重新发出 FINISH_NOTI
        NotificationCenter.default.post(name: KeyRecorder.FINISH_NOTI_NAME, object: event)
    }

    // 取消待定 hold 定时器
    private func cancelPendingHoldTimer() {
        pendingHoldTimer?.invalidate()
        pendingHoldTimer = nil
    }

    // MARK: - Single Key Mode Validation
    /// 单键模式下的事件有效性检查    /// - 允许单独的修饰键 (Control, Option, Command, Shift)
    /// - 允许 F 键
    /// - 允许普通键盘按键
    /// - 允许鼠标侧键
    /// - 不允许鼠标左右键
    private func isRecordableAsSingleKey(_ event: CGEvent) -> Bool {
        // 修饰键事件 (flagsChanged)
        if event.type == .flagsChanged {
            // 只有按下时才录制，抬起时忽略
            return event.isKeyDown && event.isModifiers
        }
        // 键盘事件
        if event.isKeyboardEvent {
            // 任何键盘按键都允许 (ESC 已在上游处理)
            return true
        }
        // 鼠标事件
        if event.isMouseEvent {
            // 左右键不允许
            if KeyCode.mouseMainKeys.contains(event.mouseCode) {
                return false
            }
            // 侧键等允许
            return true
        }
        return false
    }

    // MARK: - Keyboard Only Mode Validation
    /// 仅键盘模式下的事件有效性检查 (用于目标快捷键录制)
    /// - 只接受键盘按键，不接受鼠标事件
    /// - F 键允许无修饰键
    /// - 其他键必须有修饰键
    private func isRecordableAsKeyboardOnly(_ event: CGEvent) -> Bool {
        guard event.isKeyboardEvent else { return false }
        // F 键允许无修饰键
        if KeyCode.functionKeys.contains(event.keyCode) { return true }
        // 其他键必须有修饰键
        return event.hasModifiers
    }
    // 停止记录
    func stopRecording() {
        // Guard: 需要 Recording 才进行后续处理
        guard isRecording else { return }
        // Log
        NSLog("[EventRecorder] Stopping")
        // 隐藏录制界面
        keyPopover?.hide()
        keyPopover = nil
        // 取消超时定时器
        cancelTimeoutTimer()
        // 取消通知和监听
        interceptor?.stop()
        interceptor = nil
        NotificationCenter.default.removeObserver(self, name: KeyRecorder.FINISH_NOTI_NAME, object: nil)
        NotificationCenter.default.removeObserver(self, name: KeyRecorder.HOLD_START_NOTI_NAME, object: nil)
        NotificationCenter.default.removeObserver(self, name: KeyRecorder.FLAG_CHANGE_NOTI_NAME, object: nil)
        NotificationCenter.default.removeObserver(self, name: KeyRecorder.CANCEL_NOTI_NAME, object: nil)
        // 取消待定 Hold 状态
        cancelPendingHoldTimer()
        pendingHoldCode = nil
        pendingHoldEvent = nil
        // 重置状态 (添加延迟确保 Popover 结束动画完成, 避免多个 popover 重复出现导致卡住)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isRecording = false
            self?.isRecorded = false
            self?.invalidKeyPressCount = 0
            self?.detectedHoldButton = nil
            self?.pendingHoldCode = nil
            self?.pendingHoldEvent = nil
            NSLog("[EventRecorder] Stopped")
        }
    }
    
    // MARK: - Timeout Protection
    private func startTimeoutTimer() {
        cancelTimeoutTimer()
        recordTimeoutTimer = Timer.scheduledTimer(withTimeInterval: KeyRecorder.TIMEOUT, repeats: false) { [weak self] _ in
            NSLog("[EventRecorder] Recording timed out")
            self?.stopRecording()
        }
    }
    private func cancelTimeoutTimer() {
        recordTimeoutTimer?.invalidate()
        recordTimeoutTimer = nil
    }
}

