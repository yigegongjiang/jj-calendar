import AppKit

/// 一行: 日期格 (≤ 7 / 14 个, 区间首日前、末日后留空) + 事件 chip; 无子视图, 整行渲染为一张位图 (layer.contents).
/// 滚动只移动图层不重绘; 仅内容 / 尺寸 / 外观变化时重新渲染, 后台线程渲染 (主线程不排版文字); 远离视口 (isLive = false) 释放位图.
/// 容量不足的列: 末行改为「+N 项」; 点击日期格 / chip / +N -> 当日完整列表 (onSelectDay).
/// 双击可写 chip -> 编辑 (onEditItem); 双击日期格空白 -> 当日新建日程 (onCreate).
/// AX: 日期格 / chip / +N 为虚拟子元素 (可按下); 日期格自定义动作「新建日程 / 新建提醒」, 可写 chip「编辑」; 悬停 chip / +N 显示 tooltip.
final class WeekRowView: NSView {
    struct Config: Equatable {
        let typography: Typography
        let capacity: Int
        let monthTint: Bool
    }

    private struct Slot {
        let art: SlotArt
        let startCol: Int
        let endCol: Int
        let line: Int
    }

    enum SlotArt {
        case chip(ChipArt)
        case more(MoreArt)
    }

    /// 渲染时的尺寸 / 缩放 / 外观; 任一变化需重新渲染.
    private struct RenderKey: Equatable {
        let size: NSSize
        let scale: CGFloat
        let appearance: NSAppearance.Name
    }

    /// 点击 / AX 按下某列 -> 由 WeekGridView 弹出当日列表, 锚定该日期格 (本视图坐标).
    var onSelectDay: ((_ col: Int, _ cell: NSRect) -> Void)?
    /// 编辑条目, 锚定 chip (本视图坐标).
    var onEditItem: ((_ item: CalendarEvent, _ rect: NSRect) -> Void)?
    /// 在该列日期新建, 锚定日期格.
    var onCreate: ((_ col: Int, _ cell: NSRect, _ isReminder: Bool) -> Void)?

    /// 位于视口附近: 持有位图; 否则释放 (位图内存只随视口增长).
    var isLive = false {
        didSet {
            guard isLive != oldValue else { return }
            if isLive {
                needsDisplay = true
            } else {
                releaseRendering()
            }
        }
    }

    /// 与视口相交 (由 WeekGridView 设置); 无位图时同步渲染.
    var isOnScreen = false {
        didSet {
            if isOnScreen, !oldValue, layer?.contents == nil {
                needsDisplay = true
            }
        }
    }

    private var row: WeekRow?
    private var config: Config?
    private var calendar: Calendar?
    private var cells: [DayCellArt] = []
    private var slots: [Slot] = []
    /// slots 的当前位置 (layout 计算); tooltip / AX 共用.
    private var slotRects: [NSRect] = []
    private var renderedKey: RenderKey?
    /// 后台渲染中的 key; 完成时 generation 未变才采用 (内容变化 / 释放后旧结果作废).
    private var pendingKey: RenderKey?
    private var generation = 0
    private var elements: [NSAccessibilityElement]?
    /// 本行折叠 (未显示) 的日程格次数.
    private(set) var hiddenTotal = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    /// 内容 / 行高 / 容量变化时才重建 (数据刷新时未变的行不重建); 仅尺寸变化走 layout().
    func apply(_ config: Config, row: WeekRow, calendar: Calendar) {
        guard config != self.config || row != self.row || calendar != self.calendar else { return }
        self.config = config
        self.row = row
        self.calendar = calendar
        let capacity = config.capacity

        slots = []
        // 每列独立: 超出容量 -> 可见行数 = 容量 - 1, 末行留给「+N 项」.
        let visible = row.days.indices.map { col in
            row.lanesPerColumn[col] + row.timed[col].count > capacity ? max(0, capacity - 1) : capacity
        }
        var hidden = Array(repeating: [CalendarEvent](), count: row.days.count)
        placeBars(row.bars, visible: visible, hidden: &hidden, typography: config.typography)
        for (col, events) in row.timed.enumerated() {
            for (offset, event) in events.enumerated() {
                let line = row.lanesPerColumn[col] + offset
                guard line < visible[col] else {
                    hidden[col].append(event)
                    continue
                }
                let art = ChipArt(
                    event: event, style: .timed, dimmed: row.days[col].isPast, typography: config.typography
                )
                slots.append(Slot(art: .chip(art), startCol: col, endCol: col, line: line))
            }
        }
        for col in row.days.indices where !hidden[col].isEmpty && visible[col] < capacity {
            let art = MoreArt(hidden: hidden[col], typography: config.typography)
            slots.append(Slot(art: .more(art), startCol: col, endCol: col, line: visible[col]))
        }
        hiddenTotal = hidden.reduce(0) { $0 + $1.count }

        // 首行首日前为空白: 首日补左边线.
        cells = row.days.enumerated().map { col, day in
            DayCellArt(
                info: day,
                eventCount: row.timed[col].count + row.bars.count { ($0.startCol...$0.endCol).contains(col) },
                hidden: hidden[col].count, drawsLeadingEdge: col == 0 && row.offset > 0,
                fontSize: config.typography.fontSize, monthTint: config.monthTint
            )
        }
        if let first = row.days.first, let last = row.days.last {
            setAccessibilityLabel("\(EventText.day(first.date)) – \(EventText.day(last.date))")
        }
        // 旧位图是别的内容: 丢弃, 可见行同步重绘 (不显示过时数据).
        layer?.contents = nil
        invalidateRendering()
        needsLayout = true
    }

