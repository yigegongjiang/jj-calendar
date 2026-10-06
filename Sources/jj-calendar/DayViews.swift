import AppKit

/// 日期格: 月份底色微弱交替 (可关) + 日期号 (1 日强调色实心标签「MM - 01」, 区间首月 / 1 月带年份「yyyy - MM - 01」); 星期见表头; 折叠数见同列「+N 项」.
/// 由 WeekRowView 绘入行位图.
struct DayCellArt {
    let info: DayInfo
    let eventCount: Int
    let hidden: Int
    let drawsLeadingEdge: Bool
    let fontSize: CGFloat
    let monthTint: Bool

    @MainActor
    var accessibilityLabel: String {
        let suffix = info.isToday ? " 今天" : ""
        let folded = hidden == 0 ? "" : ", 另有 \(hidden) 个未显示"
        return "\(info.year)年\(EventText.day(info.date))\(suffix), \(eventCount) 个日程\(folded)"
    }

    func draw(size: NSSize) {
        let bounds = NSRect(origin: .zero, size: size)
        let background: NSColor = if monthTint, info.month.isMultiple(of: 2) {
            NSColor.controlBackgroundColor.blended(withFraction: 0.025, of: .labelColor) ?? .controlBackgroundColor
        } else {
            .controlBackgroundColor
        }
        background.setFill()
        bounds.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        if drawsLeadingEdge {
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }

        let isWeekend = info.weekday == 1 || info.weekday == 7
        let isFirst = info.day == 1
        // 1 日: 实心强调色标签; 区间首月 / 1 月带年份 (跨年辨认).
        let text = !isFirst ? "\(info.day)"
            : info.showsYear ? String(format: "%04d - %02d - 01", info.year, info.month)
            : String(format: "%02d - 01", info.month)
        let color: NSColor = info.isToday || isFirst ? .white
            : info.isPast ? .secondaryLabelColor
            : isWeekend ? .secondaryLabelColor : .labelColor
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: fontSize - 0.5, weight: info.day == 1 || info.isToday ? .bold : .regular
            ),
            .foregroundColor: color
        ])
        let size = label.size()
        // 标签左右留白 padding, 上方留白 topPad (数字视觉偏上, 补顶部即居中); 行高见 Typography.header.
        let padding: CGFloat = 5
        let topPad: CGFloat = 1
        let origin = NSPoint(x: 1 + padding, y: 1 + topPad)
        if info.isToday || isFirst {
            (info.isToday ? NSColor.systemRed : NSColor.controlAccentColor).setFill()
            let pill = NSRect(
                x: origin.x - padding, y: origin.y - topPad,
                width: size.width + padding * 2, height: size.height + topPad
            )
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        }
        label.draw(at: origin)
    }
}

/// 列折叠提示「+N 项」: 强调色; 点击 / AX 按下 -> 当日完整列表; 悬停列出未显示条目.
struct MoreArt {
    let hidden: [CalendarEvent]
    private let text: NSAttributedString
    private let textHeight: CGFloat

    @MainActor
    init(hidden: [CalendarEvent], typography: Typography) {
        self.hidden = hidden
        text = NSAttributedString(string: "+\(hidden.count) 项", attributes: [
            .font: NSFont.systemFont(ofSize: typography.fontSize - 0.5, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor
        ])
        textHeight = text.size().height
    }

    @MainActor
    func toolTip(calendar: Calendar) -> String {
        "另有 \(hidden.count) 项, 点击查看当日全部\n" + hidden.map {
            EventText.detail($0, calendar: calendar).replacingOccurrences(of: "\n", with: " · ")
        }.joined(separator: "\n")
    }

    func draw(size: NSSize) {
        let bounds = NSRect(origin: .zero, size: size)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        text.draw(in: NSRect(x: 5, y: (bounds.height - textHeight) / 2, width: bounds.width - 6, height: textHeight))
    }
}

/// 一行的绘制快照 (不可变): 主线程生成, 任意线程渲染 (AppKit 文字 / 路径绘制支持后台线程, 每线程独立 NSGraphicsContext).
struct RowPicture: @unchecked Sendable {
    let size: NSSize
    let scale: CGFloat
    let appearance: NSAppearance
    let colorSpace: CGColorSpace
    let cells: [(NSRect, DayCellArt)]
    let slots: [(NSRect, WeekRowView.SlotArt)]

