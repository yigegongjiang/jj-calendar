import AppKit

enum FilterAction {
    case toggle, solo, ignore, show, hide
}

final class FilterItem: NSObject {
    let summary: CalendarSummary
    let isIgnored: Bool

    init(_ summary: CalendarSummary, isIgnored: Bool) {
        self.summary = summary
        self.isIgnored = isIgnored
    }
}

/// 一个账户的列表, 或「已忽略」.
final class FilterGroup: NSObject {
    let key: String
    let title: String
    let items: [FilterItem]
    let ids: [String]

    var soloKey: String {
        "group:" + key
    }

    init(key: String, title: String, items: [FilterItem]) {
        self.key = key
        self.title = title
        self.items = items
        ids = items.map(\.summary.id)
    }

    /// 当前页签的列表按账户分组 (名称排序), 已忽略置底; 搜索匹配标题或账户名.
    static func make(_ calendars: [CalendarSummary], source: FilterSource, ignored: Set<String>,
                     query: String) -> [FilterGroup] {
        let scoped = calendars.filter(source.contains)
        let matches = query.isEmpty ? scoped : scoped.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query)
        }
        func items(_ list: [CalendarSummary], ignored: Bool) -> [FilterItem] {
            list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { FilterItem($0, isIgnored: ignored) }
        }
        var groups = Dictionary(grouping: matches.filter { !ignored.contains($0.id) }, by: \.source)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { FilterGroup(key: "\(source):\($0.key)", title: $0.key.isEmpty ? "其他" : $0.key,
                               items: items($0.value, ignored: false)) }
        let rest = matches.filter { ignored.contains($0.id) }
        if !rest.isEmpty {
            let title = "已忽略"
            groups.append(FilterGroup(key: "\(source):ignored", title: title, items: items(rest, ignored: true)))
        }
        return groups
    }
}

/// 一行: 复选框 (日历色方框 / 分组三态) + 右侧固定宽度的「只显示」列 (所有行同一位置, 常驻);
/// 「忽略」在其左侧, 悬停才显示 (仅透明度切换, 无障碍始终可按); 分组行在「只显示」左侧显示「显示数 / 总数」.
final class FilterCell: NSTableCellView {
    enum Kind {
        case group, item

