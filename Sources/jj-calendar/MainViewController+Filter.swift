import AppKit

// MARK: - Calendars filter (筛选面板 + 只显示还原)

extension MainViewController {
    func configureFilterControls() {
        calendarsButton.setAccessibilityIdentifier("calendarsButton")
        calendarsButton.target = self
        calendarsButton.action = #selector(showCalendarFilter)
        soloRestoreButton.setAccessibilityIdentifier("soloRestoreButton")
        soloRestoreButton.target = self
        soloRestoreButton.action = #selector(restoreSolos)
        soloRestoreButton.image = FilterCell.restoreIcon
        soloRestoreButton.imagePosition = .imageLeading
        soloRestoreButton.bezelColor = .controlAccentColor
        soloRestoreButton.isHidden = true
        filterController.onChange = { [weak self] selection in
            self?.selection = selection
            self?.persistSelection()
        }
    }

    func rebuildCalendarsMenu(_ calendars: [CalendarSummary]) {
        filterController.update(calendars: calendars, selection: selection)
        calendarsButton.title = FilterSource.buttonTitle(calendars, selection)
        let solos = selection.solos
        soloRestoreButton.isHidden = solos.isEmpty
        soloRestoreButton.title = "还原"
        soloRestoreButton.toolTip = "回到只显示前的状态\n" + solos.map { solo in
            "\(FilterSource(rawValue: solo.source)?.title ?? ""): 只显示「\(solo.title)」"
        }.joined(separator: "\n")
    }

    /// 再次点击关闭: App 在后台时 transient popover 不会因外部点击关闭.
    @objc
    private func showCalendarFilter() {
        if filterPopover.isShown {
            filterPopover.performClose(nil)
        } else {
            filterController.fit(to: calendarsButton)
            filterPopover.show(relativeTo: calendarsButton.bounds, of: calendarsButton, preferredEdge: .maxY)
        }
    }

    @objc
    private func restoreSolos() {
        filterController.restoreAll()
    }

    private func persistSelection() {
        selection.save()
        if let snapshot {
            rebuildCalendarsMenu(snapshot.calendars)
        }
        relayout()
    }
}
