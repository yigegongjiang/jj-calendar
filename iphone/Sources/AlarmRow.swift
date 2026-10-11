import UIKit

@MainActor
enum TimeText {
    private static let clockFormatter = formatter("HH:mm")
    private static let dayFormatter = formatter("M月d日")
    private static let weekdayFormatter = formatter("M/d EEE")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }

    /// "07:22" today, "明天 07:22", otherwise "10月14日 07:22".
    static func clock(_ date: Date) -> String {
        let time = clockFormatter.string(from: date)
        if Calendar.current.isDateInToday(date) {
            return time
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "明天 \(time)"
        }
        return "\(dayFormatter.string(from: date)) \(time)"
    }

    /// Column label for a day `offset` days from today.
    static func day(_ date: Date, offset: Int) -> String {
        switch offset {
        case 0: "今天"
        case 1: "明天"
        case 2: "后天"
        default: weekdayFormatter.string(from: date)
        }
    }

    /// Whole minutes left, rounded up so a running alarm never shows "0分".
    static func remaining(until date: Date, from now: Date = Date()) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 {
            return "\(minutes)分"
        }
        return minutes % 60 == 0 ? "\(minutes / 60)时" : "\(minutes / 60)时\(minutes % 60)分"
    }
}

final class AlarmRow: UIControl {
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let remainingLabel = UILabel()

    init(title: String, time: String, remaining: String?) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        timeLabel.text = time
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        remainingLabel.text = remaining
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        remainingLabel.textColor = .secondaryLabel
        remainingLabel.isHidden = remaining == nil
        let stack = UIStackView(arrangedSubviews: [titleLabel, remainingLabel, timeLabel])
        stack.spacing = 8
        stack.alignment = .firstBaseline
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 44)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = [title, time, remaining].compactMap(\.self).joined(separator: " ")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .tertiarySystemFill : .secondarySystemBackground }
    }
}
