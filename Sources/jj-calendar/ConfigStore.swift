import Foundation

/// 界面选项: config.jsonc, 带逐键说明, 可手工编辑 (重启生效), 界面操作时整文件重写.
struct AppConfig: Codable, Equatable {
    /// 时长 (月数); 起始月不持久化, 每次启动为本月.
    var months = 3
    /// RowSpan.rawValue.
    var rowSpan = 0
    var fontSize = 10.0
    var ignoreMonthTint = false
}

/// 界面状态: state.json, App 写入.
struct AppState: Codable, Equatable {
    var hiddenCalendarIDs: [String] = []
    /// 不参与批量显示 / 隐藏, 事件淡化.
    var ignoredCalendarIDs: [String] = []
    /// 筛选面板: 当前页签 (FilterSource.rawValue) + 折叠的分组 key; 默认折叠「已忽略」.
    var filterTab = 0
    /// 整源关闭的 FilterSource.rawValue: 主界面不显示该源, 各列表勾选不变.
    var disabledSources: [Int] = []
    /// 各页签「只显示」还原点.
    var solos: [SoloRecord] = []
    var collapsedCalendarGroups: [String] = ["calendars:ignored", "reminders:ignored"]
    var window: WindowFrame?
}

struct WindowFrame: Codable, Equatable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
}

/// `~/.config/jj-calendar/`; Debug 构建使用产物旁的独立目录, 调试不影响日常数据.
/// - `config.jsonc`: 界面选项; `config.default.jsonc`: 全部键默认值, 每次启动刷新, 仅供查阅.
/// - `state.json`: 界面状态.
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

    private static var configFile = PersistedFile(
        url: directory.appendingPathComponent("config.jsonc"), defaults: AppConfig(), jsonc: true,
        render: { try encodeConfig($0) }
    )
    private static var stateFile = PersistedFile(
        url: directory.appendingPathComponent("state.json"), defaults: AppState(), jsonc: false,
        render: { try encode($0) }
    )

    static var config: AppConfig {
        configFile.value
    }

    static var state: AppState {
        stateFile.value
    }

    /// 窗口副标题提示.
    static var warnings: String {
        [configFile.failure, stateFile.failure].compactMap(\.self).joined(separator: "; ")
    }

    /// 读取两份文件; 刷新默认模板; 缺失的 config.jsonc 以默认值新建.
    static func load() {
        configFile.load()
        stateFile.load()
        configFile.update { _ in }
        do {
            let template = try encodeConfig(AppConfig())
            let url = directory.appendingPathComponent("config.default.jsonc")
            if (try? Data(contentsOf: url)) != template {
                try write(template, to: url)
            }
        } catch {
            NSLog("jj-calendar: write config.default.jsonc failed: \(error)")
        }
    }

    static func updateConfig(_ change: (inout AppConfig) -> Void) {
        configFile.update(change)
    }

    static func update(_ change: (inout AppState) -> Void) {
        stateFile.update(change)
    }

    fileprivate static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    fileprivate static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    /// 逐键插入中文说明; 数值取自模型.
    private static func encodeConfig(_ config: AppConfig) throws -> Data {
        let text = try String(bytes: encode(config), encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let parts = line.split(separator: "\"", maxSplits: 2)
            guard parts.count == 3, let note = configNotes[String(parts[1])] else { return line }
            let indent = String(line.prefix(while: { $0 == " " }))
            return "\(indent)// \(note)\n\(line)"
        }
        let header = "// 界面操作时由 App 重写本文件; 手工修改后重启生效; 缺失键 / null 取默认值.\n"
        return Data((header + lines.joined(separator: "\n")).utf8)
    }

    private static let configNotes: [String: String] = [
        "months": "时长 (月数): 1 / 3 / 6 / 9 / 12 / 15 / 18 / 21 / 24; 其他值取 3. 起始月每次启动为本月.",
        "rowSpan": "每行天数: 0 一周 / 1 两周; 其他值取一周.",
        "fontSize": "字号 (pt), 8–16; ⌘+ / ⌘- / ⌘0 调整.",
        "ignoreMonthTint": "true = 不显示隔月背景色 (标题栏「忽略背景色」)."
    ]
}

/// 一份 JSON / JSONC 文件: 以默认值为底读取, 变化时整文件重写; 解析失败停写, 保留原文件待人工修正.
@MainActor
private struct PersistedFile<Value: Codable & Equatable> {
    let url: URL
    let jsonc: Bool
    let render: (Value) throws -> Data
    private(set) var value: Value
    private(set) var failure: String?
    private var savedData: Data?

    init(url: URL, defaults: Value, jsonc: Bool, render: @escaping (Value) throws -> Data) {
        self.url = url
        self.jsonc = jsonc
        self.render = render
        value = defaults
    }

    mutating func load() {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            value = try decode(data, defaults: value)
            savedData = data
        } catch {
            // 副标题与标题栏按钮同行: 只放短提示, 详情进日志.
            failure = "\(url.lastPathComponent) 解析失败, 本次不保存"
            NSLog("jj-calendar: \(url.path): \(error)")
        }
    }

    mutating func update(_ change: (inout Value) -> Void) {
        change(&value)
        guard failure == nil else { return }
        do {
            let data = try render(value)
            guard data != savedData else { return }
            try ConfigStore.write(data, to: url)
            savedData = data
        } catch {
            NSLog("jj-calendar: write \(url.path) failed: \(error)")
        }
    }

    /// 缺失键或 null 取默认值 (新增字段不破坏旧文件), 其余按类型解码; jsonc 按 JSON5 解析 (注释 + 尾逗号).
    private func decode(_ data: Data, defaults: Value) throws -> Value {
        let options: JSONSerialization.ReadingOptions = jsonc ? .json5Allowed : []
        guard let override = try JSONSerialization.jsonObject(with: data, options: options) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults))
        let merged = try JSONSerialization.data(withJSONObject: Self.merge(base, override))
        return try JSONDecoder().decode(Value.self, from: merged)
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