    func render() -> CGImage? {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // 与视图一致: 原点左上, 单位 pt.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        appearance.performAsCurrentDrawingAppearance {
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            for (rect, cell) in cells {
                draw(in: rect, context: context) { cell.draw(size: $0) }
            }
            for (rect, art) in slots {
                switch art {
                case let .chip(chip):
                    draw(in: rect, context: context, alpha: chip.alpha) { chip.draw(size: $0, isDark: isDark) }
                case let .more(more):
                    draw(in: rect, context: context) { more.draw(size: $0) }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// 平移到 rect 原点并裁剪, 各部件按自身尺寸绘制.
    private func draw(in rect: NSRect, context: CGContext, alpha: CGFloat = 1, _ body: (NSSize) -> Void) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.clip(to: CGRect(origin: .zero, size: rect.size))
        context.setAlpha(alpha)
        body(rect.size)
        context.restoreGState()
    }
}

/// 事件条目: bar = 全天 / 跨天横条 (continued = 起点在本段之前); timed = 单日定时事件 (色点 + 时间 + 标题).
/// 提醒事项: 两种样式均画勾选圈 (已完成 = 实心 + 删除线 + 淡化; 逾期 = 时间红色), 无底色.
struct ChipArt {
    enum Style { case bar(_ continued: Bool), timed }

    let event: CalendarEvent
    let alpha: CGFloat
    private let style: Style
    private let text: NSAttributedString
    /// 仅标题; 窄格放不下「时间 + 几个字」时改用, 保证标题可见.
    private let titleText: NSAttributedString
    /// 低于此宽度用 titleText.
    private let compactWidth: CGFloat
    private let textX: CGFloat
    private let textHeight: CGFloat
    private let titleHeight: CGFloat

    @MainActor
    init(event: CalendarEvent, style: Style, dimmed: Bool, typography: Typography) {
        self.event = event
        self.style = style
        let fontSize = typography.fontSize
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let isOverdue = event.isOverdue
        var timeAttributes = secondary
        if isOverdue {
            timeAttributes[.foregroundColor] = NSColor.systemRed
        }
        let prefix = NSMutableAttributedString()
        switch style {
        case let .bar(continued):
            textX = event.isReminder ? Self.reminderTextX(fontSize) : 5
            if continued {
                prefix.append(NSAttributedString(string: "← ", attributes: secondary))
            } else if !event.isAllDay {
                prefix.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: timeAttributes))
            } else if isOverdue {
                // 仅日期的逾期提醒无时间可标红: 补红色「逾期」.
                prefix.append(NSAttributedString(string: "逾期 ", attributes: timeAttributes))
            }
        case .timed:
            textX = event.isReminder ? Self.reminderTextX(fontSize) : min(9, fontSize - 1)
            prefix.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: timeAttributes))
        }
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let title = Self.title(event, fontSize: fontSize, paragraph: truncating)
        let text = NSMutableAttributedString(attributedString: prefix)
        text.append(title)
        text.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: text.length))
        // 不可变副本: 后台渲染线程只读.
        self.text = NSAttributedString(attributedString: text)
        titleText = title
        textHeight = text.size().height
        titleHeight = title.size().height
        compactWidth = textX + prefix.size().width + fontSize * 3
        // 提醒只按完成状态淡化: 逾期未完成的提醒在过去的日期也保持醒目.
        let dimmed = event.isReminder ? event.isCompleted : dimmed
        alpha = event.isIgnored ? 0.3 : dimmed ? 0.6 : 1
    }

    func draw(size: NSSize, isDark: Bool) {
        let bounds = NSRect(origin: .zero, size: size)
        let color = event.color.color
        switch style {
        case _ where event.isReminder:
            drawCheckCircle(color, bounds: bounds)
        case .bar:
            color.withAlphaComponent(isDark ? 0.4 : 0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
            color.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        case .timed:
            let dot = min(6, bounds.height - 6)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: (bounds.height - dot) / 2, width: dot, height: dot)).fill()
        }
        let compact = bounds.width < compactWidth
        let height = compact ? titleHeight : textHeight
        let rect = NSRect(x: textX, y: (bounds.height - height) / 2, width: bounds.width - textX - 1, height: height)
        (compact ? titleText : text).draw(in: rect)
    }

    /// 已完成提醒: 删除线 + 次要色.
    private static func title(
        _ event: CalendarEvent, fontSize: CGFloat, paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        if event.isCompleted {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        return NSAttributedString(string: event.title, attributes: attributes)
    }

    private static func reminderTextX(_ fontSize: CGFloat) -> CGFloat {
        min(12, fontSize + 2)
    }

    /// 提醒勾选圈: 未完成 = 描边, 已完成 = 实心.
    private func drawCheckCircle(_ color: NSColor, bounds: NSRect) {
        let size = min(textX - 4, bounds.height - 4)
        let circle = NSBezierPath(ovalIn: NSRect(x: 1.5, y: (bounds.height - size) / 2, width: size, height: size))
        if event.isCompleted {
            color.setFill()
            circle.fill()
        } else {
            color.setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
        }
    }
}

