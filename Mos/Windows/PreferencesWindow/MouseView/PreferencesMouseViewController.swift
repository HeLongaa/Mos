//
//  PreferencesMouseViewController.swift
//  Mos
//  鼠标速度与加速度偏好设置界面
//  Created by Claude on 2025/11/5.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa

class PreferencesMouseViewController: NSViewController {

    // MARK: - UI 控件引用
    private var enableCheckBox: NSButton!
    private var speedSlider: NSSlider!
    private var speedValueField: NSTextField!
    private var accelSlider: NSSlider!
    private var accelValueField: NSTextField!
    private var accelHintLabel: NSTextField!

    // MARK: - Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // 与 Storyboard 中定义的 view 尺寸保持一致, 确保 NSTabViewController 正确计算窗口大小
        self.preferredContentSize = NSSize(width: 450, height: 128)
        setupUI()
        syncViewWithOptions()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        syncViewWithOptions()
    }

    // MARK: - 构建界面（纯代码布局，无 Storyboard 约束）

    private func setupUI() {
        let container = view

        // ── 左侧分类标签工厂 ──
        func makeLabel(_ text: String) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.translatesAutoresizingMaskIntoConstraints = false
            f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            f.alignment = .right
            f.textColor = .secondaryLabelColor
            return f
        }

        // ── 可编辑数值输入框工厂 ──
        func makeValueField(_ value: Double, min: Double, max: Double) -> NSTextField {
            let f = NSTextField()
            f.translatesAutoresizingMaskIntoConstraints = false
            f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            f.alignment = .center
            f.isBordered = true
            f.isBezeled = true
            f.bezelStyle = .roundedBezel
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            formatter.minimum = NSNumber(value: min)
            formatter.maximum = NSNumber(value: max)
            f.formatter = formatter
            f.doubleValue = value
            f.delegate = self
            return f
        }

        // ── Row 1: 功能启用开关 ──
        let row1Label = makeLabel(NSLocalizedString("mouseSectionEnable", comment: "Mouse enable section label"))
        let enableBtn = NSButton(checkboxWithTitle: NSLocalizedString("mouseEnableCheckbox", comment: "Enable custom mouse speed checkbox title"), target: self, action: #selector(enableChanged(_:)))
        enableBtn.translatesAutoresizingMaskIntoConstraints = false
        enableBtn.font = .systemFont(ofSize: NSFont.systemFontSize)
        enableCheckBox = enableBtn

        // ── Row 2: 指针速度 (slider + editable field) ──
        let row2Label = makeLabel(NSLocalizedString("mouseSpeedLabel", comment: "Mouse tracking speed label"))
        let slider = NSSlider(value: 1.0, minValue: 0.1, maxValue: 10.0, target: self, action: #selector(speedSliderChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.sliderType = .linear
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        speedSlider = slider

        let sField = makeValueField(1.0, min: 0.1, max: 10.0)
        speedValueField = sField

        // ── Row 3: 加速度 (slider + editable field) ──
        let row3Label = makeLabel(NSLocalizedString("mouseAccelLabel", comment: "Mouse acceleration section label"))
        let aSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 10.0, target: self, action: #selector(accelSliderChanged(_:)))
        aSlider.translatesAutoresizingMaskIntoConstraints = false
        aSlider.sliderType = .linear
        aSlider.numberOfTickMarks = 0
        aSlider.isContinuous = true
        accelSlider = aSlider

        let aField = makeValueField(1.0, min: 0.0, max: 10.0)
        accelValueField = aField

        // 加速度提示 (当值为 0 时显示 "线性")
        let hint = NSTextField(labelWithString: "")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = .tertiaryLabelColor
        accelHintLabel = hint

        // ── 添加到视图 ──
        [row1Label, enableBtn,
         row2Label, slider, sField,
         row3Label, aSlider, aField, hint].forEach { container.addSubview($0) }

        // ── AutoLayout 约束 ──
        let labelW: CGFloat = 140   // 与其他 Tab 一致的左列宽度
        let controlX: CGFloat = 168 // label(20)+width(140)+gap(8)
        let topPad: CGFloat  = 20
        let rowGap: CGFloat  = 16
        let fieldW: CGFloat  = 52

        NSLayoutConstraint.activate([
            // Row 1: enable checkbox
            row1Label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row1Label.widthAnchor.constraint(equalToConstant: labelW),
            row1Label.topAnchor.constraint(equalTo: container.topAnchor, constant: topPad),

            enableBtn.centerYAnchor.constraint(equalTo: row1Label.centerYAnchor),
            enableBtn.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: controlX),
            enableBtn.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            // Row 2: speed slider + editable field
            row2Label.leadingAnchor.constraint(equalTo: row1Label.leadingAnchor),
            row2Label.widthAnchor.constraint(equalToConstant: labelW),
            row2Label.topAnchor.constraint(equalTo: row1Label.bottomAnchor, constant: rowGap),

            slider.centerYAnchor.constraint(equalTo: row2Label.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: controlX),
            slider.widthAnchor.constraint(equalToConstant: 180),

            sField.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            sField.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            sField.widthAnchor.constraint(equalToConstant: fieldW),

            // Row 3: acceleration slider + editable field
            row3Label.leadingAnchor.constraint(equalTo: row1Label.leadingAnchor),
            row3Label.widthAnchor.constraint(equalToConstant: labelW),
            row3Label.topAnchor.constraint(equalTo: row2Label.bottomAnchor, constant: rowGap),

            aSlider.centerYAnchor.constraint(equalTo: row3Label.centerYAnchor),
            aSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: controlX),
            aSlider.widthAnchor.constraint(equalToConstant: 180),

            aField.centerYAnchor.constraint(equalTo: aSlider.centerYAnchor),
            aField.leadingAnchor.constraint(equalTo: aSlider.trailingAnchor, constant: 8),
            aField.widthAnchor.constraint(equalToConstant: fieldW),

            hint.centerYAnchor.constraint(equalTo: aField.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: aField.trailingAnchor, constant: 4),

            // 底部约束: 确保 Auto Layout 能完整确定内容高度
            aSlider.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - Actions

    @objc private func enableChanged(_ sender: NSButton) {
        Options.shared.mouse.enabled = sender.state == .on
        MouseCore.shared.apply()
        syncViewWithOptions()
    }

    @objc private func speedSliderChanged(_ sender: NSSlider) {
        Options.shared.mouse.speed = sender.doubleValue
        MouseCore.shared.apply()
        syncViewWithOptions()
    }

    @objc private func accelSliderChanged(_ sender: NSSlider) {
        Options.shared.mouse.acceleration = sender.doubleValue
        MouseCore.shared.apply()
        syncViewWithOptions()
    }

    // MARK: - 同步界面与设置

    private func syncViewWithOptions() {
        let opts = Options.shared.mouse
        enableCheckBox.state = opts.enabled ? .on : .off

        // 速度
        speedSlider.isEnabled = opts.enabled
        speedSlider.doubleValue = opts.speed
        speedValueField.isEnabled = opts.enabled
        speedValueField.doubleValue = opts.speed
        speedValueField.textColor = opts.enabled ? .labelColor : .secondaryLabelColor

        // 加速度
        accelSlider.isEnabled = opts.enabled
        accelSlider.doubleValue = opts.acceleration
        accelValueField.isEnabled = opts.enabled
        accelValueField.doubleValue = opts.acceleration
        accelValueField.textColor = opts.enabled ? .labelColor : .secondaryLabelColor

        // 加速度提示
        if opts.acceleration < 0.01 {
            accelHintLabel.stringValue = NSLocalizedString("mouseAccelLinearHint", comment: "Linear mode hint when acceleration is 0")
        } else {
            accelHintLabel.stringValue = ""
        }
    }
}

// MARK: - NSTextFieldDelegate (可编辑数值输入)

extension PreferencesMouseViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field == speedValueField {
            let val = max(0.1, min(10.0, field.doubleValue))
            Options.shared.mouse.speed = val
            MouseCore.shared.apply()
            syncViewWithOptions()
        } else if field == accelValueField {
            let val = max(0.0, min(10.0, field.doubleValue))
            Options.shared.mouse.acceleration = val
            MouseCore.shared.apply()
            syncViewWithOptions()
        }
    }
}
