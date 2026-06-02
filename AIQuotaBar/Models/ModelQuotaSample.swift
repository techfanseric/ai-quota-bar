import Foundation

struct ModelQuotaSample: Codable, Identifiable, Equatable {
    let timestamp: Date
    let remaining: Int
    let percent: Int?

    var id: TimeInterval {
        timestamp.timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case remaining
        case percent
    }

    init(timestamp: Date, remaining: Int, percent: Int? = nil) {
        self.timestamp = timestamp
        self.remaining = remaining
        self.percent = percent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.remaining = try container.decode(Int.self, forKey: .remaining)
        self.percent = try container.decodeIfPresent(Int.self, forKey: .percent)
    }
}
