import Foundation
import Observation

struct CodexResetMarker: Equatable {
    /// Local start of day, for matching grid cells.
    let date: Date
    /// Exact announcement time, shown in the callout.
    let announcedAt: Date
    let banked: Bool
}

/// Public reset history from codex-resets.com (keyless, read-only), drawn as
/// frames on the usage month matrix. Fetch-only enrichment: failures leave the
/// matrix complete and retry on the next appearance. Nothing is uploaded and
/// no usage data is shared by requesting it.
@MainActor @Observable
final class CodexResetHistory {
    static let shared = CodexResetHistory()
    static let successInterval: TimeInterval = 6 * 3600
    static let failureInterval: TimeInterval = 10 * 60

    private(set) var markers: [CodexResetMarker] = []
    private var nextAttempt = Date.distantPast
    private var task: Task<Void, Never>?
    private let session: URLSession
    private let source: URL

    init(session: URLSession = .shared,
         source: URL = URL(string: "https://codex-resets.com/api/v1/resets?limit=100")!) {
        self.session = session
        self.source = source
    }

    func marker(day: Date, calendar: Calendar = .current) -> CodexResetMarker? {
        Self.latest(markers, on: day, calendar: calendar)
    }

    func refreshIfNeeded(now: Date = .now) {
        guard task == nil, now >= nextAttempt else { return }
        task = Task { [weak self] in
            await self?.refresh(now: now)
        }
    }

    private func refresh(now: Date) async {
        defer { task = nil }
        do {
            var request = URLRequest(url: source)
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("AIQuotaBar", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            markers = try Self.decode(data)
            nextAttempt = now.addingTimeInterval(Self.successInterval)
        } catch {
            nextAttempt = now.addingTimeInterval(Self.failureInterval)
        }
    }

    /// The source lists newest first, so the first hit is the latest that day.
    static func latest(_ markers: [CodexResetMarker], on day: Date, calendar: Calendar) -> CodexResetMarker? {
        markers.first { calendar.isDate($0.date, inSameDayAs: day) }
    }

    static func decode(_ data: Data, calendar: Calendar = .current) throws -> [CodexResetMarker] {
        struct Payload: Decodable { let data: [Reset] }
        struct Reset: Decodable {
            let announcedAt: String
            let resetType: String
            enum CodingKeys: String, CodingKey {
                case announcedAt = "announced_at"
                case resetType = "reset_type"
            }
        }
        // announced_at carries fractional seconds for observed resets only.
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONDecoder().decode(Payload.self, from: data).data.compactMap { reset in
            guard let date = fractional.date(from: reset.announcedAt) ?? plain.date(from: reset.announcedAt) else {
                return nil
            }
            return CodexResetMarker(date: calendar.startOfDay(for: date), announcedAt: date, banked: reset.resetType == "banked")
        }
    }
}
