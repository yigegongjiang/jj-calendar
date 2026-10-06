import AppKit

// MARK: - Access (日历 / 提醒事项分别授权)

extension MainViewController {
    /// 依次弹日历 / 提醒事项授权框 (仅未决定时).
    func requestAccess() {
        Task {
            _ = await store.requestAccess(to: .event)
            _ = await store.requestAccess(to: .reminder)
            applyAccess()
        }
    }

    /// 两者皆无 -> 全屏提示; 缺一 -> 工具栏按钮直达对应设置, 另一方照常展示.
    func applyAccess() {
        let access = AccessState.current
        accessButton.isHidden = !access.any || access.events && access.reminders
        accessButton.title = access.events ? "授权提醒事项" : "授权日历"
        guard access.any else {
            showMessage("无日历 / 提醒事项完全访问权限: 系统设置 > 隐私与安全性 > 日历 / 提醒事项 中允许 jj-calendar 后返回本窗口.")
            return
        }
        showMessage(nil)
        reload()
    }

    private func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.superview?.isHidden = text == nil
        gridView.isHidden = text != nil
    }

    /// 缺日历 -> 日历设置; 仅缺提醒事项 -> 提醒事项设置.
    @objc
    func openPrivacySettings() {
        let pane = AccessState.current.events ? "Privacy_Reminders" : "Privacy_Calendars"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
