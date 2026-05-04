import Foundation

struct ChatGPTCredential: Codable {
    static let defaultAPIURL = "https://chatgpt.com/backend-api/codex/usage"

    let apiURL: String
    let authorization: String?
    let cookie: String?
    let headers: [String: String]

    enum CodingKeys: String, CodingKey {
        case apiURL
        case authorization
        case cookie
        case headers
    }

    var storageString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return apiURL
        }
        return string
    }

    static func parse(_ input: String) throws -> ChatGPTCredential {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw UsageError.notConfigured
        }

        if let data = trimmed.data(using: .utf8),
           let credential = try? JSONDecoder().decode(ChatGPTCredential.self, from: data),
           URL(string: credential.apiURL) != nil {
            if credential.apiURL == "https://chatgpt.com/backend-api/me" {
                return ChatGPTCredential(
                    apiURL: Self.defaultAPIURL,
                    authorization: credential.authorization,
                    cookie: credential.cookie,
                    headers: credential.headers
                )
            }
            return credential
        }

        if trimmed.lowercased().contains("curl ") || trimmed.lowercased().hasPrefix("curl") {
            return try parseCurlCommand(trimmed)
        }

        if let data = trimmed.data(using: .utf8),
           let account = try? JSONDecoder().decode(ChatGPTAccountSession.self, from: data) {
            return ChatGPTCredential(
                apiURL: Self.defaultAPIURL,
                authorization: account.accessToken.map { "Bearer \($0)" },
                cookie: nil,
                headers: [:]
            )
        }

        return ChatGPTCredential(
            apiURL: Self.defaultAPIURL,
            authorization: normalizedAuthorization(trimmed),
            cookie: nil,
            headers: [:]
        )
    }

    private static func parseCurlCommand(_ command: String) throws -> ChatGPTCredential {
        let tokens = shellTokens(from: command)
        var apiURL: String?
        var headers: [String: String] = [:]
        var cookie: String?

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            if token.lowercased().hasPrefix("http://") || token.lowercased().hasPrefix("https://") {
                apiURL = token
            } else if token == "-H" || token == "--header" {
                index += 1
                if index < tokens.count {
                    parseHeader(tokens[index], into: &headers, cookie: &cookie)
                }
            } else if token.hasPrefix("-H"), token.count > 2 {
                parseHeader(String(token.dropFirst(2)), into: &headers, cookie: &cookie)
            } else if token == "-b" || token == "--cookie" {
                index += 1
                if index < tokens.count {
                    cookie = tokens[index]
                }
            } else if token.hasPrefix("-b"), token.count > 2 {
                cookie = String(token.dropFirst(2))
            }

            index += 1
        }

        let resolvedURL = apiURL ?? defaultAPIURL
        guard URL(string: resolvedURL) != nil else {
            throw UsageError.invalidURL
        }

        return ChatGPTCredential(
            apiURL: resolvedURL,
            authorization: headers["authorization"],
            cookie: cookie,
            headers: headers
        )
    }

    private static func normalizedAuthorization(_ value: String) -> String {
        if value.lowercased().hasPrefix("bearer ") {
            return value
        }
        return "Bearer \(value)"
    }

    private static func parseHeader(
        _ rawHeader: String,
        into headers: inout [String: String],
        cookie: inout String?
    ) {
        guard let separator = rawHeader.firstIndex(of: ":") else { return }
        let name = rawHeader[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = rawHeader[rawHeader.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { return }
        if name == "cookie" {
            cookie = value
        } else {
            headers[name] = value
        }
    }

    private static func shellTokens(from command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var iterator = Array(command.replacingOccurrences(of: "\\\n", with: " ")).makeIterator()

        while let character = iterator.next() {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\", activeQuote != "'" {
                    if let next = iterator.next() {
                        current.append(next)
                    }
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
            } else if character == "\\" {
                if let next = iterator.next(), next != "\n" {
                    current.append(next)
                }
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}

private struct ChatGPTAccountSession: Decodable {
    let accessToken: String?
}
