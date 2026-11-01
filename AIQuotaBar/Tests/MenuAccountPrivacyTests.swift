import XCTest
@testable import AIQuotaBar

final class MenuAccountPrivacyTests: XCTestCase {
    func testMasksEmailLocalPartAndPreservesDomain() {
        XCTAssertEqual(MenuAccountPrivacy.display("abcdefg@example.com", masked: true), "a****g@example.com")
        XCTAssertEqual(MenuAccountPrivacy.display("first.last+work@example.co.uk", masked: true), "f****k@example.co.uk")
    }

    func testShortAndUnicodeNamesDoNotExposeWholeIdentity() {
        for (raw, expected) in [("", ""), ("a", "****"), ("ab", "a****"),
                                ("abc", "a****c"), ("张三李四", "张****四"),
                                ("👩‍💻工作👨‍💻", "👩‍💻****👨‍💻"), ("a@example.com", "****@example.com")] {
            XCTAssertEqual(MenuAccountPrivacy.display(raw, masked: true), expected)
        }
    }

    func testDisabledModePreservesOriginalText() {
        let original = "Account abcdefg@example.com / 张三李四"
        XCTAssertEqual(MenuAccountPrivacy.display(original, masked: false), original)
        XCTAssertEqual(MenuAccountPrivacy.redactEmails(in: original, masked: false), original)
    }

    func testRedactsMultipleEmailsInDiagnosticText() {
        XCTAssertEqual(
            MenuAccountPrivacy.redactEmails(in: "From <abcdefg@example.com> to 'xy@test.org'", masked: true),
            "From <a****g@example.com> to 'x****@test.org'")
    }

    func testPreferenceDefaultsOffAndPersists() throws {
        let suite = "MenuAccountPrivacyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: MenuAccountPrivacy.storageKey))
        defaults.set(true, forKey: MenuAccountPrivacy.storageKey)
        XCTAssertTrue(try XCTUnwrap(UserDefaults(suiteName: suite)).bool(forKey: MenuAccountPrivacy.storageKey))
    }
}
