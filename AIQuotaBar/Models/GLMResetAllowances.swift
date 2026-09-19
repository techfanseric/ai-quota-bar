import Foundation

/// Read-only personal Coding Plan reset entitlements. These are not quota credits.
struct GLMResetAllowances: Codable {
    let fiveHourExpirations: [Date]
    let weeklyExpirations: [Date]

    func availableFiveHour(at now: Date = Date()) -> [Date] {
        fiveHourExpirations.filter { $0 > now }.sorted()
    }

    func availableWeekly(at now: Date = Date()) -> [Date] {
        weeklyExpirations.filter { $0 > now }.sorted()
    }

    static func decode(_ data: Data) throws -> Self {
        struct Item: Decodable { let available: Bool; let expireTime: String }
        struct Payload: Decodable {
            let targetType: String
            let fiveHourResets: [Item]
            let weekResets: [Item]
        }
        struct Envelope: Decodable { let code: Int; let success: Bool; let data: Payload? }
        let response = try JSONDecoder().decode(Envelope.self, from: data)
        guard response.code == 200, response.success,
              let payload = response.data, payload.targetType == "PERSONAL" else {
            throw UsageError.invalidResponse
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        func dates(_ items: [Item]) throws -> [Date] {
            try items.filter(\.available).map {
                guard let date = formatter.date(from: $0.expireTime),
                      formatter.string(from: date) == $0.expireTime else { throw UsageError.invalidResponse }
                return date
            }.sorted()
        }
        return try Self(fiveHourExpirations: dates(payload.fiveHourResets), weeklyExpirations: dates(payload.weekResets))
    }

    /// Only the verified CN web endpoint and personal scope can share these credentials.
    static func request(for credential: GLMCredential) -> URLRequest? {
        guard let source = URLComponents(string: credential.apiURL), source.scheme == "https",
              source.host == "bigmodel.cn", source.port == nil,
              source.path == "/api/monitor/usage/quota/limit",
              !(source.queryItems ?? []).contains(where: { $0.name == "type" && $0.value != "1" }),
              (credential.organization ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (credential.project ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credential.headers.contains(where: {
                  ["bigmodel-organization", "bigmodel-project"].contains($0.key.lowercased()) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return nil }
        var request = URLRequest(url: URL(string: "https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.httpShouldHandleCookies = false
        request.setValue(credential.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
