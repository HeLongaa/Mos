//
//  ButtonTableCellView.swift
//  Mos
//
//  Created by 陈标 on 2025/9/27.
//  Copyright © 2025 Caldis. All rights reserved.
//

import Cocoa

class ButtonTableCellView: NSTableCellView {

    // MARK: - IBOutlets
    @IBOutlet weak var keyDisplayContainerView: NSView!
    @IBOutlet weak var actionPopUpButton: NSPopUpButton!

    // MARK: - UI Components
    private var triggerKeyPreview: KeyPreview!
    private var targetKeyPreview: KeyPreview?
    private var targetButton: NSButton?
    private var dashedLineLayer: CAShapeLayer?

    // MARK: - Callbacks
    private var onTargetRecordRequested: ((NSView) -> Void)?
    private var onDeleteRequested: (() -> Void)?

    // MARK: - State
    private var originalRowBackgroundColor: NSColor?

    // MARK: - 配置方法
    func configure(
        with binding: ButtonBinding,
        onTargetRecordRequested: @escaping (NSView) -> Void,
        onDeleteRequested: @escaping () -> Void
    ) {
        self.onTargetRecordRequested = onTargetRecordRequested
        self.onDeleteRequested = onDeleteRequested

        // 保存原始背景色（首次或复用时）
        if originalRowBackgroundColor == nil, let rowView = self.superview as? NSTableRowView {
            originalRowBackgroundColor = rowView.backgroundColor
        }

        // 配置触发键显示
        setupTriggerKeyView(with: binding.triggerEvent, holdButton: binding.holdButton)

        // 配置目标快捷键显示区域 (替代原 popup button)
        setupTargetView(with: binding.targetShortcut)

        // 绘制虚线分隔符
        DispatchQueue.main.async {
            self.setupDashedLine()
        }
    }

    // 高亮该行（重复录制时的视觉反馈）
    func highlight() {
        guard let rowView = self.superview as? NSTableRowView else { return }
        let highlightColor: NSColor
        if #available(macOS 10.14, *) {
            highlightColor = NSColor.controlAccentColor.withAlphaComponent(1)
        } else {
            highlightColor = NSColor.mainBlue
        }
        let originalColor = originalRowBackgroundColor ?? rowView.backgroundColor
        rowView.backgroundColor = highlightColor
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 1.5
            rowView.animator().backgroundColor = originalColor
        })
    }

    // MARK: - 触发键显示
    private func setupTriggerKeyView(with recordedEvent: RecordedEvent, holdButton: UInt16?) {
        keyDisplayContainerView.subviews.forEach { $0.removeFromSuperview() }

        triggerKeyPreview = KeyPreview()
        keyDisplayContainerView.addSubview(triggerKeyPreview)

        NSLayoutConstraint.activate([
            triggerKeyPreview.leadingAnchor.constraint(equalTo: keyDisplayContainerView.leadingAnchor),
            triggerKeyPreview.centerYAnchor.constraint(equalTo: keyDisplayContainerView.centerYAnchor),
        ])

        // 组合按键: 在触发键前显示 holdButton 名称
        var displayComponents = recordedEvent.displayComponents
        if let holdCode = holdButton {
            let holdName = KeyCode.mouseMap[holdCode] ?? "🖱\(holdCode)"
            displayComponents = [holdName] + displayComponents
        }
        triggerKeyPreview.update(from: displayComponents, status: .normal)
    }

    // MARK: - 目标快捷键显示 (替代 Popup Button)
    private func setupTargetView(with targetShortcut: RecordedEvent?) {
        // 隐藏原始 popup button (保留 frame 供布局参考)
        actionPopUpButton.isHidden = true

        // 清理旧的 target 视图
        targetButton?.removeFromSuperview()
        targetKeyPreview?.removeFromSuperview()
        targetButton = nil
        targetKeyPreview = nil

        guard let parent = actionPopUpButton.superview else { return }

        // 先添加 KeyPreview（在下层）
        let kp = KeyPreview()
        parent.addSubview(kp)

        // 再添加透明按钮作为点击层（在上层，覆盖 KeyPreview）
        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.title = ""
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = #selector(targetButtonClicked(_:))
        parent.addSubview(button)

        NSLayoutConstraint.activate([
            // 透明按钮占据 popup button 的全部位置
            button.leadingAnchor.constraint(equalTo: actionPopUpButton.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: actionPopUpButton.trailingAnchor),
            button.topAnchor.constraint(equalTo: actionPopUpButton.topAnchor),
            button.bottomAnchor.constraint(equalTo: actionPopUpButton.bottomAnchor),
            // KeyPreview 居中显示在同位置
            kp.centerXAnchor.constraint(equalTo: actionPopUpButton.centerXAnchor),
            kp.centerYAnchor.constraint(equalTo: actionPopUpButton.centerYAnchor),
        ])

        // 更新目标快捷键显示
        if let shortcut = targetShortcut {
            kp.update(from: shortcut.displayComponents, status: .normal)
        } else {
            kp.update(from: ["…"], status: .normal)
        }

        targetButton = button
        targetKeyPreview = kp
    }

    /// 更新目标快捷键显示（无需重建视图）
    func updateTargetDisplay(with targetShortcut: RecordedEvent?) {
        if let shortcut = targetShortcut {
            targetKeyPreview?.update(from: shortcut.displayComponents, status: .normal)
        } else {
            targetKeyPreview?.update(from: ["…"], status: .normal)
        }
    }

    // MARK: - 虚线分隔符
    private func setupDashedLine() {
        dashedLineLayer?.removeFromSuperlayer()

        guard let keyBox = keyDisplayContainerView.superview,
              let contentView = keyBox.superview else {
            return
        }

        contentView.wantsLayer = true

        let keyPreviewFrameInContentView = keyDisplayContainerView.convert(triggerKeyPreview.frame, to: contentView)
        let buttonFrame = actionPopUpButton.frame  // 隐藏但 frame 仍有效

        let horizontalMargin: CGFloat = 8.0
        let startX = keyPreviewFrameInContentView.maxX + horizontalMargin
        let endX = buttonFrame.minX - horizontalMargin
        let centerY = contentView.bounds.height / 2

        let path = CGMutablePath()
        path.move(to: CGPoint(x: startX, y: centerY))
        path.addLine(to: CGPoint(x: endX, y: centerY))

        let shapeLayer = CAShapeLayer()
        shapeLayer.path = path
        shapeLayer.strokeColor = NSColor.getMainLightBlack(for: self).cgColor
        shapeLayer.lineWidth = 1.0
        shapeLayer.lineDashPattern = [2, 2]

        contentView.layer?.addSublayer(shapeLayer)
        dashedLineLayer = shapeLayer
    }

    // MARK: - Actions

    @objc private func targetButtonClicked(_ sender: NSButton) {
        onTargetRecordRequested?(sender)
    }
}
