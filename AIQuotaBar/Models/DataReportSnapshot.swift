import Foundation

struct DataReportSnapshot: Codable {
    let generatedAt: Date
    let usageData: UsageData?
    let providerUsageData: [UsageProvider: UsageData]
    let modelQuotaSamples: [String: [ModelQuotaSample]]
    let utilizationHistories: [UsageProvider: ModelUtilizationStoreData]
}
