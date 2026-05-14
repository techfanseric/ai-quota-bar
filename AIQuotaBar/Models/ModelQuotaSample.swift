import Foundation

struct ModelQuotaSample: Codable, Identifiable, Equatable {
    let timestamp: Date
    let remaining: Int

    var id: TimeInterval {
        timestamp.timeIntervalSince1970
    }
}
