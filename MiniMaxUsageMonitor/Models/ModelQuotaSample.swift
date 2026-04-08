import Foundation

struct ModelQuotaSample: Identifiable, Equatable {
    let timestamp: Date
    let remaining: Int

    var id: TimeInterval {
        timestamp.timeIntervalSince1970
    }
}
