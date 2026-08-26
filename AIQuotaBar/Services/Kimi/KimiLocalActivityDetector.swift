import Foundation

struct KimiLocalActivitySnapshot: Equatable, Sendable {
    var activeSessionIDs: Set<String>
    var lastEventAt: Date?

    static let empty = KimiLocalActivitySnapshot(
        activeSessionIDs: [],
        lastEventAt: nil)
}

protocol KimiLocalActivityProviding: Sendable {
    func snapshot() async -> KimiLocalActivitySnapshot
}

/// Detects active Kimi turns from its persisted Wire lifecycle events. Message
/// bodies, model output, tool arguments, and command output are never retained.
final class KimiLocalActivityDetector: KimiLocalActivityProviding,
    @unchecked Sendable
{
    typealias RunningWorkDirectoriesProvider = @Sendable () -> [String: Int]

    private struct SessionCandidate {
        let id: String
        let directory: URL
        let workDirectory: String
        let updatedAt: Date
    }

    private struct WireState {
        var size: UInt64 = 0
        var isActive = false
        var lastEventAt: Date?
    }

    let codeHomeURL: URL
    private let runningWorkDirectoriesProvider: RunningWorkDirectoriesProvider
    private let lock = NSLock()
    private var wireStates: [String: WireState] = [:]

    init(
        codeHomeURL: URL = KimiLocalActivityDetector.defaultCodeHomeURL(),
        runningWorkDirectoriesProvider: RunningWorkDirectoriesProvider? = nil
    ) {
        self.codeHomeURL = codeHomeURL
        self.runningWorkDirectoriesProvider =
            runningWorkDirectoriesProvider ?? {
                KimiLocalActivityDetector.runningKimiWorkDirectories()
            }
    }

    func snapshot() async -> KimiLocalActivitySnapshot {
        await Task.detached(priority: .utility) { [self] in
            detectSnapshot()
        }.value
    }

    func detectSnapshot() -> KimiLocalActivitySnapshot {
        lock.lock()
        defer { lock.unlock() }

        let running = runningWorkDirectoriesProvider()
        guard !running.isEmpty else {
            wireStates.removeAll()
            return .empty
        }

        let selectedSessions = selectedSessionCandidates(
            runningWorkDirectories: running)
        var activeSessionIDs = Set<String>()
        var lastEventAt: Date?
        var retainedWirePaths = Set<String>()

        for session in selectedSessions {
            var sessionIsActive = false
            for wireURL in wireURLs(in: session.directory) {
                retainedWirePaths.insert(wireURL.path)
                let wireState = readWireState(at: wireURL)
                sessionIsActive = sessionIsActive || wireState.isActive
                if let eventAt = wireState.lastEventAt,
                   lastEventAt == nil || eventAt > lastEventAt! {
                    lastEventAt = eventAt
                }
            }
            if sessionIsActive {
                activeSessionIDs.insert("kimi:\(session.id)")
            }
        }

        wireStates = wireStates.filter {
            retainedWirePaths.contains($0.key)
        }
        return KimiLocalActivitySnapshot(
            activeSessionIDs: activeSessionIDs,
            lastEventAt: lastEventAt)
    }

    private func selectedSessionCandidates(
        runningWorkDirectories: [String: Int]
    ) -> [SessionCandidate] {
        let indexURL = codeHomeURL.appendingPathComponent(
            "session_index.jsonl",
            isDirectory: false)
        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var candidatesByWorkDirectory: [String: [SessionCandidate]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let recordData = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(
                    with: recordData) as? [String: Any],
                  let id = record["sessionId"] as? String,
                  let directoryPath = record["sessionDir"] as? String,
                  let workDirectory = record["workDir"] as? String,
                  runningWorkDirectories[workDirectory] != nil else {
                continue
            }
            let directory = URL(
                fileURLWithPath: directoryPath,
                isDirectory: true)
            candidatesByWorkDirectory[workDirectory, default: []].append(
                SessionCandidate(
                    id: id,
                    directory: directory,
                    workDirectory: workDirectory,
                    updatedAt: sessionUpdatedAt(directory)))
        }

        return candidatesByWorkDirectory.flatMap { workDirectory, candidates in
            let processCount = max(1, runningWorkDirectories[workDirectory] ?? 1)
            return candidates
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(processCount)
        }
    }

    private func sessionUpdatedAt(_ directory: URL) -> Date {
        wireURLs(in: directory)
            .compactMap {
                try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            }
            .max() ?? .distantPast
    }

    private func wireURLs(in sessionDirectory: URL) -> [URL] {
        let agentsURL = sessionDirectory.appendingPathComponent(
            "agents",
            isDirectory: true)
        guard let agentURLs = try? FileManager.default.contentsOfDirectory(
            at: agentsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return agentURLs.compactMap { agentURL in
            let wireURL = agentURL.appendingPathComponent(
                "wire.jsonl",
                isDirectory: false)
            return FileManager.default.fileExists(atPath: wireURL.path)
                ? wireURL
                : nil
        }
    }

    private func readWireState(at url: URL) -> WireState {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = wireStates[url.path], cached.size == size {
            return cached
        }

        guard let data = try? Data(contentsOf: url) else {
            let empty = WireState(size: size)
            wireStates[url.path] = empty
            return empty
        }

        var state = WireState(size: size)
        for line in data.split(separator: 0x0A) {
            guard let record = try? JSONSerialization.jsonObject(
                with: Data(line)) as? [String: Any],
                  let type = record["type"] as? String else {
                continue
            }
            switch type {
            case "turn.prompt":
                state.isActive = true
            case "turn.ended":
                state.isActive = false
            default:
                break
            }
            if let milliseconds = record["time"] as? NSNumber {
                state.lastEventAt = Date(
                    timeIntervalSince1970:
                        milliseconds.doubleValue / 1_000)
            }
        }
        wireStates[url.path] = state
        return state
    }

    static func defaultCodeHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = environment["KIMI_CODE_HOME"],
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
    }

    static func runningKimiWorkDirectories() -> [String: Int] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-c", "kimi", "-d", "cwd", "-Fn"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }
        guard process.terminationStatus == 0,
              let text = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) else {
            return [:]
        }

        var directories: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.first == "n" else { continue }
            let path = String(line.dropFirst())
            directories[path, default: 0] += 1
        }
        return directories
    }
}
