import Foundation

/// 界面状态: 启动时读取, 随界面操作写入; 外部修改需重启.
struct AppState: Codable, Equatable {
    /// 时长 (月数); 起始月不持久化, 每次启动为本月.
    var months = 3
    /// RowSpan.rawValue.
    var rowSpan = 0
    var fontSize = 10.0
    var ignoreMonthTint = false
    var hiddenCalendarIDs: [String] = []
    var window: WindowFrame?
}

struct WindowFrame: Codable, Equatable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
}

/// `~/.config/jj-calendar/state.json`; Debug 构建使用产物旁的独立目录, 调试不影响日常数据.
@MainActor
enum ConfigStore {
    #if DEBUG
    /// 放在 .app 同级: 每份构建 (每个 worktree) 独立, 多实例并行调试互不覆盖, 随 build 目录删除.
    static let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("debug-config", isDirectory: true)
    #else
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/jj-calendar", isDirectory: true)
    #endif
    static let stateURL = directory.appendingPathComponent("state.json")

    private(set) static var state = AppState()
    /// 解析失败时停写, 保留原文件待人工修正.
    private(set) static var failure: String?
    private static var savedData: Data?

    static func load() {
        do {
            guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
            let data = try Data(contentsOf: stateURL)
            state = try decode(data, defaults: AppState())
            savedData = data
        } catch {
            failure = "\(stateURL.path) 解析失败, 本次不保存设置: \(error.localizedDescription)"
        }
    }

    static func update(_ change: (inout AppState) -> Void) {
        change(&state)
        guard failure == nil else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state) + Data("\n".utf8)
            guard data != savedData else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: stateURL, options: .atomic)
            savedData = data
        } catch {
            NSLog("jj-calendar: write \(stateURL.path) failed: \(error)")
        }
    }

    /// 以默认值为底合并文件内容: 缺失键或 null 取默认值 (新增字段不破坏旧文件), 其余按类型解码.
    private static func decode<T: Codable>(_ data: Data, defaults: T) throws -> T {
        guard let override = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults))
        let merged = try JSONSerialization.data(withJSONObject: merge(base, override))
        return try JSONDecoder().decode(T.self, from: merged)
    }

    private static func merge(_ base: Any, _ override: Any) -> Any {
        if override is NSNull {
            return base
        }
        guard var result = base as? [String: Any], let values = override as? [String: Any] else { return override }
        for (key, value) in values {
            result[key] = result[key].map { merge($0, value) } ?? value
        }
        return result
    }
}
