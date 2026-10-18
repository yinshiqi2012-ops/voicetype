import Foundation

/// 输出字数的本地统计。
///
/// 设计取舍：
/// - **每日总量**（`daily`）永久保留，用来算历史累计、今天、最近 7/30 天。
/// - **逐条明细**（`entries`）只留最近 48 小时，用来算「最近一小时」「最近 24 小时」
///   这种滚动窗口 —— 按天存桶做不到跨天边界的精确回滚。
/// - 数据落在 `~/Library/Application Support/voicetype/usage.json`，纯本地、不联网。
@MainActor
final class UsageStats {
    struct Entry: Codable {
        var at: Date
        var chars: Int
    }

    struct Store: Codable {
        var daily: [String: Int] = [:]
        var entries: [Entry] = []
    }

    /// 明细保留时长。要覆盖「最近 24 小时」，留一倍余量更稳。
    static let entryRetention: TimeInterval = 48 * 60 * 60

    private let storeURL: URL
    private let now: () -> Date
    private let calendar: Calendar
    private var store: Store

    init(
        storeURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.storeURL = storeURL ?? Config.usageFileURL
        self.now = now
        self.calendar = calendar
        self.store = Self.load(from: storeURL ?? Config.usageFileURL)
    }

    // MARK: - 写入

    /// 记一笔输出。`chars` 是最终插入（或放进剪贴板）的字符数。
    func record(chars: Int) {
        guard chars > 0 else { return }
        let moment = now()
        store.daily[Self.dayKey(for: moment, calendar: calendar), default: 0] += chars
        store.entries.append(Entry(at: moment, chars: chars))
        prune()
        save()
    }

    /// 丢掉过期明细。注意这里**不**删"时间戳在未来"的条目：
    /// 系统时间被往回调时，那些条目其实是真的历史数据，删了就永久丢账；
    /// 让查询侧把它们排除在窗口外即可。
    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.entryRetention)
        store.entries.removeAll { $0.at < cutoff }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // 统计写失败不该干扰输入主流程，静默跳过。
            NSLog("[voicetype] usage save failed: \(error)")
        }
    }

    private static func load(from url: URL) -> Store {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(Store.self, from: data)
        else { return Store() }
        return store
    }

    // MARK: - 查询

    /// 历史累计字数。
    var totalChars: Int {
        store.daily.values.reduce(0, +)
    }

    /// 今天（自然日）字数。
    var todayChars: Int {
        store.daily[Self.dayKey(for: now(), calendar: calendar)] ?? 0
    }

    /// 滚动窗口字数，比如 `chars(inLast: 3600)` 是最近一小时。
    func chars(inLast seconds: TimeInterval) -> Int {
        let cutoff = now().addingTimeInterval(-seconds)
        return store.entries
            .filter { $0.at >= cutoff && $0.at <= now().addingTimeInterval(60) }
            .reduce(0) { $0 + $1.chars }
    }

    /// 最近 `days` 天的合计（按自然日，含今天）。明细只留 48 小时，
    /// 更长的窗口必须靠每日桶累加。
    func chars(lastDays days: Int) -> Int {
        dailyTotals(lastDays: days).reduce(0) { $0 + $1.chars }
    }

    /// 最近 `days` 天的每日字数，按日期升序，没有记录的日子补 0。
    func dailyTotals(lastDays days: Int) -> [(date: Date, chars: Int)] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now())
        return (0..<days).reversed().compactMap { offset -> (date: Date, chars: Int)? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, store.daily[Self.dayKey(for: day, calendar: calendar)] ?? 0)
        }
    }

    /// 最近 `hours` 小时的逐小时字数，按时间升序（用于菜单里的迷你分布）。
    func hourlyTotals(lastHours hours: Int) -> [(date: Date, chars: Int)] {
        guard hours > 0 else { return [] }
        let currentHour = calendar.dateInterval(of: .hour, for: now())?.start ?? now()
        return (0..<hours).reversed().compactMap { offset -> (date: Date, chars: Int)? in
            guard let start = calendar.date(byAdding: .hour, value: -offset, to: currentHour),
                  let end = calendar.date(byAdding: .hour, value: 1, to: start)
            else { return nil }
            let chars = store.entries
                .filter { $0.at >= start && $0.at < end }
                .reduce(0) { $0 + $1.chars }
            return (start, chars)
        }
    }

    // MARK: - 展示

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func dayLabel(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
    }

    /// 数字统一加千分位，中文场景下也读得顺。
    static func format(_ chars: Int) -> String {
        chars.formatted(.number.grouping(.automatic))
    }
}
