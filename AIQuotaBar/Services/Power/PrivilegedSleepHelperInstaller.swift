import AIQuotaBarSleepShared
import CryptoKit
import Foundation

struct PrivilegedSleepHelperInstaller: Sendable {
    enum InstallationStatus: Equatable {
        case missing
        case outdated
        case installed
    }

    private let bundledHelperURL: URL
    private let legacyPlistURL: URL
    private let appExecutableURL: URL
    private let installedHelperURL: URL
    private let installedPlistURL: URL
    private let authorizedClientMarkerURL: URL

    init(bundle: Bundle = .main) {
        let contentsURL = bundle.bundleURL
            .appendingPathComponent(
                "Contents",
                isDirectory: true)
        bundledHelperURL = contentsURL
            .appendingPathComponent(
                "MacOS",
                isDirectory: true)
            .appendingPathComponent(
                SleepHelperConstants.helperExecutableName)
        legacyPlistURL = contentsURL
            .appendingPathComponent(
                "Resources",
                isDirectory: true)
            .appendingPathComponent(
                SleepHelperConstants.legacyPlistResourceName)
        appExecutableURL = bundle.executableURL
            ?? contentsURL
                .appendingPathComponent(
                    "MacOS",
                    isDirectory: true)
                .appendingPathComponent("AIQuotaBar")
        installedHelperURL = URL(
            fileURLWithPath:
                SleepHelperConstants.privilegedHelperPath)
        installedPlistURL = URL(
            fileURLWithPath:
                SleepHelperConstants.launchDaemonPath)
        authorizedClientMarkerURL = URL(
            fileURLWithPath:
                SleepHelperConstants.authorizedClientMarkerPath)
    }

    init(
        bundledHelperURL: URL,
        legacyPlistURL: URL,
        appExecutableURL: URL,
        installedHelperURL: URL,
        installedPlistURL: URL,
        authorizedClientMarkerURL: URL
    ) {
        self.bundledHelperURL = bundledHelperURL
        self.legacyPlistURL = legacyPlistURL
        self.appExecutableURL = appExecutableURL
        self.installedHelperURL = installedHelperURL
        self.installedPlistURL = installedPlistURL
        self.authorizedClientMarkerURL =
            authorizedClientMarkerURL
    }

    var hasBundledPayload: Bool {
        FileManager.default.isExecutableFile(
            atPath: bundledHelperURL.path)
            && FileManager.default.fileExists(
                atPath: legacyPlistURL.path)
    }

    func installationStatus() -> InstallationStatus {
        guard FileManager.default.isExecutableFile(
            atPath: installedHelperURL.path),
            FileManager.default.fileExists(
                atPath: installedPlistURL.path),
            FileManager.default.fileExists(
                atPath: authorizedClientMarkerURL.path) else {
            return .missing
        }

        guard fileDigest(installedHelperURL)
                == fileDigest(bundledHelperURL),
              let marker = try? String(
                contentsOf: authorizedClientMarkerURL,
                encoding: .utf8) else {
            return .outdated
        }

        let lines = marker
            .split(
                separator: "\n",
                omittingEmptySubsequences: true)
            .map(String.init)
        guard lines.count == 2,
              URL(fileURLWithPath: lines[0])
                .standardizedFileURL.path
                == appExecutableURL.standardizedFileURL.path,
              lines[1].lowercased()
                == fileDigest(appExecutableURL) else {
            return .outdated
        }
        return .installed
    }

    func install() throws {
        guard hasBundledPayload else {
            throw PrivilegedSleepHelperInstallerError
                .bundledPayloadMissing
        }

        let helperTarget = installedHelperURL.path
        let plistTarget = installedPlistURL.path
        let markerTarget = authorizedClientMarkerURL.path
        let markerTemporary = "\(markerTarget).new"
        let serviceTarget =
            "system/\(SleepHelperConstants.helperBundleIdentifier)"

        let commands = [
            "(/bin/launchctl bootout "
                + "\(shellQuote(serviceTarget)) "
                + ">/dev/null 2>&1 || true)",
            "/usr/bin/install -d -o root -g wheel -m 0755 "
                + "/Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 0755 "
                + "\(shellQuote(bundledHelperURL.path)) "
                + "\(shellQuote(helperTarget))",
            "/usr/bin/install -o root -g wheel -m 0644 "
                + "\(shellQuote(legacyPlistURL.path)) "
                + "\(shellQuote(plistTarget))",
            "app_hash=$(/usr/bin/shasum -a 256 "
                + "\(shellQuote(appExecutableURL.path)) "
                + "| /usr/bin/awk '{print $1}')",
            "/usr/bin/printf '%s\\n%s\\n' "
                + "\(shellQuote(appExecutableURL.path)) "
                + "\"$app_hash\" > "
                + "\(shellQuote(markerTemporary))",
            "/usr/sbin/chown root:wheel "
                + "\(shellQuote(markerTemporary))",
            "/bin/chmod 0644 "
                + "\(shellQuote(markerTemporary))",
            "/bin/mv -f "
                + "\(shellQuote(markerTemporary)) "
                + "\(shellQuote(markerTarget))",
            "/bin/launchctl enable "
                + "\(shellQuote(serviceTarget))",
            "/bin/launchctl bootstrap system "
                + "\(shellQuote(plistTarget))",
        ]
        let command = commands.joined(separator: " && ")
        let script = "do shell script "
            + appleScriptQuote(command)
            + " with administrator privileges"

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = error.fileHandleForReading
                .readDataToEndOfFile()
            let message = String(
                data: data,
                encoding: .utf8)?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines)
            throw PrivilegedSleepHelperInstallerError
                .installationFailed(
                    message?.isEmpty == false
                        ? message!
                        : "osascript exited with "
                            + "\(process.terminationStatus)")
        }

        guard installationStatus() == .installed else {
            throw PrivilegedSleepHelperInstallerError
                .verificationFailed
        }
    }

    private func fileDigest(_ url: URL) -> String? {
        guard let data = try? Data(
            contentsOf: url,
            options: .mappedIfSafe) else {
            return nil
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func shellQuote(_ value: String) -> String {
        "'"
            + value.replacingOccurrences(
                of: "'",
                with: "'\"'\"'")
            + "'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        "\""
            + value
                .replacingOccurrences(
                    of: "\\",
                    with: "\\\\")
                .replacingOccurrences(
                    of: "\"",
                    with: "\\\"")
            + "\""
    }
}

enum PrivilegedSleepHelperInstallerError: LocalizedError {
    case bundledPayloadMissing
    case installationFailed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .bundledPayloadMissing:
            return "The app bundle does not contain the sleep helper."
        case let .installationFailed(message):
            return message
        case .verificationFailed:
            return "The installed sleep helper did not match the app."
        }
    }
}
