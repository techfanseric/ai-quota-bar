import Foundation

/// Presentation only: raw identities remain the keys for grouping and account actions.
enum MenuAccountPrivacy {
    static let storageKey = "maskMenuAccountNames"

    static func display(_ account: String, masked: Bool) -> String {
        guard masked, !account.isEmpty else { return account }
        if let at = account.lastIndex(of: "@") {
            return maskName(String(account[..<at])) + String(account[at...])
        }
        return maskName(account)
    }

    private static func maskName(_ name: String) -> String {
        // Short names must still lose at least one character. Do not expose a
        // one- or two-character identity in full by preserving both ends.
        guard name.count > 1, let first = name.first else { return "****" }
        guard name.count > 2, let last = name.last else { return String(first) + "****" }
        return String(first) + "****" + String(last)
    }

    /// Errors can contain an email even when it is absent from the account list.
    static func redactEmails(in text: String, masked: Bool) -> String {
        guard masked else { return text }
        let pattern = #"[^\s<>\"'(),;:@]+@[^\s<>\"'(),;:@]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: display(String(result[range]), masked: true))
        }
        return result
    }
}
