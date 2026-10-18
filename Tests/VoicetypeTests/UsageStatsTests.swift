import Foundation
import Testing
@testable import Voicetype

@MainActor
struct UsageStatsTests {
    /// 固定时钟 + 临时文件，避免测试互相踩数据。
    private func makeStats(
        now: @escaping () -> Date,
        file: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetype-usage-\(UUID().uuidString).json")
    ) -> UsageStats {
        UsageStats(storeURL: file, now: now)
    }

    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func accumulatesTotalAndToday() {
        let stats = makeStats(now: { self.base })
        stats.record(chars: 10)
        stats.record(chars: 32)
        #expect(stats.totalChars == 42)
        #expect(stats.todayChars == 42)
    }

    @Test func rollingWindowsUsePerEntryTimestamps() {
        var clock = base
        let stats = makeStats(now: { clock })
        stats.record(chars: 5)                 // 此刻
        clock = base.addingTimeInterval(-2 * 3600)
        stats.record(chars: 7)                 // 2 小时前
        clock = base.addingTimeInterval(-30 * 3600)
        stats.record(chars: 9)                 // 30 小时前
        clock = base

        #expect(stats.chars(inLast: 3600) == 5)
        #expect(stats.chars(inLast: 24 * 3600) == 12)
        #expect(stats.chars(inLast: 48 * 3600) == 21)
    }

    @Test func longWindowsComeFromDailyBuckets() {
        var clock = base
        let stats = makeStats(now: { clock })
        for daysAgo in 0..<40 {
            clock = base.addingTimeInterval(-Double(daysAgo) * 24 * 3600)
            stats.record(chars: 100)
        }
        clock = base
        // 每日桶永久保留，明细只有 48 小时，长窗口必须依然算得出来。
        #expect(stats.totalChars == 4000)
        #expect(stats.chars(lastDays: 7) == 700)
        #expect(stats.chars(lastDays: 30) == 3000)
    }

    @Test func dailyTotalsFillMissingDaysWithZero() {
        var clock = base
        let stats = makeStats(now: { clock })
        stats.record(chars: 33)
        clock = base.addingTimeInterval(-2 * 24 * 3600)
        stats.record(chars: 11)
        clock = base

        let rows = stats.dailyTotals(lastDays: 3)
        #expect(rows.count == 3)
        #expect(rows.map(\.chars) == [11, 0, 33])  // 升序，中间那天补 0
    }

    @Test func persistsAcrossInstances() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetype-usage-\(UUID().uuidString).json")
        let first = makeStats(now: { self.base }, file: file)
        first.record(chars: 64)

        let second = makeStats(now: { self.base }, file: file)
        #expect(second.totalChars == 64)
        #expect(second.todayChars == 64)
        try? FileManager.default.removeItem(at: file)
    }

    @Test func prunesStaleEntriesButKeepsDailyTotals() {
        var clock = base
        let stats = makeStats(now: { clock })
        clock = base.addingTimeInterval(-72 * 3600)
        stats.record(chars: 20)          // 72 小时前，明细会被裁掉
        clock = base
        stats.record(chars: 1)           // 触发一次写入与裁剪

        #expect(stats.chars(inLast: 96 * 3600) == 1)  // 明细里只剩新的
        #expect(stats.totalChars == 21)               // 每日桶仍保留旧数据
    }

    @Test func ignoresNonPositiveInput() {
        let stats = makeStats(now: { self.base })
        stats.record(chars: 0)
        stats.record(chars: -5)
        #expect(stats.totalChars == 0)
    }
}
