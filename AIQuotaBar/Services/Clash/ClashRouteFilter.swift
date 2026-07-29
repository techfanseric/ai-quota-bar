import Foundation

struct ClashRouteFilterResult: Equatable, Sendable {
    let routes: [ClashRoute]
    let errorMessage: String?
}

enum ClashRouteFilter {
    static func filter(
        _ routes: [ClashRoute],
        query: String,
        usesRegularExpression: Bool
    ) -> ClashRouteFilterResult {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return ClashRouteFilterResult(routes: routes, errorMessage: nil)
        }

        if usesRegularExpression {
            do {
                let expression = try NSRegularExpression(
                    pattern: trimmedQuery,
                    options: [.caseInsensitive])
                let filtered = routes.filter { route in
                    let range = NSRange(route.name.startIndex..., in: route.name)
                    return expression.firstMatch(
                        in: route.name,
                        options: [],
                        range: range) != nil
                }
                return ClashRouteFilterResult(routes: filtered, errorMessage: nil)
            } catch {
                return ClashRouteFilterResult(
                    routes: [],
                    errorMessage: error.localizedDescription)
            }
        }

        let normalizedQuery = normalize(trimmedQuery)
        let queryCountries = Set(countryAliases.compactMap { country in
            country.aliases.contains(where: { normalize($0) == normalizedQuery })
                ? country.code
                : nil
        })

        let filtered = routes.filter { route in
            let normalizedName = normalize(route.name)
            if normalizedName.contains(normalizedQuery) {
                return true
            }

            guard !queryCountries.isEmpty else { return false }
            let routeCountries = Set(countryAliases.compactMap { country in
                country.aliases.contains(where: { alias in
                    containsAlias(alias, in: route.name)
                }) ? country.code : nil
            })
            return !routeCountries.isDisjoint(with: queryCountries)
        }

        return ClashRouteFilterResult(routes: filtered, errorMessage: nil)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAlias(_ alias: String, in name: String) -> Bool {
        let normalizedAlias = normalize(alias)
        let normalizedName = normalize(name)

        guard normalizedAlias.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil else {
            return normalizedName.contains(normalizedAlias)
        }

        guard let expression = try? NSRegularExpression(
            pattern: "(^|[^a-z])\(NSRegularExpression.escapedPattern(for: normalizedAlias))([^a-z]|$)",
            options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(normalizedName.startIndex..., in: normalizedName)
        return expression.firstMatch(in: normalizedName, range: range) != nil
    }

    private static let countryAliases: [CountryAliases] = [
        CountryAliases(code: "JP", aliases: ["🇯🇵", "日本", "Japan", "JP"]),
        CountryAliases(code: "SG", aliases: ["🇸🇬", "新加坡", "Singapore", "SG"]),
        CountryAliases(code: "US", aliases: ["🇺🇸", "美国", "United States", "USA", "US"]),
        CountryAliases(code: "HK", aliases: ["🇭🇰", "香港", "Hong Kong", "HK"]),
        CountryAliases(code: "TW", aliases: ["🇹🇼", "台湾", "臺灣", "Taiwan", "TW"]),
        CountryAliases(code: "KR", aliases: ["🇰🇷", "韩国", "韓國", "Korea", "KR"]),
        CountryAliases(code: "GB", aliases: ["🇬🇧", "英国", "英國", "United Kingdom", "UK", "GB"]),
        CountryAliases(code: "DE", aliases: ["🇩🇪", "德国", "德國", "Germany", "DE"]),
        CountryAliases(code: "FR", aliases: ["🇫🇷", "法国", "法國", "France", "FR"]),
        CountryAliases(code: "CA", aliases: ["🇨🇦", "加拿大", "Canada", "CA"]),
        CountryAliases(code: "AU", aliases: ["🇦🇺", "澳洲", "澳大利亚", "Australia", "AU"]),
        CountryAliases(code: "NL", aliases: ["🇳🇱", "荷兰", "荷蘭", "Netherlands", "NL"]),
    ]
}

private struct CountryAliases {
    let code: String
    let aliases: [String]
}
