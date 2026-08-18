import CodexBarCore
import Foundation

protocol KimiCLIStatusProviding: Sendable {
    func fetchUsageSnapshot() async throws -> UsageSnapshot
}

enum KimiCLIStatusProbeError: LocalizedError, Sendable, Equatable {
    case cliNotInstalled
    case statusUnavailable
    case workspaceTrustRequired

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            "Kimi Code CLI is not installed."
        case .statusUnavailable:
            "Kimi Code CLI /status did not return quota data."
        case .workspaceTrustRequired:
            "Kimi Code CLI workspace trust could not be completed for the dedicated status folder."
        }
    }
}

/// Runs the real Kimi Code slash command in a PTY. Unlike `kimi -p`, `/status`
/// is handled locally by the CLI and does not create a model turn or consume
/// context tokens. Keeping OAuth refresh inside the official CLI also avoids
/// racing its short-lived access/refresh token rotation.
struct KimiCLIStatusProbe: KimiCLIStatusProviding, Sendable {
    var timeout: TimeInterval = 10
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func fetchUsageSnapshot() async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            let binary = try Self.resolveBinary(environment: environment)
            let workingDirectory = try Self.probeWorkingDirectory(
                environment: environment)
            let result = try TTYCommandRunner().run(
                binary: binary,
                send: "",
                options: .init(
                    rows: 60,
                    cols: 180,
                    timeout: timeout,
                    idleTimeout: 1.2,
                    workingDirectory: workingDirectory,
                    baseEnvironment: environment,
                    initialDelay: 0.2,
                    sendOnSubstrings: [
                        "Trust this folder?": "\u{1b}[A\r",
                        "context:": "/status\r",
                    ],
                    stopOnSubstrings: ["5h limit", "5-hour limit"],
                    settleAfterStop: 0.6))
            return try Self.parse(text: result.text, now: Date())
        }.value
    }

    static func parse(text: String, now: Date) throws -> UsageSnapshot {
        let clean = stripTerminalControlSequences(text)
        let weeklyLine = TextParsing.firstLine(
            matching: #"Weekly\s+limit[^\n]*"#,
            text: clean)
        let fiveHourLine = TextParsing.firstLine(
            matching: #"(?:5h|5-hour)\s+limit[^\n]*"#,
            text: clean)
        let weekly = weeklyLine.flatMap {
            rateWindow(from: $0, windowMinutes: 7 * 24 * 60, now: now)
        }
        let fiveHour = fiveHourLine.flatMap {
            rateWindow(from: $0, windowMinutes: 5 * 60, now: now)
        }
        guard weekly != nil || fiveHour != nil else {
            if clean.localizedCaseInsensitiveContains("Trust this folder?") {
                throw KimiCLIStatusProbeError.workspaceTrustRequired
            }
            throw KimiCLIStatusProbeError.statusUnavailable
        }

        return UsageSnapshot(
            primary: weekly,
            secondary: fiveHour,
            updatedAt: now)
    }

    private static func rateWindow(
        from line: String,
        windowMinutes: Int,
        now: Date
    ) -> RateWindow? {
        guard let usedPercent = percentUsed(from: line) else { return nil }
        return RateWindow(
            usedPercent: Double(usedPercent),
            windowMinutes: windowMinutes,
            resetsAt: resetDate(from: line, now: now),
            resetDescription: TextParsing.resetString(fromLine: line))
    }

    private static func percentUsed(from line: String) -> Int? {
        if let used = TextParsing.firstInt(
            pattern: #"([0-9]{1,3})%\s*used"#,
            text: line) {
            return min(100, max(0, used))
        }
        if let left = TextParsing.firstInt(
            pattern: #"([0-9]{1,3})%\s*(?:left|remaining)"#,
            text: line) {
            return 100 - min(100, max(0, left))
        }
        return nil
    }

    private static func resetDate(from line: String, now: Date) -> Date? {
        guard let reset = TextParsing.resetString(fromLine: line)?.lowercased(),
              reset.hasPrefix("in ") else { return nil }
        let body = reset.dropFirst(3)
        guard let regex = try? NSRegularExpression(
            pattern: #"([0-9]+)\s*([dhms])"#,
            options: [.caseInsensitive]) else { return nil }
        let string = String(body)
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        var seconds: TimeInterval = 0
        for match in regex.matches(in: string, range: range) {
            guard match.numberOfRanges == 3,
                  let valueRange = Range(match.range(at: 1), in: string),
                  let unitRange = Range(match.range(at: 2), in: string),
                  let value = Double(string[valueRange]) else { continue }
            switch string[unitRange].lowercased() {
            case "d": seconds += value * 24 * 60 * 60
            case "h": seconds += value * 60 * 60
            case "m": seconds += value * 60
            case "s": seconds += value
            default: break
            }
        }
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }

    private static func stripTerminalControlSequences(_ text: String) -> String {
        var result = TextParsing.stripANSICodes(text)
        // OSC hyperlinks/titles terminate with BEL or ST and are not CSI.
        result = result.replacingOccurrences(
            of: #"\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)"#,
            with: "",
            options: .regularExpression)
        return result.replacingOccurrences(
            of: #"[\u0000-\u0008\u000B\u000C\u000E-\u001A\u001C-\u001F]"#,
            with: "",
            options: .regularExpression)
    }

    private static func resolveBinary(
        environment: [String: String]
    ) throws -> String {
        let home = homeDirectory(environment: environment)
        let codeHome = environment["KIMI_CODE_HOME"].flatMap { raw in
            raw.isEmpty ? nil : URL(fileURLWithPath: raw, isDirectory: true)
        } ?? home.appendingPathComponent(".kimi-code", isDirectory: true)
        let bundled = codeHome
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("kimi", isDirectory: false).path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        if let located = TTYCommandRunner.which("kimi") {
            return located
        }
        throw KimiCLIStatusProbeError.cliNotInstalled
    }

    private static func homeDirectory(
        environment: [String: String]
    ) -> URL {
        if let raw = environment["HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func probeWorkingDirectory(
        environment: [String: String]
    ) throws -> URL {
        let url = homeDirectory(environment: environment)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(
                "com.techfanseric.aiquotabar",
                isDirectory: true)
            .appendingPathComponent("KimiStatusProbe", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        return url
    }
}