/// 当日完整列表 (popover 内容): 全部日程 / 提醒, 只读; 文本可选中复制 (如账号); 超高时滚动.
final class DayDetailController: NSViewController {
    private static let width: CGFloat = 340
    private static let maxHeight: CGFloat = 520
    private static let inset: CGFloat = 12
    private static let markerWidth: CGFloat = 10

    /// 当前展示的日期 (再次点击同日 = 关闭; 数据刷新时据此定位).
    private(set) var date: Date?
    private let stack = NSStackView()
    private let document = FlippedView()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: Self.inset, bottom: 12, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("dayDetail")
        view = scrollView
    }

    func update(day: DayInfo, items: [CalendarEvent], calendar: Calendar) {
        _ = view
        date = day.date
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let today = day.isToday ? " · 今天" : ""
        let header = NSTextField(labelWithString: "\(day.year)年\(EventText.day(day.date))\(today) · \(items.count) 项")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(header)
        if items.isEmpty {
            stack.addArrangedSubview(secondaryLabel("无日程"))
        }
        for event in items {
            stack.addArrangedSubview(itemRow(event, calendar: calendar))
        }
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        document.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        preferredContentSize = NSSize(width: Self.width, height: min(height, Self.maxHeight))
        view.setAccessibilityLabel(header.stringValue)
    }

    /// 标记 + [时间 标题 / 日历 · 状态 · 地点].
    private func itemRow(_ event: CalendarEvent, calendar: Calendar) -> NSView {
        let isOverdue = event.isOverdue
        let when = NSAttributedString(string: EventText.when(event, calendar: calendar) + "  ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: isOverdue ? NSColor.systemRed : NSColor.secondaryLabelColor
        ])
        var titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
        ]
        if event.isCompleted {
            titleAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            titleAttributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        let line = NSMutableAttributedString(attributedString: when)
        line.append(NSAttributedString(string: event.title, attributes: titleAttributes))
        let title = NSTextField(labelWithAttributedString: line)
        configureWrapping(title)

        let state = event.isCompleted ? "已完成" : isOverdue ? "逾期" : nil
        let source = event.isReminder ? "提醒事项 · \(event.calendarTitle)" : event.calendarTitle
        let detail = secondaryLabel([source, state, event.location].compactMap(\.self).joined(separator: " · "))
        configureWrapping(detail)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let marker = NSImageView(image: Self.marker(event))
        marker.setAccessibilityElement(false)
        let row = NSStackView(views: [marker, text])
        row.alignment = .top
        row.spacing = 6
        row.alphaValue = event.isIgnored ? 0.5 : 1
        return row
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// 多行换行 + 可选中复制.
    private func configureWrapping(_ label: NSTextField) {
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = Self.width - Self.inset * 2 - Self.markerWidth - 6
    }

    /// 日程 = 日历色竖条; 提醒 = 勾选圈 (已完成实心).
    private static func marker(_ event: CalendarEvent) -> NSImage {
        let color = event.color.color
        return NSImage(size: NSSize(width: markerWidth, height: 15), flipped: true) { _ in
            if event.isReminder {
                let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: 3, width: 8, height: 8))
                if event.isCompleted {
                    color.setFill()
                    circle.fill()
                } else {
                    color.setStroke()
                    circle.lineWidth = 1.2
                    circle.stroke()
                }
            } else {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 4, height: 13), xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
    }
}
