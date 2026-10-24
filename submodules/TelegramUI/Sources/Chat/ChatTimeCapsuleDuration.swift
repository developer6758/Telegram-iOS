import AsyncDisplayKit
import Display
import Foundation
import TelegramPresentationData
import UIKit

private final class CapsuleDurationSelection {
    var days = 0
    var hours = 1
    var minutes = 0
    var seconds = 0
    var changed: (() -> Void)?
    var duration: Int64 {
        return Int64(days) * 86400 + Int64(hours) * 3600 + Int64(minutes) * 60 + Int64(seconds)
    }
}

private final class CapsuleDurationPickerItem: ActionSheetItem {
    let selection: CapsuleDurationSelection
    let labels: [String]
    let invalidText: String
    init(selection: CapsuleDurationSelection, labels: [String], invalidText: String) {
        self.selection = selection
        self.labels = labels
        self.invalidText = invalidText
    }
    func node(theme: ActionSheetControllerTheme) -> ActionSheetItemNode {
        return CapsuleDurationPickerNode(theme: theme, selection: self.selection, labels: self.labels, invalidText: self.invalidText)
    }
    func updateNode(_ node: ActionSheetItemNode) {
        node.requestLayoutUpdate()
    }
}

private final class CapsuleDurationPickerNode: ActionSheetItemNode, UIPickerViewDataSource, UIPickerViewDelegate {
    private let selection: CapsuleDurationSelection
    private let labels: [String]
    private let color: UIColor
    private let fontSize: CGFloat
    private let picker = UIPickerView()
    private let presets = UISegmentedControl(items: ["00:00:08", "01:00:00", "1d 00:00:00"])
    private let validation = UILabel()
    private var headings: [UILabel] = []

