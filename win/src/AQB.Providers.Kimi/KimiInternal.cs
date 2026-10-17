using System.Globalization;
using System.Text.Json.Nodes;

namespace AQB.Providers.Kimi;

internal static class KimiJson
{
    /// <summary>Tolerant double read: JSON number, numeric string, or null when absent/unparsable.</summary>
    public static double? OptDouble(this JsonNode? node, string key)
    {
        var value = node?[key];
        if (value is null)
        {
            return null;
        }

        if (value is JsonValue json)
        {
            if (json.TryGetValue<double>(out var d))
            {
                return double.IsFinite(d) ? d : null;
            }

            if (json.TryGetValue<string>(out var s) &&
                double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
            {
                return double.IsFinite(parsed) ? parsed : null;
            }
        }

        return null;
    }

    public static long? OptLong(this JsonNode? node, string key)
    {
        var value = node?[key];
        if (value is null)
        {
            return null;
        }

        if (value is JsonValue json)
        {
            if (json.TryGetValue<long>(out var l))
            {
                return l;
            }

            if (json.TryGetValue<double>(out var d) && double.IsFinite(d))
            {
                return (long)d;
            }

            if (json.TryGetValue<string>(out var s) &&
                long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
            {
                return parsed;
            }
        }

        return null;
    }

    public static string? OptString(this JsonNode? node, string key)
    {
        var value = node?[key];
        return value is null ? null : value.ToString();
    }
}

internal static class KimiText
{
    /// <summary>Localizable subscribe end date text ("yyyy-MM-dd", UTC) — null when absent.</summary>
    public static string? EndTimeText(DateTimeOffset? endUtc)
        => endUtc is null
            ? null
            : endUtc.Value.ToUniversalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
}
