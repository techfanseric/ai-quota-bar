import XCTest
@testable import AIQuotaBar

/// `updatedAgoText` 的分档是这个函数存在的全部理由，所以逐档钉住边界值：
/// 分钟的上界、小时的下界、小时的上界各测一次。这些边界一旦悄悄挪了
/// （比如 60 分钟显示成 "60m ago" 而不是 "1h ago"），UI 上看不出问题，
/// 但读者读到的量级就错了。
final class UpdatedAgoTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testUnderAMinuteReadsAsJustNow() {
        XCTAssertEqual(
            AppLanguage.english.updatedAgoText(from: now.addingTimeInterval(-59), now: now),
            "Updated just now")
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.updatedAgoText(from: now.addingTimeInterval(-59), now: now),
            "刚刚更新")
    }

    func testMinutesCoverOneThroughFiftyNine() {
        XCTAssertEqual(
            AppLanguage.english.updatedAgoText(from: now.addingTimeInterval(-60), now: now),
            "Updated 1m ago")
        XCTAssertEqual(
            AppLanguage.english.updatedAgoText(from: now.addingTimeInterval(-59 * 60), now: now),
            "Updated 59m ago")
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.updatedAgoText(from: now.addingTimeInterval(-59 * 60), now: now),
            "59 分钟前更新")
    }

    /// 60 分钟必须换挡成小时。停在分钟上会得到 "60m ago"，再往上就是
    /// "888m ago" 这种读者得自己换算的数。
    func testSixtyMinutesReadsAsHours() {
        XCTAssertEqual(
            AppLanguage.english.updatedAgoText(from: now.addingTimeInterval(-60 * 60), now: now),
            "Updated 1h ago")
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.updatedAgoText(from: now.addingTimeInterval(-60 * 60), now: now),
            "1 小时前更新")
        XCTAssertEqual(
            AppLanguage.english.updatedAgoText(from: now.addingTimeInterval(-23 * 3600), now: now),
            "Updated 23h ago")
    }

    /// 满 24 小时改说日期+时刻：这时候"多久之前"已经不是主要信息了。
    func testTwentyFourHoursSwitchesToDateAndTime() {
        let sample = now.addingTimeInterval(-26 * 3600)
        for language in [AppLanguage.english, .simplifiedChinese] {
            let text = language.updatedAgoText(from: sample, now: now)
            XCTAssertFalse(
                text.contains("h ago") || text.contains("小时前"),
                "超过一天不该再说小时：\(text)")
            XCTAssertTrue(
                text.contains(hourStamp(of: sample)),
                "应该给出当天时刻：\(text)")
        }
    }

    /// 超过一天的档位要带日期，否则"上午 9 点"到底是哪一天仍然说不清。
    func testDateTierCarriesTheDayAsWellAsTheTime() {
        let sample = now.addingTimeInterval(-40 * 24 * 3600)
        for language in [AppLanguage.english, .simplifiedChinese] {
            let text = language.updatedAgoText(from: sample, now: now)
            XCTAssertTrue(
                text.contains(dayStamp(of: sample, language: language)),
                "应该给出日期：\(text)")
            XCTAssertTrue(
                text.contains(hourStamp(of: sample)),
                "应该给出时刻：\(text)")
        }
    }

    /// 采样时间偶尔会比读取时钟晚一点点（云端上报的墙钟、系统时间回拨）。
    /// 负值不能被 floor 成 "-1 分钟前"或 "-3 小时前"。
    func testFutureTimestampDoesNotProduceNegativeAges() {
        for language in [AppLanguage.english, .simplifiedChinese] {
            XCTAssertEqual(
                language.updatedAgoText(from: now.addingTimeInterval(120), now: now),
                language == .english ? "Updated just now" : "刚刚更新")
        }
    }

    /// 用和实现同样的规则独立算一遍期望值，避免测试只是把实现抄了一遍 ——
    /// 真正的风险在格式串和边界，换个算法重算才能盯住"60 分钟是 1h 不是 0h"
    /// 这类换算错误。
    private func hourStamp(of date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let hour = String(format: "%02d", calendar.component(.hour, from: date))
        let minute = String(format: "%02d", calendar.component(.minute, from: date))
        return "\(hour):\(minute)"
    }

    private func dayStamp(of date: Date, language: AppLanguage) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        switch language {
        case .english:
            // 月份名必须按 en_US_POSIX 取，和实现一样写死：实现不跟系统语言跑，
            // 这里若跟着系统语言走，在中文系统上就会拿"10月"去比"Oct"，测的
            // 就不是同一个契约了。
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return "\(formatter.shortMonthSymbols?[month - 1] ?? "?") \(day)"
        case .simplifiedChinese:
            return "\(month)月\(day)日"
        }
    }
}