    /// 横条只画在仍有空间 (lane < 该列可见行数) 的连续列段上; 其余列计入该列折叠.
    private func placeBars(
        _ bars: [BarSlot], visible: [Int], hidden: inout [[CalendarEvent]], typography: Typography
    ) {
        for bar in bars {
            var runStart: Int?
            for col in bar.startCol...(bar.endCol + 1) {
                if col <= bar.endCol, bar.lane < visible[col] {
                    runStart = runStart ?? col
                    continue
                }
                if col <= bar.endCol {
                    hidden[col].append(bar.event)
                }
                if let start = runStart {
                    let art = ChipArt(
                        event: bar.event, style: .bar(bar.continued || start > bar.startCol), dimmed: bar.isPast,
                        typography: typography
                    )
                    slots.append(Slot(art: .chip(art), startCol: start, endCol: col - 1, line: bar.lane))
                    runStart = nil
                }
            }
        }
    }

    /// 外观 / 强调色等系统颜色变化: 下次显示时重新渲染.
    func invalidateRendering() {
        renderedKey = nil
        pendingKey = nil
        generation += 1
        needsDisplay = true
    }

    private func releaseRendering() {
        layer?.contents = nil
        renderedKey = nil
        pendingKey = nil
        generation += 1
    }

    /// 日下标 -> 列: 首行整体右移 offset 列 (首日落在其星期列).
    private func columnX(_ index: Int) -> CGFloat {
        guard let row else { return 0 }
        return WeekGeometry.columnX(row.offset + index, of: row.columns, width: bounds.width)
    }

    /// 日期格位置 (本视图坐标); 当日列表锚点.
    func cellRect(_ col: Int) -> NSRect {
        let x = columnX(col)
        return NSRect(x: x, y: 0, width: columnX(col + 1) - x, height: bounds.height)
    }

    private func select(_ col: Int) {
        guard cells.indices.contains(col) else { return }
        onSelectDay?(col, cellRect(col))
    }

