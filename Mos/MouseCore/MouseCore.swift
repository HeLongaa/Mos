//
//  MouseCore.swift
//  Mos
//  鼠标速度与加速度控制核心类
//  通过 IOKit HID 系统接口读写鼠标追踪速度和加速度参数
//
//  Created by Claude on 2025/11/5.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa
import IOKit.hidsystem

class MouseCore {

    // 单例
    static let shared = MouseCore()
    init() { NSLog("Module initialized: MouseCore") }

    // HID 加速度键
    private let mouseAccelKey = "HIDMouseAcceleration" as CFString
    // 应用前的原始系统加速度值 (nil = 尚未捕获)
    private var originalAcceleration: Double? = nil

    // MARK: - IOKit 连接

    /// 打开 IOHIDSystem 连接，调用方负责在使用完毕后调用 IOServiceClose
    private func openHIDConnection() -> io_connect_t? {
        // kIOMasterPortDefault / kIOMainPortDefault = 0
        let service = IOServiceGetMatchingService(0, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else {
            NSLog("MouseCore: IOHIDSystem service not found")
            return nil
        }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard result == KERN_SUCCESS else {
            NSLog("MouseCore: IOServiceOpen failed: \(result)")
            return nil
        }
        return connect
    }

    // MARK: - 公共接口

    /// 应用自定义鼠标设置（从 Options.shared.mouse 读取）
    func apply() {
        let opts = Options.shared.mouse
        guard opts.enabled else {
            restore()
            return
        }
        guard let connect = openHIDConnection() else { return }
        defer { IOServiceClose(connect) }

        // 首次应用时记录原始加速度值，以便恢复
        if originalAcceleration == nil {
            var val: Double = 0
            if IOHIDGetAccelerationWithKey(connect, mouseAccelKey, &val) == KERN_SUCCESS {
                originalAcceleration = val
                NSLog("MouseCore: Captured original acceleration = \(val)")
            }
        }

        // 计算最终 HID 值: acceleration=0 时为线性模式 (-1)，否则 speed * acceleration
        let target: Double
        if opts.acceleration < 0.01 {
            target = -1.0  // 线性模式
        } else {
            target = opts.speed * opts.acceleration
        }
        let result = IOHIDSetAccelerationWithKey(connect, mouseAccelKey, target)
        if result == KERN_SUCCESS {
            NSLog("MouseCore: Applied mouse acceleration = \(target)")
        } else {
            NSLog("MouseCore: Failed to set acceleration: \(result)")
        }
    }

    /// 恢复系统原始鼠标加速度值
    func restore() {
        guard let original = originalAcceleration else { return }
        guard let connect = openHIDConnection() else { return }
        defer { IOServiceClose(connect) }
        let result = IOHIDSetAccelerationWithKey(connect, mouseAccelKey, original)
        if result == KERN_SUCCESS {
            originalAcceleration = nil
            NSLog("MouseCore: Restored original acceleration = \(original)")
        }
    }

    /// 读取当前系统鼠标加速度值（不修改状态）
    func readCurrentAcceleration() -> Double? {
        guard let connect = openHIDConnection() else { return nil }
        defer { IOServiceClose(connect) }
        var val: Double = 0
        guard IOHIDGetAccelerationWithKey(connect, mouseAccelKey, &val) == KERN_SUCCESS else { return nil }
        return val
    }
}
