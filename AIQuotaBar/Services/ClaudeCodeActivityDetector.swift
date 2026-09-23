import Foundation

/// Detects active Claude Code sessions and attributes them to the GLM or
/// MiniMax coding plans. Claude Code is a common client for both plans via a
/// custom `ANTHROPIC_BASE_URL`, and its transcript files under
/// `~/.claude/projects/<project>/<session-uuid>.jsonl` record the responding
/// model on every assistant entry (for example `MiniMax-M3` or
/// `glm-4.7`). Read-only: only file modification times and the model field
/// inside the tail of freshly-updated transcripts are read.
final class ClaudeCodeActivityDetector: ProviderLocalActivityProviding,
    @unchecked Sendable
{
    static let defaultFreshnessWindow: TimeInterval = 120

    /// Transcript lines can be large; only the tail of a freshly updated
    /// file is scanned for the latest assistant model field.
    static let defaultTailScanBytes = 256 * 1_024

    let projectsRootURL: URL
    let freshnessWindow: TimeInterval
    let tailScanBytes: Int

    init(
        projectsRootURL: URL = ClaudeCodeActivityDetector
            .defaultProjectsRootURL(),
        freshnessWindow: TimeInterval = ClaudeCodeActivityDetector
            .defaultFreshnessWindow,
        tailScanBytes: Int = ClaudeCodeActivityDetector.defaultTailScanBytes
    ) {
        self.projectsRootURL = projectsRootURL
        self.freshnessWindow = freshnessWindow
        self.tailScanBytes = tailScanBytes
    }

    static func defaultProjectsRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let claudeHome: URL
        if let configured = environment["CLAUDE_CONFIG_DIR"],
           !configured.isEmpty {
            claudeHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            claudeHome = homeDirectory.appendingPathComponent(
                ".claude",
                isDirectory: true)
        }
        return claudeHome.appendingPathComponent(
            "projects",
            isDirectory: true)
    }

    func snapshot() async -> ProviderLocalActivitySnapshot {
        await Task.detached(priority: .utility) { [self] in
            detectSnapshot(now: Date())
        }.value
    }

    func detectSnapshot(now: Date) -> ProviderLocalActivitySnapshot {
        let cutoff = now.addingTimeInterval(-freshnessWindow)
        var activeSessionIDs = Set<String>()
        var lastEventBySession: [String: Date] = [:]
        var lastEventAt: Date?

        for projectDirectory in projectDirectories() {
            for sessionFile in freshTranscriptFiles(
                in: projectDirectory,
                cutoff: cutoff,
                now: now) {
                guard let model = lastAssistantModel(in: sessionFile.url),
                      let provider = Self.attributedProvider(for: model)
                else { continue }
                let prefixedID = "\(provider.rawValue):claude:\(sessionFile.sessionID)"
                activeSessionIDs.insert(prefixedID)
                lastEventBySession[prefixedID] = sessionFile.modifiedAt
                if lastEventAt == nil
                    || sessionFile.modifiedAt > lastEventAt! {
                    lastEventAt = sessionFile.modifiedAt
                }
            }
        }

        return ProviderLocalActivitySnapshot(
            activeSessionIDs: activeSessionIDs,
            lastEventAt: lastEventAt,
            lastEventBySession: lastEventBySession)
    }

    /// Maps a responding model name onto a protected provider. Anything else
    /// (real Anthropic models, unknown providers) is ignored so unrelated
    /// Claude Code usage never triggers protection.
    static func attributedProvider(for model: String) -> UsageProvider? {
        let name = model.lowercased()
        if name.hasPrefix("glm") { return .glm }
        if name.contains("minimax") { return .miniMax }
        return nil
    }

    private func projectDirectories() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projectsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.filter { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
        }
    }

    private func freshTranscriptFiles(
        in projectDirectory: URL,
        cutoff: Date,
        now: Date
    ) -> [(url: URL, sessionID: String, modifiedAt: Date)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [(url: URL, sessionID: String, modifiedAt: Date)] = []
        for entry in entries where entry.pathExtension == "jsonl" {
            let values = try? entry.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt >= cutoff, modifiedAt <= now else {
                continue
            }
            let sessionID = entry.deletingPathExtension().lastPathComponent
            guard !sessionID.isEmpty else { continue }
            results.append((entry, sessionID, modifiedAt))
        }
        return results
    }

    private func lastAssistantModel(in transcriptURL: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: transcriptURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              fileSize > 0,
              let file = try? FileHandle(forReadingFrom: transcriptURL)
        else { return nil }
        defer { try? file.close() }

        let tailBytes = min(Int(fileSize), tailScanBytes)
        let startOffset = UInt64(tailBytes) < fileSize
            ? fileSize - UInt64(tailBytes)
            : 0
        try? file.seek(toOffset: startOffset)
        guard let data = try? file.read(upToCount: tailBytes) else {
            return nil
        }
        var lines = data.split(
            separator: 0x0A,
            omittingEmptySubsequences: true)
        // The first line in a partial tail read may be truncated mid-JSON.
        if startOffset > 0, !lines.isEmpty {
            lines.removeFirst()
        }

        var model: String?
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let candidate = message["model"] as? String else {
                continue
            }
            if Self.attributedProvider(for: candidate) != nil {
                model = candidate
            }
        }
        return model
    }
}
