import EventKit
import UIKit

extension UIMenu {
    /// Inline pick-list of reminder lists, grouped by account only when there is more than one.
    static func lists(_ lists: [EKCalendar], current: String?, select: @escaping (String) -> Void) -> UIMenu {
        let action = { (list: EKCalendar) in
            UIAction(title: list.title, state: list.calendarIdentifier == current ? .on : .off) { _ in
                select(list.calendarIdentifier)
            }
        }
        let sources = Dictionary(grouping: lists, by: { $0.source.title })
        var sections: [UIMenuElement] = sources.count > 1
            ? sources.keys.sorted().map { source in
                UIMenu(title: source, options: .displayInline, children: (sources[source] ?? []).map(action))
            }
            : lists.map(action)
        // The current list stays reachable at the top of a long menu.
        if let selected = lists.first(where: { $0.calendarIdentifier == current }) {
            sections.insert(UIMenu(options: .displayInline, children: [action(selected)]), at: 0)
        }
        return UIMenu(children: sections)
    }
}
