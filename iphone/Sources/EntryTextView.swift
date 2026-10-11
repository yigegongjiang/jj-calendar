import UIKit

/// Grows with its text up to `maxHeight`, then scrolls internally.
final class EntryTextView: UITextView {
    private let maxHeight: CGFloat = 200
    private var previousWidth: CGFloat = 0

    init() {
        super.init(frame: .zero, textContainer: nil)
        font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20, weight: .medium))
        adjustsFontForContentSizeCategory = true
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textContainer.lineFragmentPadding = 0
        returnKeyType = .done
        isScrollEnabled = false
        accessibilityLabel = "事项"
        accessibilityIdentifier = "entry.text"
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var fittingHeight: CGFloat {
        sizeThatFits(CGSize(width: max(bounds.width, 100), height: .greatestFiniteMagnitude)).height
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: min(fittingHeight, maxHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previousWidth != bounds.width {
            previousWidth = bounds.width
            updateSizing()
        }
    }

    func updateSizing() {
        let scrolls = fittingHeight > maxHeight
        if isScrollEnabled != scrolls {
            isScrollEnabled = scrolls
        }
        invalidateIntrinsicContentSize()
        if scrolls {
            scrollRangeToVisible(selectedRange)
        }
    }
}