    /// 按横坐标定位列; 双击: chip -> 编辑 (只读 / +N 忽略), 空白 -> 新建日程.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let col = cells.indices.first { cellRect($0).minX <= point.x && point.x < cellRect($0).maxX }
        guard let col else { return }
        switch event.clickCount {
        case 1:
            select(col)
        case 2:
            if let index = slotRects.firstIndex(where: { $0.contains(point) }) {
                if case let .chip(art) = slots[index].art, art.event.isWritable {
                    onEditItem?(art.event, slotRects[index])
                }
            } else {
                onCreate?(col, cellRect(col), false)
            }
        default:
            break
        }
    }

    /// 后台窗口首次点击即生效.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        guard let config else { return }
        let line = config.typography.line
        let top = config.typography.header
        slotRects = slots.map { slot in
            let x = columnX(slot.startCol)
            return NSRect(
                x: x + 1, y: top + CGFloat(slot.line) * line, width: columnX(slot.endCol + 1) - x - 3, height: line - 1
            )
        }
        removeAllToolTips()
        for rect in slotRects {
            addToolTip(rect, owner: self, userData: nil)
        }
        elements = nil
        if renderedKey?.size != bounds.size {
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// 仅在渲染条件变化时重绘; AppKit 额外的 display 调用直接返回.
    /// 可见且尚无位图 -> 同步渲染 (不出现空白帧); 其余后台渲染, 完成前保留旧位图.
    override func updateLayer() {
        guard isLive, row != nil else {
            releaseRendering()
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let key = RenderKey(size: bounds.size, scale: scale, appearance: effectiveAppearance.name)
        guard key != renderedKey else { return }
        let blank = layer?.contents == nil && isOnScreen
        guard blank || key != pendingKey else { return }
        let picture = RowPicture(
            size: bounds.size, scale: scale, appearance: effectiveAppearance,
            colorSpace: window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            cells: cells.indices.map { (cellRect($0), cells[$0]) }, slots: zip(slotRects, slots.map(\.art)).map(\.self)
        )
        generation += 1
        if blank {
            show(picture.render(), key: key)
            return
        }
        let generation = generation
        pendingKey = key
        Task.detached(priority: .userInitiated) {
            let image = picture.render()
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                show(image, key: key)
            }
        }
    }

    private func show(_ image: CGImage?, key: RenderKey) {
        layer?.contents = image
        layer?.contentsScale = key.scale
        renderedKey = key
        pendingKey = nil
    }
}

extension WeekRowView: NSViewToolTipOwner {
    func view(
        _: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?
    ) -> String {
        guard let calendar, let index = slotRects.firstIndex(where: { $0.contains(point) }) else { return "" }
        return switch slots[index].art {
        case let .chip(art): EventText.detail(art.event, calendar: calendar)
        case let .more(art): art.toolTip(calendar: calendar)
        }
    }
}

extension WeekRowView {
    /// 按下 = 打开当日列表; frame = 行内 rect 换算到屏幕 (随滚动更新).
    private final class RowElement: NSAccessibilityElement {
        weak var view: NSView?
        var rect = NSRect.zero
        var onPress: (() -> Void)?

        override func accessibilityFrame() -> NSRect {
            guard let view, let window = view.window else { return .zero }
            return window.convertToScreen(view.convert(rect, to: nil))
        }

        override func accessibilityPerformPress() -> Bool {
            onPress?()
            return onPress != nil
        }
    }

    override func accessibilityChildren() -> [Any]? {
        if elements == nil {
            elements = makeElements()
        }
        return elements
    }

    private func makeElements() -> [NSAccessibilityElement] {
        guard let calendar else { return [] }
        func element(_ role: NSAccessibility.Role, _ label: String, _ frame: NSRect, col: Int) -> RowElement {
            let element = RowElement()
            element.setAccessibilityElement(true)
            element.setAccessibilityRole(role)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.view = self
            element.rect = frame
            element.onPress = { [weak self] in self?.select(col) }
            return element
        }
        func action(_ name: String, _ body: @escaping @MainActor (WeekRowView) -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self else { return false }
                body(self)
                return true
            }
        }
        let days = cells.enumerated().map { col, cell in
            let day = element(.group, cell.accessibilityLabel, cellRect(col), col: col)
            day.setAccessibilityCustomActions([
                action("新建日程") { $0.onCreate?(col, $0.cellRect(col), false) },
                action("新建提醒") { $0.onCreate?(col, $0.cellRect(col), true) }
            ])
            return day
        }
        let items = zip(slots, slotRects).map { slot, rect -> RowElement in
            switch slot.art {
            case let .chip(art):
                let chip = element(
                    .staticText,
                    EventText.detail(art.event, calendar: calendar).replacingOccurrences(of: "\n", with: " · "),
                    rect, col: slot.startCol
                )
                if art.event.isWritable {
                    chip.setAccessibilityCustomActions([action("编辑") { $0.onEditItem?(art.event, rect) }])
                }
                return chip
            case let .more(art):
                return element(.button, "另有 \(art.hidden.count) 项未显示, 查看当日全部", rect, col: slot.startCol)
            }
        }
        return days + items
    }
}
