import AppKit

/// 界面状态: 启动时读取, 随界面操作写入; 外部修改需重启.
struct AppState: Codable, Equatable {
    /// 时长 (月数); 起始月不持久化, 每次启动为本月.
    var months = 3
    /// RowSpan.rawValue.
    var rowSpan = 0
    var fontSize = 10.0
    var ignoreMonthTint = false
    var hiddenCalendarIDs: [String] = []
    /// 不参与批量显示 / 隐藏, 事件淡化.
    var ignoredCalendarIDs: [String] = []
    var window: WindowFrame?
}

struct WindowFrame: Codable, Equatable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
}

/// 外观设置: 只读, 手工编辑 config.jsonc 后重启生效. 颜色为 hex (#RRGGBB / #RRGGBBAA), 空值 = 系统色.
struct AppConfig: Codable, Equatable {
    var appearance = Appearance()
    var layout = Layout()

    struct Appearance: Codable, Equatable {
        var monthTintColor = ""
        var monthTintOpacity = 0.025
        var todayColor = ""
        var weekendColor = ""
        var moreColor = ""
        var barOpacityLight = 0.25
        var barOpacityDark = 0.4
        var pastOpacity = 0.6
        var ignoredOpacity = 0.3
    }

    struct Layout: Codable, Equatable {
        var minLinesBeforeScroll = 3
    }

    /// 启动时读取一次; 首次访问触发.
    @MainActor static let current: AppConfig = {
        let (config, warning) = ConfigStore.loadConfig()
        ConfigStore.configWarning = warning
        return config
    }()

    /// 越界数值收敛; 非法颜色清空 (取系统色) 并返回出错键.
    func normalized() -> (AppConfig, [String]) {
        var result = self
        var invalid: [String] = []
        func clamp(_ value: inout Double, _ range: ClosedRange<Double>) {
            value = min(max(value, range.lowerBound), range.upperBound)
        }
        clamp(&result.appearance.monthTintOpacity, 0...0.3)
        clamp(&result.appearance.barOpacityLight, 0...1)
        clamp(&result.appearance.barOpacityDark, 0...1)
        clamp(&result.appearance.pastOpacity, 0.1...1)
        clamp(&result.appearance.ignoredOpacity, 0.1...1)
        result.layout.minLinesBeforeScroll = min(max(layout.minLinesBeforeScroll, 1), 20)
        let colors: [(String, WritableKeyPath<Appearance, String>)] = [
            ("monthTintColor", \.monthTintColor), ("todayColor", \.todayColor),
            ("weekendColor", \.weekendColor), ("moreColor", \.moreColor)
        ]
        for (name, path) in colors {
            let value = appearance[keyPath: path]
            if !value.isEmpty, NSColor(hex: value) == nil {
                result.appearance[keyPath: path] = ""
                invalid.append("appearance.\(name)")
            }
        }
        return (result, invalid)
    }
}

extension NSColor {
    /// #RRGGBB / #RRGGBBAA; 其余返回 nil.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard [6, 8].contains(digits.count), let value = UInt64(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        func channel(_ shift: UInt64) -> CGFloat {
            CGFloat((rgba >> shift) & 0xFF) / 255
        }
        self.init(srgbRed: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }

    /// 配置色; 空值 = fallback.
    static func config(_ hex: String, fallback: NSColor) -> NSColor {
        hex.isEmpty ? fallback : NSColor(hex: hex) ?? fallback
    }
}

