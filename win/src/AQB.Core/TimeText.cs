using System.Globalization;
using System.Text;

namespace AQB.Core;

public static class TimeText
{
    /// <summary>Compact remaining time: &lt;1min "0m", &lt;1h "Nm" (floor), &lt;48h "N.Nh", else "N.Nd".</summary>
    public static string FormatRemaining(TimeSpan remaining)
    {
        if (remaining <= TimeSpan.Zero)
        {
            return "0m";
        }

        if (remaining.TotalMinutes < 60)
        {
            return $"{(int)remaining.TotalMinutes}m";
        }

        if (remaining.TotalHours < 48)
        {
            return $"{remaining.TotalHours.ToString("0.0", CultureInfo.InvariantCulture)}h";
        }

        return $"{remaining.TotalDays.ToString("0.0", CultureInfo.InvariantCulture)}d";
    }

    /// <summary>Relative age like the macOS history rows: "just now", "3m ago", "2.1h ago", "1.2d ago".</summary>
    public static string FormatRelativeAge(TimeSpan age)
    {
        if (age < TimeSpan.FromSeconds(45))
        {
            return "just now";
        }

        if (age < TimeSpan.FromMinutes(60))
        {
            return $"{(int)Math.Ceiling(age.TotalMinutes)}m ago";
        }

        if (age < TimeSpan.FromHours(48))
        {
            return $"{age.TotalHours:0.0}h ago";
        }

        return $"{age.TotalDays:0.0}d ago";
    }

    /// <summary>
    /// Fixed ISO-8601 with milliseconds, always UTC ("yyyy-MM-dd'T'HH:mm:ss.fffZ").
    /// The macOS app compares these lexicographically, so the format must stay fixed.
    /// </summary>
    public static string FixedIso(DateTimeOffset value)
        => value.ToUniversalTime().UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fffZ", CultureInfo.InvariantCulture);

    /// <summary>Parses both ISO formats used by the macOS app (with/without fractional seconds).</summary>
    public static bool TryParseIso(ReadOnlySpan<char> text, out DateTimeOffset value)
    {
        text = text.Trim();
        if (text.EndsWith("Z", StringComparison.OrdinalIgnoreCase))
        {
            var trimmed = text[..^1];
            var formats = new[]
            {
                "yyyy-MM-dd'T'HH:mm:ss.fff",
                "yyyy-MM-dd'T'HH:mm:ss",
            };
            foreach (var format in formats)
            {
                if (DateTimeOffset.TryParseExact(
                        trimmed, format, CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal, out value))
                {
                    return true;
                }
            }

            value = default;
            return false;
        }

        return DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out value);
    }

    /// <summary>Masks an account label (typically an email) for read-only remote surfaces.</summary>
    public static string MaskLabel(string label)
    {
        if (string.IsNullOrWhiteSpace(label))
        {
            return "";
        }

        var at = label.IndexOf('@');
        if (at <= 0 || at == label.Length - 1)
        {
            return label.Length <= 2 ? new string('*', label.Length) : label[0] + new string('*', label.Length - 1);
        }

        var local = label[..at];
        var domain = label[(at + 1)..];
        var head = local.Length == 1 ? local : local[..1];
        var sb = new StringBuilder(head);
        sb.Append("***@");
        sb.Append(domain);
        return sb.ToString();
    }
}
