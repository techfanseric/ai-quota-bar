namespace AQB.Clash;

public sealed record ClashVersion
{
    public bool? Meta { get; init; }

    public required string Version { get; init; }
}

public sealed record ClashProxyHistory
{
    public string? Time { get; init; }

    public int Delay { get; init; }
}

/// <summary>A proxy or group entry from GET /proxies. Selector and URLTest groups expose Now/All.</summary>
public sealed record ClashProxy
{
    public string? Name { get; init; }

    public string Type { get; init; } = "";

    /// <summary>Currently selected member (Selector/URLTest groups).</summary>
    public string? Now { get; init; }

    /// <summary>Member names for groups.</summary>
    public IReadOnlyList<string>? All { get; init; }

    public IReadOnlyList<ClashProxyHistory>? History { get; init; }

    public int? LatestDelay => History is { Count: > 0 } ? History[^1].Delay : null;
}

public sealed record ClashRule
{
    public string Type { get; init; } = "";

    public string Payload { get; init; } = "";

    /// <summary>Target group name of the rule.</summary>
    public string Proxy { get; init; } = "";
}

/// <summary>One switchable route inside a group (name is unique within the group).</summary>
public sealed record ClashRoute
{
    public required string Name { get; init; }

    public string Type { get; init; } = "Unknown";

    /// <summary>null = never tested, 0 = timed out during the last test.</summary>
    public int? Delay { get; init; }

    public bool IsSelected { get; init; }

    public bool HasUsableDelay => Delay is > 0;
}

public sealed record ClashRouteSnapshot
{
    public required string GroupName { get; init; }

    public string? SelectedRouteName { get; init; }

    public required IReadOnlyList<ClashRoute> Routes { get; init; }
}

/// <summary>Exception carrying a machine readable reason plus HTTP status when available.</summary>
public sealed class ClashApiException : Exception
{
    public const string ApiFailure = "apiFailure";

    public const string ControllerUnavailable = "controllerUnavailable";

    public const string IncompatibleResponse = "incompatibleResponse";

    public string Reason { get; }

    /// <summary>HTTP status code, or 0 for transport/parse failures.</summary>
    public int StatusCode { get; }

    public ClashApiException(string reason, int statusCode, string message)
        : base(message)
    {
        Reason = reason;
        StatusCode = statusCode;
    }
}