/// `~/.config/jj-calendar/`; Debug 构建使用产物旁的独立目录, 调试不影响日常数据.
/// - `config.jsonc`: 外观设置, 手工编辑, 带注释.
/// - `config.default.jsonc`: 全部键默认值, 每次启动刷新, 仅供查阅.
/// - `state.json`: 界面状态, App 写入.
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
    static let configURL = directory.appendingPathComponent("config.jsonc")
    static let defaultsURL = directory.appendingPathComponent("config.default.jsonc")

    private(set) static var state = AppState()
    /// 解析失败时停写, 保留原文件待人工修正.
    private(set) static var failure: String?
    fileprivate(set) static var configWarning: String?
    private static var savedData: Data?

    /// 窗口副标题提示: 配置 / 状态文件问题.
    static var warnings: String {
        [configWarning, failure].compactMap(\.self).joined(separator: "; ")
    }

    static func load() {
        do {
            guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
            let data = try Data(contentsOf: stateURL)
            state = try decode(data, defaults: AppState())
            savedData = data
        } catch {
            // 副标题与标题栏按钮同行: 只放短提示, 详情进日志.
            failure = "state.json 解析失败, 本次不保存设置"
            NSLog("jj-calendar: \(stateURL.path): \(error)")
        }
    }

    static func update(_ change: (inout AppState) -> Void) {
        change(&state)
        guard failure == nil else { return }
        do {
            let data = try encode(state)
            guard data != savedData else { return }
            try write(data, to: stateURL)
            savedData = data
        } catch {
            NSLog("jj-calendar: write \(stateURL.path) failed: \(error)")
        }
    }

    /// 刷新默认模板; 无 config.jsonc 时以模板新建; 解析失败使用默认值.
    fileprivate static func loadConfig() -> (AppConfig, String?) {
        do {
            let template = try encodeConfig(AppConfig())
            if (try? Data(contentsOf: defaultsURL)) != template {
                try write(template, to: defaultsURL)
            }
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                try write(template, to: configURL)
                return (AppConfig(), nil)
            }
            let (config, invalid) = try decode(Data(contentsOf: configURL), defaults: AppConfig(), jsonc: true)
                .normalized()
            let warning = invalid.isEmpty ? nil : "config.jsonc 颜色无效: \(invalid.joined(separator: ", "))"
            return (config, warning)
        } catch {
            NSLog("jj-calendar: \(configURL.path): \(error)")
            return (AppConfig(), "config.jsonc 解析失败, 已用默认外观")
        }
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
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
        return Data(("// 修改后重启生效; 缺失键 / null 取默认值, 越界数值收敛.\n" + lines.joined(separator: "\n")).utf8)
    }

    private static let configNotes: [String: String] = [
        "appearance": "颜色 hex: #RRGGBB / #RRGGBBAA; 空值 = 系统色 (随深浅色切换)",
        "monthTintColor": "隔月日期格背景叠加色; 空值 = 系统文字色.",
        "monthTintOpacity": "隔月背景叠加强度, 0–0.3; 0 关闭. 标题栏「忽略背景色」可临时关闭.",
        "todayColor": "今天日期标记底色; 空值 = 系统红.",
        "weekendColor": "周末星期文字色; 空值 = 系统红.",
        "moreColor": "折叠数 +N 文字色; 空值 = 系统橙.",
        "barOpacityLight": "全天 / 跨天横条底色不透明度 (浅色模式), 0–1.",
        "barOpacityDark": "全天 / 跨天横条底色不透明度 (深色模式), 0–1.",
        "pastOpacity": "已结束日程不透明度, 0.1–1.",
        "ignoredOpacity": "已忽略日历的日程不透明度, 0.1–1.",
        "layout": "排版",
        "minLinesBeforeScroll": "铺满窗口时每行至少展示的日程行数, 1–20; 放不下改为纵向滚动."
    ]

    /// 以默认值为底合并文件内容: 缺失键或 null 取默认值 (新增字段不破坏旧文件), 其余按类型解码.
    /// jsonc: JSON5 解析, 支持 `//` / `/* */` 注释 + 尾逗号.
    private static func decode<T: Codable>(_ data: Data, defaults: T, jsonc: Bool = false) throws -> T {
        let options: JSONSerialization.ReadingOptions = jsonc ? .json5Allowed : []
        guard let override = try JSONSerialization.jsonObject(with: data, options: options) as? [String: Any] else {
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
