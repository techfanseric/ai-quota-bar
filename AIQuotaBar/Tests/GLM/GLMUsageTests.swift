import XCTest
@testable import AIQuotaBar

final class GLMUsageTests: XCTestCase {
    func testCurrentCreditResponseKeepsWindowsDistinctAndUsesServerRemaining() throws {
        // Shape observed in the personal usage dashboard on 2026-09-11.
        // The server rounds currentValue and remaining independently.
        let data = Data(#"{"code":200,"success":true,"data":{"level":"lite","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":0,"remaining":2000,"percentage":0},{"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":514,"remaining":9485,"percentage":5,"nextResetTime":1789647732997}]}}"#.utf8)
        let result = try UsageService.shared.decodeGLMUsageData(from: data)
        XCTAssertEqual(result.provider, .glm)
        XCTAssertEqual(result.subscribeTitle, "lite")
        XCTAssertEqual(result.models.map(\.modelName), ["GLM Credits (5h)", "GLM Credits (weekly)"])
        XCTAssertEqual(Set(result.models.map(\.id)).count, 2)
        XCTAssertEqual(result.models.map(\.currentIntervalRemaining), [2000, 9485])
        XCTAssertEqual(result.models.map(\.currentIntervalTotal), [2000, 10000])
        XCTAssertNil(result.models[0].endTime)
        XCTAssertNil(result.models[0].startTime)
        let weekly = result.models[1]
        XCTAssertEqual(weekly.endTime!.timeIntervalSince1970, 1789647732.997, accuracy: 0.001)
        XCTAssertEqual(weekly.endTime!.timeIntervalSince(weekly.startTime!), 7 * 24 * 3600)
    }

    func testLegacyPercentageOnlyAndMonthlyMCP() throws {
        let data = Data(#"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":"12.5","nextResetTime":1800000000000},{"type":"TIME_LIMIT","usage":"1000","currentValue":"25"}]}}"#.utf8)
        let reset = Date(timeIntervalSince1970: 1800000000)
        let result = try UsageService.shared.decodeGLMUsageData(from: data, subscriptionResetTime: reset)
        XCTAssertEqual(result.models[0].currentIntervalRemaining, 87)
        XCTAssertEqual(result.models[0].valueSuffix, "%")
        XCTAssertEqual(result.models[0].startTime, reset.addingTimeInterval(-5 * 3600))
        XCTAssertEqual(result.models[1].currentIntervalRemaining, 975)
        XCTAssertEqual(result.models[1].endTime, reset)
        XCTAssertNil(result.models[1].startTime)
    }

    func testInvalidAndEmptyQuotaDoesNotReportConnectionSuccess() {
        for json in [
            #"{"code":401,"success":false,"msg":"expired"}"#,
            #"{"code":200,"success":true,"data":{"limits":[]}}"#,
            #"{"code":200,"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT"}]}}"#
        ] {
            XCTAssertThrowsError(try UsageService.shared.decodeGLMUsageData(from: Data(json.utf8)))
        }
    }

    func testOutOfRangeRemainingIsClamped() throws {
        let data = Data(#"{"code":200,"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":100,"currentValue":120,"remaining":-20}]}}"#.utf8)
        let model = try XCTUnwrap(UsageService.shared.decodeGLMUsageData(from: data).models.first)
        XCTAssertEqual(model.currentIntervalRemaining, 0)
    }

    func testAPIKeyUsesOpenAPIAndBearerExactlyOnce() throws {
        for input in ["test-api-key", "Bearer test-api-key"] {
            let credential = try GLMCredential.parse(input)
            XCTAssertEqual(credential.apiURL, "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
            XCTAssertEqual(credential.authorization, "Bearer test-api-key")
            let restored = try GLMCredential.parse(credential.storageString)
            XCTAssertEqual(restored.apiURL, credential.apiURL)
            XCTAssertEqual(restored.authorization, credential.authorization)
        }
    }

    func testWebCurlPreservesAuthenticationAndLegacyStoredCredential() throws {
        let curl = #"curl 'https://bigmodel.cn/api/monitor/usage/quota/limit' -H 'authorization: web-session' -H 'bigmodel-organization: org' -H 'bigmodel-project: project' -b 'session=value'"#
        let credential = try GLMCredential.parse(curl)
        XCTAssertEqual(credential.apiURL, GLMCredential.defaultAPIURL)
        XCTAssertEqual(credential.authorization, "web-session")
        XCTAssertEqual(credential.organization, "org")
        XCTAssertEqual(credential.project, "project")
        XCTAssertEqual(credential.cookie, "session=value")
        let restored = try GLMCredential.parse(credential.storageString)
        XCTAssertEqual(restored.headers, credential.headers)
        XCTAssertEqual(restored.authorization, "web-session")
        XCTAssertThrowsError(try GLMCredential.parse("curl 'https://bigmodel.cn/api/monitor/usage/quota/limit'"))
    }

    func testEditableCredentialRoundTripPreservesWebContext() throws {
        let web = GLMCredential(
            apiURL: GLMCredential.defaultAPIURL,
            authorization: "test'web-token", organization: "org", project: "project",
            cookie: "session=a'b", headers: ["accept": "application/json"])
        let parsed = try GLMCredential.parse(web.editableString)
        XCTAssertEqual(parsed.authorization, web.authorization)
        XCTAssertEqual(parsed.cookie, web.cookie)
        XCTAssertEqual(parsed.organization, web.organization)
        XCTAssertEqual(parsed.project, web.project)
        XCTAssertEqual(parsed.headers["accept"], "application/json")
        XCTAssertEqual(try GLMCredential.parse("test-key").editableString, "test-key")
    }

    func testProviderIsAvailableForConfigurationAndDiscovery() {
        XCTAssertTrue(UsageProvider.allCases.contains(.glm))
        XCTAssertTrue(UsageProvider.glm.usesCurlCredential)
        XCTAssertEqual(UsageProvider.glm.keychainAccount, "glmCredential")
    }
}
