import Foundation

struct GLMCredential: Codable {
    static let defaultAPIURL = "https://bigmodel.cn/api/monitor/usage/quota/limit"

    let apiURL: String
    let authorization: String
    let organization: String?
    let project: String?
    let cookie: String?
    let headers: [String: String]

    init(
        apiURL: String,
        authorization: String,
        organization: String?,
        project: String?,
        cookie: String?,
        headers: [String: String] = [:]
    ) {
        self.apiURL = apiURL
        self.authorization = authorization
        self.organization = organization
        self.project = project
        self.cookie = cookie
        self.headers = headers
    }

    enum CodingKeys: String, CodingKey {
        case apiURL
        case authorization
        case organization
        case project
        case cookie
        case headers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiURL = try container.decode(String.self, forKey: .apiURL)
        authorization = try container.decode(String.self, forKey: .authorization)
        organization = try container.decodeIfPresent(String.self, forKey: .organization)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        cookie = try container.decodeIfPresent(String.self, forKey: .cookie)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }

    var storageString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return authorization
        }
        return string
    }

    static func parse(_ input: String) throws -> GLMCredential {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw UsageError.notConfigured
        }

        if let data = trimmed.data(using: .utf8),
           let credential = try? JSONDecoder().decode(GLMCredential.self, from: data),
           !credential.authorization.isEmpty {
            return credential
        }

        if trimmed.lowercased().contains("curl ") || trimmed.lowercased().hasPrefix("curl") {
            return try parseCurlCommand(trimmed)
        }

        return GLMCredential(
            apiURL: defaultAPIURL,
            authorization: trimmed,
            organization: nil,
            project: nil,
            cookie: nil,
            headers: [:]
        )
    }

    private static func parseCurlCommand(_ command: String) throws -> GLMCredential {
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

        let authorization = headers["authorization"]
            ?? cookieValue(named: "bigmodel_token_production", in: cookie)

        guard let authorization,
              !authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageError.apiError("Missing GLM authorization header in curl command.")
        }

        let resolvedURL = apiURL ?? defaultAPIURL
        guard URL(string: resolvedURL) != nil else {
            throw UsageError.invalidURL
        }

        return GLMCredential(
            apiURL: resolvedURL,
            authorization: authorization,
            organization: headers["bigmodel-organization"],
            project: headers["bigmodel-project"],
            cookie: cookie,
            headers: headers
        )
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

    private static func cookieValue(named name: String, in cookie: String?) -> String? {
        guard let cookie else { return nil }

        for part in cookie.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator]
            guard key == name else { continue }
            return String(trimmed[trimmed.index(after: separator)...])
        }

        return nil
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
                if let next = iterator.next() {
                    if next != "\n" {
                        current.append(next)
                    }
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
