import UIKit

/// Side-by-side tap-to-select columns that fill their height, so far more values are visible than in a wheel.
final class ColumnPicker: UIView, UITableViewDataSource, UITableViewDelegate {
    private var columns: [[String]]
    private var tables: [UITableView] = []
    private(set) var selection: [Int]
    var onChange: (() -> Void)?

    init(columns: [[String]], widths: [CGFloat]) {
        self.columns = columns
        selection = Array(repeating: 0, count: columns.count)
        super.init(frame: .zero)
        let stack = UIStackView()
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for (index, width) in widths.enumerated() {
            let table = UITableView(frame: .zero, style: .plain)
            table.tag = index
            table.dataSource = self
            table.delegate = self
            table.rowHeight = 40
            table.separatorStyle = .none
            table.backgroundColor = .clear
            table.showsVerticalScrollIndicator = false
            table.contentInsetAdjustmentBehavior = .never
            table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
            tables.append(table)
            stack.addArrangedSubview(table)
            if index > 0 {
                let ratio = width / widths[0]
                table.widthAnchor.constraint(equalTo: tables[0].widthAnchor, multiplier: ratio).isActive = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var revealedHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        for table in tables {
            // Pad the end so the last whole-row offset is reachable and the final row is never clipped.
            let inset = bounds.height.truncatingRemainder(dividingBy: table.rowHeight)
            if table.contentInset.bottom != inset {
                table.contentInset.bottom = inset
            }
        }
        // Keep the choice in view when the keyboard resizes the columns.
        guard bounds.height != revealedHeight else { return }
        revealedHeight = bounds.height
        DispatchQueue.main.async { [weak self] in self?.revealSelection() }
    }

    func setItems(_ items: [String], column: Int) {
        guard columns[column] != items else { return }
        columns[column] = items
        selection[column] = min(selection[column], items.count - 1)
        tables[column].reloadData()
    }

    func select(_ row: Int, column: Int) {
        selection[column] = max(0, min(row, columns[column].count - 1))
        tables[column].reloadData()
    }

    /// Centers every selected row on the shared row grid; call after layout so the tables know their height.
    func revealSelection() {
        layoutIfNeeded()
        for (column, table) in tables.enumerated() where table.bounds.height > 0 {
            table.layoutIfNeeded()
            let visibleRows = Int(table.bounds.height / table.rowHeight)
            let top = CGFloat(selection[column] - visibleRows / 2) * table.rowHeight
            table.contentOffset.y = gridOffset(top, in: table)
        }
    }

    /// Offsets snap to whole rows so the columns' rows stay level with each other.
    private func gridOffset(_ y: CGFloat, in table: UITableView) -> CGFloat {
        let maxY = max(0, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
        return min(max(0, (y / table.rowHeight).rounded() * table.rowHeight), maxY)
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity _: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard let table = scrollView as? UITableView else { return }
        targetContentOffset.pointee.y = gridOffset(targetContentOffset.pointee.y, in: table)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection _: Int) -> Int {
        columns[tableView.tag].count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let selected = selection[tableView.tag] == indexPath.row
        var content = cell.defaultContentConfiguration()
        content.text = columns[tableView.tag][indexPath.row]
        content.textProperties.alignment = .center
        content.textProperties.numberOfLines = 1
        // Default cell margins (11 pt) would squeeze the label below the glyph height in a 40 pt row.
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        content.textProperties.font = .monospacedDigitSystemFont(ofSize: 18, weight: selected ? .semibold : .regular)
        content.textProperties.color = selected ? .white : .label
        cell.contentConfiguration = content
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = selected ? .systemOrange : .clear
        background.cornerRadius = 10
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        cell.backgroundConfiguration = background
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let previous = selection[tableView.tag]
        guard previous != indexPath.row else { return }
        selection[tableView.tag] = indexPath.row
        tableView.reloadRows(at: [IndexPath(row: previous, section: 0), indexPath], with: .none)
        UISelectionFeedbackGenerator().selectionChanged()
        onChange?()
    }
}
