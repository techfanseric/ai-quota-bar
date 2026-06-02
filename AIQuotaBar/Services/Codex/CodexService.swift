import CodexBarCore
import Foundation

/// 适配层入口：把 codexbar 的 ProviderFetchResult 转换为 ai-quota-bar 的 UsageData
final class CodexService {
    static let shared = CodexService()

    private let descriptor: ProviderDescriptor
    private let fetcher: UsageFetcher
    private let browserDetection: BrowserDetection

    private init() {
        self.descriptor = CodexProviderDescriptor.descriptor
        self.fetcher = UsageFetcher()
        self.browserDetection = BrowserDetection()
    }

    /// 当前 source mode（持久化在 UserDefaults）
    var sourceMode: CodexDataSourceMode {
        get {
            guard
                let raw = UserDefaults.standard.string(forKey: CodexDataSourceMode.storageKey),
                let mode = CodexDataSourceMode(rawValue: raw)
            else {
                return .default
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: CodexDataSourceMode.storageKey)
        }
    }

    /// 拉取当前 source mode 下的 Codex usage
    func fetchUsage() async throws -> UsageData {
        let context = makeContext(sourceMode: sourceMode)
        do {
            let result = try await descriptor.fetch(context: context)
            return CodexUsageDataMapper.mapToUsageData(
                snapshot: result.usage,
                credits: result.credits,
                sourceLabel: result.sourceLabel)
        } catch let error as CodexOAuthFetchError {
            throw mapCodexError(error)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.networkError(error)
        }
    }

    /// 测试当前 source mode 是否能拉到数据
    func testConnection() async throws -> Bool {
        _ = try await fetchUsage()
        return true
    }

    private func makeContext(sourceMode: CodexDataSourceMode) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode.codexbarSourceMode,
            includeCredits: true,
            includeOptionalUsage: true,
            webTimeout: 30,
            webDebugDumpHTML: false,
            verbose: false,
            env: ProcessInfo.processInfo.environment,
            settings: nil,
            fetcher: fetcher,
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func mapCodexError(_ error: CodexOAuthFetchError) -> UsageError {
        switch error {
        case .unauthorized:
            return .apiError("Codex token expired — run `codex` to refresh")
        case .invalidResponse:
            return .invalidResponse
        case let .serverError(code, _):
            return .apiError("Codex API error \(code)")
        case let .networkError(inner):
            return .networkError(inner)
        }
    }
}