        var identifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(self == .group ? "filterGroup" : "filterItem")
        }
    }

    var onAction: ((FilterAction) -> Void)?
    private let kind: Kind
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let soloButton = FilterCell.pushButton("只显示", target: nil, action: nil)
    private let ignoreButton = FilterCell.pushButton("忽略", target: nil, action: nil)
    private var isRevealed = false
    private var soloTitle = "只显示"
    /// 当前只显示的对象: 「还原」常驻.
    private var isSoloTarget = false

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        identifier = kind.identifier
        checkbox.target = self
        checkbox.action = #selector(checkboxPressed)
        checkbox.lineBreakMode = .byTruncatingTail
        checkbox.imageHugsTitle = true
        checkbox.alignment = .left
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 复选框吸收剩余宽度: 否则单元格按内容收缩, 右侧按钮随标题长度漂移.
        checkbox.setContentHuggingPriority(.init(1), for: .horizontal)
        soloButton.target = self
        soloButton.action = #selector(soloPressed)
        ignoreButton.target = self
        ignoreButton.action = #selector(ignorePressed)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        let actions = NSStackView(views: kind == .group ? [soloButton] : [ignoreButton, soloButton])
        actions.spacing = 4
        // 固定宽度: 「只显示」/「还原」/ 悬停边框切换都不改变位置.
        soloButton.widthAnchor.constraint(equalToConstant: 66).isActive = true
        ignoreButton.widthAnchor.constraint(equalToConstant: 70).isActive = true
        for subview in [checkbox, countLabel, actions] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 条目: 复选框铺满到操作按钮, 整行任意处点击即切换; 分组: 空白处点击展开 / 折叠.
            kind == .item
                ? checkbox.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -6)
                : checkbox.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setRevealed(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showItem(_ summary: CalendarSummary, isOn: Bool, isIgnored: Bool, isSolo: Bool) {
        let image = Self.box(summary.color.color, checked: isOn)
        checkbox.image = image
        checkbox.alternateImage = image
        checkbox.state = isOn ? .on : .off
        checkbox.attributedTitle = Self.title(summary.title, size: 13, weight: .regular,
                                              color: isOn ? .labelColor : .secondaryLabelColor)
        checkbox.alphaValue = isIgnored ? 0.5 : 1
        checkbox.setAccessibilityIdentifier(summary.id)
        checkbox.setAccessibilityLabel(summary.title)
        checkbox.toolTip = "\(summary.title)\n⌥ 点击: 只显示此项"
        setSolo(isSolo, name: summary.title, key: summary.id)
        ignoreButton.setAccessibilityIdentifier("ignore:" + summary.id)
        ignoreButton.title = isIgnored ? "取消忽略" : "忽略"
        ignoreButton.toolTip = isIgnored ? "移回所属账户并显示" : "移到「已忽略」: 立即隐藏并置底; 手动勾选才显示 (淡化)"
        ignoreButton.setAccessibilityLabel("\(ignoreButton.title) \(summary.title)")
    }

    func showGroup(_ group: FilterGroup, shown: Int, isSolo: Bool) {
        checkbox.allowsMixedState = true
        checkbox.state = shown == 0 ? .off : shown == group.ids.count ? .on : .mixed
        checkbox.attributedTitle = Self.title(group.title, size: 12, weight: .semibold, color: .secondaryLabelColor)
        checkbox.setAccessibilityIdentifier(group.soloKey)
        checkbox.setAccessibilityLabel(group.title)
        checkbox.toolTip = "整组显示 / 隐藏\n⌥ 点击: 只显示本组"
        countLabel.stringValue = "\(shown)/\(group.ids.count)"
        setSolo(isSolo, name: group.title, key: group.soloKey)
    }

    /// 只显示对象: 强调色「还原」; 其余行「只显示」.
    private func setSolo(_ isSolo: Bool, name: String, key: String) {
        isSoloTarget = isSolo
        soloTitle = isSolo ? "还原" : "只显示"
        soloButton.image = isSolo ? Self.restoreIcon : nil
        soloButton.imagePosition = .imageLeading
        soloButton.toolTip = isSolo ? "还原到只显示前的状态" : "只显示\(name) (当前页签内; 可随时还原)"
        soloButton.setAccessibilityLabel("\(soloTitle) \(name)")
        soloButton.setAccessibilityIdentifier("only:" + key)
        setRevealed(isRevealed)
    }

    /// 「只显示」常驻: 平时淡色文字, 悬停 / 键盘选中加边框; 「还原」始终强调色边框. 「忽略」仅悬停显示.
    func setRevealed(_ revealed: Bool) {
        isRevealed = revealed
        let prominent = revealed || isSoloTarget
        soloButton.isBordered = prominent
        soloButton.bezelColor = isSoloTarget ? .controlAccentColor : nil
        if prominent {
            soloButton.title = soloTitle
        } else {
            soloButton.attributedTitle = NSAttributedString(string: soloTitle, attributes: [
                .font: soloButton.font ?? .systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor
            ])
        }
        ignoreButton.alphaValue = revealed ? 1 : 0
    }

    @objc
    private func checkboxPressed() {
        onAction?(NSEvent.modifierFlags.contains(.option) ? .solo : .toggle)
    }

    @objc
    private func soloPressed() {
        onAction?(.solo)
    }

    @objc
    private func ignorePressed() {
        onAction?(.ignore)
    }

    static let restoreIcon = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "还原")

    static func pushButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        return button
    }

    private static func title(_ text: String, size: CGFloat, weight: NSFont.Weight,
                              color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
        ])
    }

    /// 日历色圆角方框: 勾选 = 实心 + 对勾 (按底色亮度取黑 / 白), 未勾选 = 描边.
    private static func box(_ color: NSColor, checked: Bool) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            guard checked else {
                color.setStroke()
                path.lineWidth = 1.5
                path.stroke()
                return true
            }
            color.setFill()
            path.fill()
            let rgb = color.usingColorSpace(.sRGB) ?? color
            let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                .applying(.init(paletteColors: [luminance > 0.6 ? .black : .white]))
            if let mark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let origin = NSPoint(x: (size.width - mark.size.width) / 2, y: (size.height - mark.size.height) / 2)
                mark.draw(in: NSRect(origin: origin, size: mark.size))
            }
            return true
        }
    }
}

/// 悬停高亮 + 通知单元格显示操作按钮; 选中 (键盘) 用强调色浅底, 文字保持原色.
final class FilterRowView: NSTableRowView {
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            updateReveal()
        }
    }

    override var isSelected: Bool {
        didSet { updateReveal() }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
            ))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateReveal()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 5, yRadius: 5).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 5, yRadius: 5).fill()
    }

    private func updateReveal() {
        // viewAtColumn: 在单元格加入前调用会断言失败, 直接查子视图.
        for case let cell as FilterCell in subviews {
            cell.setRevealed(isHovered || isSelected)
        }
    }
}

/// 键盘: 空格 / 回车 = 切换 (⌥ = 只显示); 首行 ↑ 回到搜索框.
final class FilterOutlineView: NSOutlineView {
    var onToggle: ((_ solo: Bool) -> Void)?
    var onExitTop: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76:
            guard selectedRow >= 0 else { return super.keyDown(with: event) }
            onToggle?(event.modifierFlags.contains(.option))
        case 126 where selectedRow <= 0:
            onExitTop?()
        default:
            super.keyDown(with: event)
        }
    }
}

/// 只显示中的横幅: 强调色底 + 对象 + 「还原」/「保留当前」.
final class SoloBanner: NSView {
    var onRestore: (() -> Void)?
    var onKeep: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("soloBanner")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let restore = FilterCell.pushButton("还原", target: self, action: #selector(restorePressed))
        restore.image = FilterCell.restoreIcon
        restore.imagePosition = .imageLeading
        restore.bezelColor = .controlAccentColor
        restore.toolTip = "回到只显示前的状态"
        restore.setAccessibilityIdentifier("soloRestore")
        let keep = FilterCell.pushButton("保留当前", target: self, action: #selector(keepPressed))
        keep.toolTip = "保持现在的显示, 不再提示还原"
        keep.setAccessibilityIdentifier("soloKeep")
        let texts = NSStackView(views: [titleLabel, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [texts, keep, restore])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        setAccessibilityLabel("\(title), \(detail)")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    @objc
    private func restorePressed() {
        onRestore?()
    }

    @objc
    private func keepPressed() {
        onKeep?()
    }
}
