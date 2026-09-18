import Foundation
import Observation

/// A bounded local history. Store error codes, never server bodies, credentials or URLs.
@MainActor
@Observable
final class CloudDiagnosticLog {
    struct Entry: Codable, Identifiable {
        let id: UUID
        var date: Date
        let operation: String
        let message: String
        let failed: Bool
        var occurrences: Int
    }
    static let shared = CloudDiagnosticLog()
    private(set) var entries: [Entry]
    private let defaults: UserDefaults
    private let key = "cloud.diagnostics.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
    func record(_ operation: String, error: Error? = nil, at date: Date = .now) {
        let message: String
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                message = "URL loading error (\(ns.code))"
            } else if case CloudSyncError.serverError(let status, _) = error {
                message = "HTTP \(status)"
            } else {
                message = "Cloud operation failed"
            }
        } else { message = "OK" }
        if let index = entries.firstIndex(where: { $0.operation == operation }),
           entries[index].message == message, entries[index].failed == (error != nil) {
            var entry = entries.remove(at: index)
            entry.date = date
            entry.occurrences += 1
            entries.insert(entry, at: 0)
        } else {
            entries.insert(Entry(id: UUID(), date: date, operation: operation, message: message, failed: error != nil, occurrences: 1), at: 0)
        }
        entries = Array(entries.prefix(200))
        save()
    }
    func clear() { entries = []; save() }
    private func save() { defaults.set(try? JSONEncoder().encode(entries), forKey: key) }
}
