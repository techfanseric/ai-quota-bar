import Foundation

struct ClashConfigurationDiscovery {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func discover() throws -> ClashControllerConfiguration {
        var foundConfiguration = false

        for candidate in candidateConfigurations {
            guard fileManager.fileExists(atPath: candidate.url.path) else { continue }
            foundConfiguration = true

            guard let data = fileManager.contents(atPath: candidate.url.path),
                  let contents = String(data: data, encoding: .utf8) else {
                continue
            }

            let values = ClashTopLevelYAML.parse(contents)
            guard let rawController = values["external-controller"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawController.isEmpty else {
                continue
            }

            let baseURL = try Self.controllerURL(from: rawController)
            return ClashControllerConfiguration(
                baseURL: baseURL,
                secret: values["secret"] ?? "",
                clientName: candidate.clientName,
                configURL: candidate.url)
        }

        if foundConfiguration {
            throw ClashIntegrationError.externalControllerDisabled
        }
        throw ClashIntegrationError.configurationNotFound
    }

    private var candidateConfigurations: [(url: URL, clientName: String)] {
        [
            (
                homeDirectory.appending(
                    path: "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"),
                "Clash Verge Rev"
            ),
            (
                homeDirectory.appending(path: ".config/mihomo/config.yaml"),
                "Mihomo"
            ),
            (
                homeDirectory.appending(path: ".config/clash/config.yaml"),
                "Clash"
            ),
        ]
    }

    static func controllerURL(from rawAddress: String) throws -> URL {
        var address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix(":") {
            address = "127.0.0.1\(address)"
        } else if address.hasPrefix("*:") {
            address = "127.0.0.1:\(address.dropFirst(2))"
        } else if address.hasPrefix("0.0.0.0:") {
            address = "127.0.0.1:\(address.dropFirst("0.0.0.0:".count))"
        } else if address.hasPrefix("[::]:") {
            address = "127.0.0.1:\(address.dropFirst("[::]:".count))"
        }

        if !address.contains("://") {
            address = "http://\(address)"
        }

        guard let components = URLComponents(string: address),
              let host = components.host?.lowercased(),
              let port = components.port,
              port > 0,
              let url = components.url else {
            throw ClashIntegrationError.invalidControllerAddress(rawAddress)
        }

        let localHosts = Set(["127.0.0.1", "localhost", "::1"])
        guard localHosts.contains(host) else {
            throw ClashIntegrationError.unsafeControllerHost(host)
        }

        return url
    }
}

enum ClashTopLevelYAML {
    static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            guard let first = rawLine.first,
                  !first.isWhitespace,
                  first != "#",
                  let separator = rawLine.firstIndex(of: ":") else {
                continue
            }

            let key = rawLine[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            let valueStart = rawLine.index(after: separator)
            let rawValue = String(rawLine[valueStart...])
            result[key] = decodeScalar(rawValue)
        }

        return result
    }

    private static func decodeScalar(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("'") {
            guard let closingIndex = closingSingleQuote(in: trimmed) else {
                return String(trimmed.dropFirst())
            }
            let value = trimmed[trimmed.index(after: trimmed.startIndex)..<closingIndex]
            return value.replacingOccurrences(of: "''", with: "'")
        }

        if trimmed.hasPrefix("\"") {
            if let data = trimmed.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return decoded
            }
            if let closingIndex = closingDoubleQuote(in: trimmed) {
                return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingIndex])
            }
        }

        if let commentRange = trimmed.range(of: " #") {
            return String(trimmed[..<commentRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func closingSingleQuote(in value: String) -> String.Index? {
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            guard value[index] == "'" else {
                index = value.index(after: index)
                continue
            }

            let next = value.index(after: index)
            if next < value.endIndex, value[next] == "'" {
                index = value.index(after: next)
                continue
            }
            return index
        }
        return nil
    }

    private static func closingDoubleQuote(in value: String) -> String.Index? {
        var index = value.index(after: value.startIndex)
        var isEscaped = false

        while index < value.endIndex {
            let character = value[index]
            if character == "\"", !isEscaped {
                return index
            }
            if character == "\\" {
                isEscaped.toggle()
            } else {
                isEscaped = false
            }
            index = value.index(after: index)
        }
        return nil
    }
}
