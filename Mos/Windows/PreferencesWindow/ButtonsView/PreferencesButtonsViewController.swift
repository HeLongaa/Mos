//
//  PreferencesButtonsViewController.swift
//  Mos
//  按钮绑定配置界面
//  Created by Claude on 2025/8/10.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa

class PreferencesButtonsViewController: NSViewController {

    // MARK: - Recorder
    private var recorder = KeyRecorder()

    // MARK: - 录制上下文 (区分触发键录制和目标快捷键录制)
    private enum RecordingContext {
        case trigger
        case target(bindingId: UUID)
    }
    private var recordingContext: RecordingContext = .trigger

    // MARK: - Data
    private var buttonBindings: [ButtonBinding] = []

    // MARK: - UI Elements
    // 表格
    @IBOutlet weak var tableHead: NSVisualEffectView!
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var tableEmpty: NSView!
    @IBOutlet weak var tableFoot: NSView!
    // 按钮
    @IBOutlet weak var createButton: PrimaryButton!
    @IBOutlet weak var addButton: NSButton!
    @IBOutlet weak var delButton: NSButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        recorder.delegate = self
        tableView.delegate = self
        tableView.dataSource = self
        loadOptionsToView()
    }

    override func viewWillAppear() {
        toggleNoDataHint()
        setupRecordButtonCallback()
    }

    // 添加触发键（组合键模式）
    @IBAction func addItemClick(_ sender: NSButton) {
        recordingContext = .trigger
        recorder.startRecording(from: sender)
    }

    // 删除
    @IBAction func removeItemClick(_ sender: NSButton) {
        guard tableView.selectedRow != -1 else { return }
        let binding = buttonBindings[tableView.selectedRow]
        removeButtonBinding(id: binding.id)
        updateDelButtonState()
    }
}

/**
 * 数据持久化
 **/
extension PreferencesButtonsViewController {
    // 从 Options 加载到界面
    func loadOptionsToView() {
        buttonBindings = Options.shared.buttons.binding
        tableView.reloadData()
        toggleNoDataHint()
    }

    // 保存界面到 Options
    func syncViewWithOptions() {
        Options.shared.buttons.binding = buttonBindings
    }

    // 更新删除按钮状态
    func updateDelButtonState() {
        delButton.isEnabled = tableView.selectedRow != -1
    }

    // 设置录制按钮回调（createButton 用于空状态页）
    private func setupRecordButtonCallback() {
        createButton.onMouseDown = { [weak self] target in
            guard let self = self else { return }
            self.recordingContext = .trigger
            self.recorder.startRecording(from: target)
        }
    }

    // 添加触发键录制结果到列表
    private func addRecordedTrigger(_ event: CGEvent, holdButton: UInt16?, isDuplicate: Bool) {
        let recordedEvent = RecordedEvent(from: event)

        if isDuplicate {
            if let existing = buttonBindings.first(where: { $0.triggerEvent == recordedEvent && $0.holdButton == holdButton }) {
                highlightExistingRow(with: existing.id)
            }
            return
        }

        let binding = ButtonBinding(triggerEvent: recordedEvent, holdButton: holdButton, targetShortcut: nil, isEnabled: false)
        buttonBindings.append(binding)
        tableView.reloadData()
        toggleNoDataHint()
        syncViewWithOptions()
    }

    // 更新目标快捷键绑定
    func updateButtonBinding(id: UUID, targetShortcut: RecordedEvent?) {
        guard let index = buttonBindings.firstIndex(where: { $0.id == id }) else { return }
        let old = buttonBindings[index]
        let updated = ButtonBinding(
            id: old.id,
            triggerEvent: old.triggerEvent,
            holdButton: old.holdButton,
            targetShortcut: targetShortcut,
            isEnabled: targetShortcut != nil
        )
        buttonBindings[index] = updated
        tableView.reloadData()
        toggleNoDataHint()
        syncViewWithOptions()
    }

    // 高亮已存在的行 (重复录制触发键时的视觉反馈)
    private func highlightExistingRow(with id: UUID) {
        guard let row = buttonBindings.firstIndex(where: { $0.id == id }) else { return }
        tableView.deselectAll(nil)
        tableView.scrollRowToVisible(row)
        if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ButtonTableCellView {
            cellView.highlight()
        }
    }

    // 删除按钮绑定
    func removeButtonBinding(id: UUID) {
        buttonBindings.removeAll(where: { $0.id == id })
        tableView.reloadData()
        toggleNoDataHint()
        syncViewWithOptions()
    }
}

/**
 * 表格区域渲染及操作
 **/
extension PreferencesButtonsViewController: NSTableViewDelegate, NSTableViewDataSource {
    // 无数据
    func toggleNoDataHint() {
        let hasData = buttonBindings.count != 0
        updateViewVisibility(view: createButton, visible: !hasData)
        updateViewVisibility(view: tableEmpty, visible: !hasData)
        updateViewVisibility(view: tableHead, visible: hasData)
        updateViewVisibility(view: tableFoot, visible: hasData)
    }
    private func updateViewVisibility(view: NSView, visible: Bool) {
        view.isHidden = !visible
        view.animator().alphaValue = visible ? 1 : 0
    }

    // 表格数据源
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumnIdentifier = tableColumn?.identifier else { return nil }

        if let cell = tableView.makeView(withIdentifier: tableColumnIdentifier, owner: self) as? ButtonTableCellView {
            let binding = buttonBindings[row]

            cell.configure(
                with: binding,
                onTargetRecordRequested: { [weak self] sourceView in
                    guard let self = self else { return }
                    // 开始录制目标键盘快捷键
                    self.recordingContext = .target(bindingId: binding.id)
                    self.recorder.startRecording(from: sourceView, mode: .keyboardOnly)
                },
                onDeleteRequested: { [weak self] in
                    self?.removeButtonBinding(id: binding.id)
                }
            )
            return cell
        }

        return nil
    }

    // 行高
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 44
    }

    // 行数
    func numberOfRows(in tableView: NSTableView) -> Int {
        return buttonBindings.count
    }

    // 选择变化
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDelButtonState()
    }

    // Type Selection 支持
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard row < buttonBindings.count else { return nil }
        let components = buttonBindings[row].triggerEvent.displayComponents
        let keyOnly = components.count > 1 ? Array(components.dropFirst()) : components
        return keyOnly.joined(separator: " ")
    }
}

// MARK: - KeyRecorderDelegate
extension PreferencesButtonsViewController: KeyRecorderDelegate {
    // 验证录制的事件 (触发键录制时检查重复；目标快捷键录制时不检查重复)
    func validateRecordedEvent(_ recorder: KeyRecorder, event: CGEvent) -> Bool {
        switch recordingContext {
        case .trigger:
            let recordedEvent = RecordedEvent(from: event)
            let holdButton = recorder.detectedHoldButton
            return !buttonBindings.contains(where: { $0.triggerEvent == recordedEvent && $0.holdButton == holdButton })
        case .target:
            return true  // 目标快捷键不检查重复
        }
    }

    // 录制完成回调
    func onEventRecorded(_ recorder: KeyRecorder, didRecordEvent event: CGEvent, isDuplicate: Bool) {
        let holdButton = recorder.detectedHoldButton
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.66) { [weak self] in
            guard let self = self else { return }
            switch self.recordingContext {
            case .trigger:
                self.addRecordedTrigger(event, holdButton: holdButton, isDuplicate: isDuplicate)
            case .target(let bindingId):
                let targetShortcut = RecordedEvent(from: event)
                self.updateButtonBinding(id: bindingId, targetShortcut: targetShortcut)
            }
        }
    }
}
