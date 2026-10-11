import CryptoKit
@preconcurrency import EventKit
import Foundation

extension ReminderService {
    func checkWritable(_ list: EKCalendar?) throws {
        guard let list, let fresh = store.calendar(withIdentifier: list.calendarIdentifier),
              fresh.allowsContentModifications else { throw EntryError.message("该列表不可写。") }
        #if DEBUG
        let titles: Set = ["test 待办", "test 购物", "test 工作跟进"]
        let fingerprint = SHA256.hash(data: Data(fresh.source.title.lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
        // iOS exposes only "iCloud" as the source title. Bind its opaque ID after
        // checking the device's Apple Account sign-in addresses; new sources fail closed.
        let verifiedDeviceSource = Diagnostics.fingerprint(fresh.source.sourceIdentifier)
            == Bundle.main.object(forInfoDictionaryKey: "JJDebugSourceFingerprint") as? String
            && fresh.source.title == "iCloud"
        let expectedAccount = Bundle.main.object(forInfoDictionaryKey: "JJDebugAccountFingerprint") as? String
        let verifiedAccount = fingerprint == expectedAccount
        guard titles.contains(fresh.title), fresh.source.sourceType == .calDAV,
              verifiedAccount || verifiedDeviceSource else {
            throw EntryError.message("Debug 只允许写入指定 iCloud 账户的 test 待办 / test 购物 / test 工作跟进。")
        }
        #endif
    }
}
