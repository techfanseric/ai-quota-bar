import Foundation

/// API response model for MiniMax usage data
/// Endpoint: GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains
struct UsageData: Codable {
    /// Remaining tokens/credits
    let remains: Int
    /// Total allocated amount (for percentage calculation)
    let total: Int
    /// Timestamp of the response
    let timestamp: Date

    /// Percentage remaining (0-100)
    var percentageRemaining: Double {
        guard total > 0 else { return 0 }
        return (Double(remains) / Double(total)) * 100
    }

    /// Formatted remaining display string
    func formattedRemaining(format: DisplayFormat) -> String {
        switch format {
        case .numberOnly:
            return "\(Int(percentageRemaining))%"
        case .numberWithUnit:
            return "\(Int(percentageRemaining))% remaining"
        case .leveled:
            if percentageRemaining > 50 {
                return "\(Int(percentageRemaining))%"
            } else {
                let days = estimateDaysRemaining()
                return "[Warning] \(Int(percentageRemaining))% (~\(days) days)"
            }
        }
    }

    /// Estimate days until quota exhaustion (simplified)
    private func estimateDaysRemaining() -> Int {
        // Placeholder calculation based on typical usage
        // Real implementation would track usage trend over time
        return max(1, Int(Double(remains) / Double(total) * 30))
    }
}

/// Menu bar display format options
enum DisplayFormat: Int, CaseIterable, Codable {
    case numberOnly = 0
    case numberWithUnit = 1
    case leveled = 2

    var description: String {
        switch self {
        case .numberOnly: return "Number only (e.g., 85%)"
        case .numberWithUnit: return "Number with unit (e.g., 85% remaining)"
        case .leveled: return "Leveled (detailed when low)"
        }
    }
}

/// Error types for usage fetching
enum UsageError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case apiError(String)
    case keychainError
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .invalidResponse: return "Invalid response from server"
        case .apiError(let message): return "API error: \(message)"
        case .keychainError: return "Keychain access error"
        case .notConfigured: return "API key not configured"
        }
    }
}
