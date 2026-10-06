import AppKit

/// AX value 可写: 自动化以 set value (选项标题) 后台切换, 无需弹出菜单 (弹菜单需前台).
/// NSPopUpButton 的 AX 元素由 cell 提供, 覆写须在 cell 上.
final class SettablePopUpButton: NSPopUpButton {
    override static var cellClass: AnyClass? {
        get { Cell.self }
        set { _ = newValue }
    }

    private final class Cell: NSPopUpButtonCell {
        override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
            selector == #selector(setAccessibilityValue(_:)) || super.isAccessibilitySelectorAllowed(selector)
        }

        override func setAccessibilityValue(_ value: Any?) {
            guard let title = value as? String, let item = item(withTitle: title),
                  let control = controlView as? NSControl else { return }
            select(item)
            control.sendAction(action, to: target)
        }
    }
}
