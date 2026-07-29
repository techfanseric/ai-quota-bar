import Darwin
import Foundation

enum CodexHookInstallationStatus: Equatable {
    case notChecked
    case installed
    case helperMissing
    case failed(String)
}

struct CodexHookInstaller {
    static let supportedEvents = CodexHookEventName.allCases

    let hooksURL: URL
    let helperURL: URL
    let fileManager: FileManager

    init(
        hooksURL: URL = CodexHookInstaller.defaultHooksURL(),
        helperURL: URL = CodexHookInstaller.defaultHelperURL(),
        fileManager: FileManager = .default
    ) {
        self.hooksURL = hooksURL
        self.helperURL = helperURL
        self.fileManager = fileManager
    }

    func install() -> CodexHookInstallationStatus {
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            return .helperMissing
        }

        do {
            try fileManager.createDirectory(
                at: hooksURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let existingData = try? Data(contentsOf: hooksURL)
            var root = try parseRoot(existingData)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            let command = shellQuoted(helperURL.path)

            for event in Self.supportedEvents {
                var groups = hooks[event.rawValue] as? [[String: Any]] ?? []
                groups.removeAll(where: ownsHookGroup)
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": command,
                        "timeout": 5
                    ]]
                ])
                hooks[event.rawValue] = groups
            }

            root["hooks"] = hooks
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )

            if data != existingData {
                try backupExistingConfigurationIfNeeded(existingData)
                try data.write(to: hooksURL, options: .atomic)
                _ = chmod(hooksURL.path, S_IRUSR | S_IWUSR)
            }

            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private func backupExistingConfigurationIfNeeded(_ data: Data?) throws {
        guard let data, !data.isEmpty else { return }
        let backupURL = hooksURL.appendingPathExtension("ai-quota-bar.backup")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        try data.write(to: backupURL, options: .atomic)
        _ = chmod(backupURL.path, S_IRUSR | S_IWUSR)
    }

    private func ownsHookGroup(_ group: [String: Any]) -> Bool {
        guard let commands = group["hooks"] as? [[String: Any]] else { return false }
        return commands.contains { command in
            (command["command"] as? String)?.contains("/AIQuotaBarHook") == true
        }
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func defaultHooksURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let codexHome: URL
        if let configuredHome = environment["CODEX_HOME"], !configuredHome.isEmpty {
            codexHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
        } else {
            codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome.appendingPathComponent("hooks.json")
    }

    static func defaultHelperURL(
        bundle: Bundle = .main
    ) -> URL {
        if bundle.bundleURL.pathExtension == "app" {
            return bundle.bundleURL
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent("AIQuotaBarHook")
        }

        let executableDirectory = bundle.executableURL?
            .deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return executableDirectory.appendingPathComponent("AIQuotaBarHook")
    }
}