    init(theme: ActionSheetControllerTheme, selection: CapsuleDurationSelection, labels: [String], invalidText: String) {
        self.selection = selection
        self.labels = labels
        self.color = theme.primaryTextColor
        self.fontSize = min(26.0, theme.baseFontSize)
        super.init(theme: theme)
        self.picker.dataSource = self
        self.picker.delegate = self
        self.picker.semanticContentAttribute = .forceLeftToRight
        self.presets.semanticContentAttribute = .forceLeftToRight
        self.presets.selectedSegmentIndex = 1
        self.presets.selectedSegmentTintColor = theme.controlColor
        self.presets.setTitleTextAttributes([.foregroundColor: theme.primaryTextColor], for: .normal)
        self.presets.addTarget(self, action: #selector(self.presetChanged), for: .valueChanged)
        self.view.addSubview(self.picker)
        self.view.addSubview(self.presets)
        self.validation.text = invalidText
        self.validation.font = Font.regular(max(12.0, theme.baseFontSize * 0.72))
        self.validation.textColor = theme.destructiveActionTextColor
        self.validation.textAlignment = .center
        self.validation.numberOfLines = 2
        self.validation.isHidden = true
        self.view.addSubview(self.validation)
        for label in labels {
            let heading = UILabel()
            heading.text = label
            heading.font = Font.regular(max(11.0, theme.baseFontSize * 0.72))
            heading.textColor = theme.secondaryTextColor
            heading.textAlignment = .center
            heading.adjustsFontSizeToFitWidth = true
            heading.minimumScaleFactor = 0.8
            self.view.addSubview(heading)
            self.headings.append(heading)
        }
        self.synchronizePicker()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayout(constrainedSize: CGSize, transition: ContainedViewLayoutTransition) -> CGSize {
        let invalid = !(1...31_536_000).contains(self.selection.duration)
        let size = CGSize(width: constrainedSize.width, height: invalid ? 306.0 : 270.0)
        let width = max(1.0, size.width - 24.0)
        for (index, heading) in self.headings.enumerated() {
            heading.frame = CGRect(x: 12.0 + CGFloat(index) * width / 4.0, y: 12.0, width: width / 4.0, height: 24.0)
        }
        self.picker.frame = CGRect(x: 12.0, y: 36.0, width: width, height: 176.0)
        self.presets.frame = CGRect(x: 16.0, y: 222.0, width: max(1.0, size.width - 32.0), height: 34.0)
        self.validation.frame = CGRect(x: 16.0, y: 260.0, width: max(1.0, size.width - 32.0), height: 40.0)
        self.validation.isHidden = !invalid
        self.updateInternalLayout(size, constrainedSize: constrainedSize)
        return size
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int { return 4 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return [366, 24, 60, 60][component]
    }
    func pickerView(_ pickerView: UIPickerView, widthForComponent component: Int) -> CGFloat {
        return max(1.0, pickerView.bounds.width / 4.0)
    }
    func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat { return 36.0 }
    func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
        let label = (view as? UILabel) ?? UILabel()
        label.text = String(format: component == 0 ? "%d" : "%02d", row)
        label.font = Font.regular(self.fontSize)
        label.textColor = self.color
        label.textAlignment = .center
        label.accessibilityLabel = "\(row) \(self.labels[component])"
        return label
    }
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        switch component {
        case 0: self.selection.days = row
        case 1: self.selection.hours = row
        case 2: self.selection.minutes = row
        default: self.selection.seconds = row
        }
        self.presets.selectedSegmentIndex = UISegmentedControl.noSegment
        self.requestLayout?()
        self.selection.changed?()
    }
    private func synchronizePicker() {
        for (component, row) in [self.selection.days, self.selection.hours, self.selection.minutes, self.selection.seconds].enumerated() {
            self.picker.selectRow(row, inComponent: component, animated: false)
        }
    }
    @objc private func presetChanged() {
        self.selection.days = self.presets.selectedSegmentIndex == 2 ? 1 : 0
        self.selection.hours = self.presets.selectedSegmentIndex == 1 ? 1 : 0
        self.selection.minutes = 0
        self.selection.seconds = self.presets.selectedSegmentIndex == 0 ? 8 : 0
        self.synchronizePicker()
        self.requestLayout?()
        self.selection.changed?()
    }
}

/// Telegram's native action sheet owns presentation, theming, safe areas and dismissal.
func chatTimeCapsuleDurationController(presentationData: PresentationData, send: @escaping (Int64) -> Void, cancelled: @escaping () -> Void) -> ActionSheetController {
    let strings = presentationData.strings
    let selection = CapsuleDurationSelection()
    let sheet = ActionSheetController(presentationData: presentationData)
    let sendItem: () -> ActionSheetButtonItem = { [weak sheet] in
        let valid = (1...31_536_000).contains(selection.duration)
        return ActionSheetButtonItem(title: strings.TimeCapsule_Send, color: valid ? .accent : .disabled, font: .bold, enabled: valid, action: {
            guard (1...31_536_000).contains(selection.duration) else { return }
            let duration = selection.duration
            sheet?.dismissAnimated()
            send(duration)
        })
    }
    sheet.setItemGroups([
        ActionSheetItemGroup(items: [
            ActionSheetTextItem(title: strings.TimeCapsule_Title, font: .large, parseMarkdown: false),
            CapsuleDurationPickerItem(selection: selection, labels: [strings.TimeCapsule_Days, strings.TimeCapsule_Hours, strings.TimeCapsule_Minutes, strings.TimeCapsule_Seconds], invalidText: strings.TimeCapsule_DurationInvalid),
            sendItem()
        ]),
        ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, action: { [weak sheet] in
            sheet?.dismissAnimated()
            cancelled()
        })])
    ])
    selection.changed = { [weak sheet, weak selection] in
        guard let selection else { return }
        let valid = (1...31_536_000).contains(selection.duration)
        sheet?.updateItem(groupIndex: 0, itemIndex: 2, { [weak sheet, weak selection] _ in
            return ActionSheetButtonItem(title: strings.TimeCapsule_Send, color: valid ? .accent : .disabled, font: .bold, enabled: valid, action: { [weak sheet, weak selection] in
                guard let selection, (1...31_536_000).contains(selection.duration) else { return }
                let duration = selection.duration
                sheet?.dismissAnimated()
                send(duration)
            })
        })
    }
    sheet.dismissed = { wasCancelled in
        if wasCancelled { cancelled() }
    }
    return sheet
}
