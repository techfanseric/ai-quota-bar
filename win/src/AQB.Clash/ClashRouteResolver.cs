using System.Text.RegularExpressions;

namespace AQB.Clash;

/// <summary>
/// Numeric-aware, case-insensitive string comparison approximating macOS
/// localizedStandardCompare so group ordering stays stable across platforms.
/// </summary>
public sealed class NaturalStringComparer : IComparer<string>
{
    public static readonly NaturalStringComparer Instance = new();

    public int Compare(string? x, string? y)
    {
        if (ReferenceEquals(x, y))
        {
            return 0;
        }

        if (x is null)
        {
            return -1;
        }

        if (y is null)
        {
            return 1;
        }

        var i = 0;
        var j = 0;
        while (i < x.Length && j < y.Length)
        {
            var xDigit = char.IsAsciiDigit(x[i]);
            var yDigit = char.IsAsciiDigit(y[j]);
            if (xDigit && yDigit)
            {
                var xStart = i;
                var yStart = j;
                while (i < x.Length && char.IsAsciiDigit(x[i]))
                {
                    i++;
                }

                while (j < y.Length && char.IsAsciiDigit(y[j]))
                {
                    j++;
                }

                var xDigits = x[xStart..i];
                var yDigits = y[yStart..j];
                var order = xDigits.Length.CompareTo(yDigits.Length);
                if (order != 0)
                {
                    return order;
                }

                order = string.CompareOrdinal(xDigits, yDigits);
                if (order != 0)
                {
                    return order;
                }

                continue;
            }

            var charOrder = char.ToLowerInvariant(x[i]).CompareTo(char.ToLowerInvariant(y[j]));
            if (charOrder != 0)
            {
                return charOrder;
            }

            i++;
            j++;
        }

        return (x.Length - i).CompareTo(y.Length - j);
    }

    private NaturalStringComparer()
    {
    }
}

/// <summary>
/// Pure functions finding the OpenAI strategy group (rules first, name heuristics as fallback)
/// and ordering routes by usable latency, mirroring the macOS resolver.
/// </summary>
public static class ClashRouteResolver
{
    private static readonly Regex StandaloneAiPattern =
        new(@"(^|[^a-z])ai([^a-z]|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly string[] ObservedDomains = { "openai.com", "chatgpt.com" };

    /// <summary>
    /// Resolves the switchable OpenAI Selector group: the first rule whose type/payload marks it
    /// as an OpenAI rule and whose target is a Selector with members; otherwise the first stable
    /// ordered candidate whose name looks like an OpenAI group. null when nothing matches.
    /// </summary>
    public static string? ResolveGroupName(
        IReadOnlyList<ClashRule> rules,
        IReadOnlyDictionary<string, ClashProxy> proxies)
    {
        var selectors = proxies.Values
            .Where(proxy => proxy.Type.Equals("Selector", StringComparison.OrdinalIgnoreCase)
                && proxy.All is { Count: > 0 })
            .ToDictionary(proxy => proxy.Name ?? "", proxy => proxy, StringComparer.Ordinal);

        foreach (var rule in rules)
        {
            if (IsOpenAiRule(rule)
                && selectors.TryGetValue(rule.Proxy, out _))
            {
                return rule.Proxy;
            }
        }

        return selectors.Values
            .OrderBy(proxy => proxy.Name ?? "", NaturalStringComparer.Instance)
            .Select(proxy => proxy.Name)
            .OfType<string>()
            .FirstOrDefault(IsLikelyOpenAiGroupName);
    }

    /// <summary>Builds the route list for a group: member name -> type/last delay/selected flag.</summary>
    public static IReadOnlyList<ClashRoute> BuildRoutes(
        ClashProxy group,
        IReadOnlyDictionary<string, ClashProxy> proxies)
    {
        if (group.All is null)
        {
            return Array.Empty<ClashRoute>();
        }

        return group.All
            .Select(name => proxies.TryGetValue(name, out var proxy)
                ? new ClashRoute
                {
                    Name = name,
                    Type = proxy.Type.Length > 0 ? proxy.Type : "Unknown",
                    Delay = proxy.LatestDelay,
                    IsSelected = name == group.Now,
                }
                : new ClashRoute
                {
                    Name = name,
                    Type = "Unknown",
                    Delay = null,
                    IsSelected = name == group.Now,
                })
            .ToArray();
    }

    /// <summary>Applies speed test results (missing entries become 0 = timed out) and re-sorts.</summary>
    public static IReadOnlyList<ClashRoute> ApplyDelays(
        IReadOnlyList<ClashRoute> routes,
        IReadOnlyDictionary<string, int> delays)
        => RouteSorter.Sort(routes.Select(route => route with { Delay = delays.TryGetValue(route.Name, out var delay) ? delay : 0 }));

    /// <summary>Rule classification: domain / domainsuffix / domainkeyword / ruleset|geosite only.</summary>
    public static bool IsOpenAiRule(ClashRule rule)
    {
        var type = new string(rule.Type.ToLowerInvariant().Where(char.IsLetter).ToArray());
        var payload = rule.Payload.Trim().ToLowerInvariant();

        switch (type)
        {
            case "domain":
                return payload == "openai.com" || payload == "chatgpt.com";
            case "domainsuffix":
                return ObservedDomains.Any(domain =>
                    domain == payload || domain.EndsWith("." + payload, StringComparison.Ordinal));
            case "domainkeyword":
                return payload.Contains("openai", StringComparison.Ordinal)
                    || payload.Contains("chatgpt", StringComparison.Ordinal);
            case "ruleset":
            case "geosite":
                return payload == "ai"
                    || payload.Contains("openai", StringComparison.Ordinal)
                    || payload.Contains("chatgpt", StringComparison.Ordinal)
                    || payload.Contains("category-ai", StringComparison.Ordinal)
                    || payload.Contains("ai-chat", StringComparison.Ordinal);
            default:
                return false;
        }
    }

    /// <summary>Name fallback: contains openai/chatgpt/海外ai/人工智能, or a standalone "ai" word.</summary>
    public static bool IsLikelyOpenAiGroupName(string name)
    {
        var lowercased = name.ToLowerInvariant();
        if (lowercased.Contains("openai", StringComparison.Ordinal)
            || lowercased.Contains("chatgpt", StringComparison.Ordinal)
            || lowercased.Contains("海外ai", StringComparison.Ordinal)
            || lowercased.Contains("人工智能", StringComparison.Ordinal))
        {
            return true;
        }

        return StandaloneAiPattern.IsMatch(name);
    }
}

/// <summary>Usable delays first (ascending), timeouts (0) and untested (null) last by name order.</summary>
public static class RouteSorter
{
    public static IReadOnlyList<ClashRoute> Sort(IEnumerable<ClashRoute> routes)
        => routes.OrderBy(route => route, RouteComparer.Instance).ToArray();

    private sealed class RouteComparer : IComparer<ClashRoute>
    {
        public static readonly RouteComparer Instance = new();

        public int Compare(ClashRoute? x, ClashRoute? y)
        {
            if (ReferenceEquals(x, y))
            {
                return 0;
            }

            if (x is null)
            {
                return -1;
            }

            if (y is null)
            {
                return 1;
            }

            switch (x.HasUsableDelay, y.HasUsableDelay)
            {
                case (true, false):
                    return -1;
                case (false, true):
                    return 1;
                case (true, true) when x.Delay != y.Delay:
                    return (x.Delay ?? int.MaxValue).CompareTo(y.Delay ?? int.MaxValue);
            }

            return NaturalStringComparer.Instance.Compare(x.Name, y.Name);
        }

        private RouteComparer()
        {
        }
    }
}
