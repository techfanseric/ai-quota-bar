import CodexBarCore
import Foundation

final class KimiService {
    static let shared = KimiService()

    private let cliStatusProvider: any KimiCLIStatusProviding

    init(
        cliStatusProvider: any KimiCLIStatusProviding = KimiCLIStatusProbe()
    ) {
        self.cliStatusProvider = cliStatusProvider
    }

    var hasCLICredential: Bool {
        KimiSettingsReader.hasKimiCodeCredential()
    }

    func fetchUsage(apiKey: String?) async throws -> UsageData {
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAPIKey.isEmpty {
            return try await fetchAPIUsage(
                credential: trimmedAPIKey,
                source: "Kimi Code API")
        }

        do {
            guard KimiSettingsReader.hasKimiCodeCredential() else {
                throw UsageError.notConfigured
            }
            let snapshot = try await cliStatusProvider.fetchUsageSnapshot()
            return try KimiUsageDataMapper.map(
                snapshot,
                source: "Kimi Code CLI /status")
        } catch let error as UsageError {
            throw error
        } catch let error as URLError {
            throw UsageError.networkError(error)
        } catch let error as KimiAPIError {
            throw UsageError.apiError(error.localizedDescription)
        } catch is DecodingError {
            throw UsageError.invalidResponse
        } catch {
            throw UsageError.apiError(error.localizedDescription)
        }
    }

    private func fetchAPIUsage(
        credential: String,
        source: String
    ) async throws -> UsageData {
        do {
            let baseURL = try KimiSettingsReader.codeAPIBaseURL()
            let kimiSnapshot = try await KimiUsageFetcher.fetchCodeAPIUsage(
                apiKey: credential,
                baseURL: baseURL)
            return try KimiUsageDataMapper.map(
                kimiSnapshot.toUsageSnapshot(),
                source: source)
        } catch let error as UsageError {
            throw error
        } catch let error as URLError {
            throw UsageError.networkError(error)
        } catch let error as KimiAPIError {
            throw UsageError.apiError(error.localizedDescription)
        } catch is DecodingError {
            throw UsageError.invalidResponse
        } catch {
            throw UsageError.apiError(error.localizedDescription)
        }
    }

    func testConnection(apiKey: String?) async throws -> Bool {
        _ = try await fetchUsage(apiKey: apiKey)
        return true
    }
}
