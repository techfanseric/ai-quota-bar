import XCTest
@testable import AIQuotaBar

final class GLMResetAllowanceTests: XCTestCase {
    func testAvailableFlagsExpiryAndPersonalScopeAreAuthoritative() throws {
        let fixture = Data(#"{"code":200,"success":true,"data":{"targetType":"PERSONAL","fiveHourResets":[{"available":false,"expireTime":"2026-09-17 20:04:30"},{"available":true,"expireTime":"2026-10-18 18:48:45"}],"weekResets":[{"available":true,"expireTime":"2026-10-18 17:48:12"}]}}"#.utf8)
        let allowances = try GLMResetAllowances.decode(fixture)
        let now = ISO8601DateFormatter().date(from: "2026-09-20T00:00:00Z")!
        XCTAssertEqual(allowances.availableFiveHour(at: now).count, 1)
        XCTAssertEqual(allowances.availableWeekly(at: now).count, 1)
        XCTAssertEqual(allowances.weeklyExpirations.first, ISO8601DateFormatter().date(from: "2026-10-18T09:48:12Z"))
        XCTAssertTrue(allowances.availableWeekly(at: allowances.weeklyExpirations[0]).isEmpty)
        XCTAssertThrowsError(try GLMResetAllowances.decode(Data(String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "PERSONAL", with: "TEAM").utf8)))
        for invalid in [#"{"code":401,"success":false}"#, #"{"code":200,"success":true,"data":{"targetType":"PERSONAL"}}"#] {
            XCTAssertThrowsError(try GLMResetAllowances.decode(Data(invalid.utf8)))
        }
    }

    func testRequestDoesNotSendCredentialsToUnverifiedHostsOrScopes() {
        func credential(_ url: String, organization: String? = nil) -> GLMCredential {
            GLMCredential(apiURL: url, authorization: "fixture-auth", organization: organization,
                          project: nil, cookie: "must-not-be-sent", headers: [:])
        }
        let valid = credential(GLMCredential.defaultAPIURL)
        let request = GLMResetAllowances.request(for: valid)
        XCTAssertEqual(request?.url?.absoluteString, "https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL")
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.timeoutInterval, 2)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "fixture-auth")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request?.httpShouldHandleCookies, false)
        for url in [GLMCredential.apiKeyURL, "https://proxy.example/api/monitor/usage/quota/limit", "http://bigmodel.cn/api/monitor/usage/quota/limit", GLMCredential.defaultAPIURL + "?type=2"] {
            XCTAssertNil(GLMResetAllowances.request(for: credential(url)))
        }
        XCTAssertNil(GLMResetAllowances.request(for: credential(GLMCredential.defaultAPIURL, organization: "team")))
    }

    func testGroupingPreservesAllowancesWithoutChangingQuota() throws {
        let data = Data(#"{"code":200,"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":0,"remaining":12000}]}}"#.utf8)
        var quota = try UsageService.shared.decodeGLMUsageData(from: data)
        quota.glmResetAllowances = GLMResetAllowances(fiveHourExpirations: [.distantFuture], weeklyExpirations: [])
        let grouped = quota.withModels(quota.models)
        XCTAssertEqual(grouped.glmResetAllowances?.availableFiveHour().count, 1)
        XCTAssertEqual(grouped.models[0].currentIntervalRemaining, 12000)
        let restored = try JSONDecoder().decode(UsageData.self, from: JSONEncoder().encode(grouped))
        XCTAssertEqual(restored.glmResetAllowances?.availableFiveHour().count, 1)
    }
}
