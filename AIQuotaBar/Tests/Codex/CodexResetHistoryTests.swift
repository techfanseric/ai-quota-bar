import XCTest
@testable import AIQuotaBar

@MainActor final class CodexResetHistoryTests: XCTestCase {
    private var calendar: Calendar {
        // UTC+7: late-evening announcements slip into the next local day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 25_200)!
        return calendar
    }

    func testDecodeMapsAnnouncedDatesToLocalDaysAndKeepsBankedFlag() throws {
        let data = Data("""
        {"data":[
          {"id":"1","reset_type":"regular","announced_at":"2026-09-08T01:56:57.501Z","text":"All reset for everyone.","source":{"type":"observed","url":"https://codex-resets.com"}},
          {"id":"2","reset_type":"banked","announced_at":"2026-09-03T23:12:09Z","text":"One banked reset.","source":{"type":"x_post","author":"thsottiaux","url":"https://x.com/p"}},
          {"id":"3","reset_type":"regular","announced_at":"not-a-date","text":"","source":{"type":"observed","url":"https://codex-resets.com"}}
        ]}
        """.utf8)
        let markers = try CodexResetHistory.decode(data, calendar: calendar)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].date, Date(timeIntervalSince1970: 1_788_800_400))
        XCTAssertEqual(markers[0].announcedAt.timeIntervalSince1970, 1_788_832_617.501, accuracy: 0.01)
        XCTAssertEqual(markers[0].banked, false)
        XCTAssertEqual(markers[1].date, Date(timeIntervalSince1970: 1_788_454_800))
        XCTAssertEqual(markers[1].announcedAt.timeIntervalSince1970, 1_788_477_129, accuracy: 0.01)
        XCTAssertEqual(markers[1].banked, true)
    }

    func testLatestPicksTheFirstResetListedForTheDay() {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_789_505_417))
        let morning = CodexResetMarker(date: day, announcedAt: day.addingTimeInterval(3600), banked: true)
        let evening = CodexResetMarker(date: day, announcedAt: day.addingTimeInterval(7200), banked: false)
        let other = CodexResetMarker(date: day.addingTimeInterval(86400), announcedAt: day.addingTimeInterval(86400), banked: false)
        XCTAssertEqual(CodexResetHistory.latest([other, evening, morning], on: day, calendar: calendar), evening)
        XCTAssertNil(CodexResetHistory.latest([other], on: day, calendar: calendar))
    }
}
