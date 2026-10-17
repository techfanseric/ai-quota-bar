using System.Text.RegularExpressions;
using AQB.Core;

namespace AQB.Providers.Kimi;

/// <summary>
/// Strips ANSI/CSI escape sequences, OSC hyperlinks/title sequences and stray control
/// characters from terminal output, mirroring the macOS TextParsing cleaner (spec §1.5).
/// </summary>
public static class AnsiText
{
    private static readonly Regex OscSequence = new(
        "\u001B\\][^\u0007\u001B]*(?:\u0007|\u001B\\\\)",
        RegexOptions.Compiled);

    private static readonly Regex CsiSequence = new(
        "\u001B\\[[0-9;?]*[ -/]*[@-~]",
        RegexOptions.Compiled);

    private static readonly Regex LoneEscape = new(
        "\u001B.",
        RegexOptions.Compiled | RegexOptions.Singleline);

    private static readonly Regex ControlChars = new(
        "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]",
        RegexOptions.Compiled);

    public static string Strip(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }

        var cleaned = OscSequence.Replace(text, "");
        cleaned = CsiSequence.Replace(cleaned, "");
        cleaned = LoneEscape.Replace(cleaned, "");
        cleaned = ControlChars.Replace(cleaned, "");
        return cleaned;
    }
}

/// <summary>CLI /status result: primary weekly window, secondary 5h window, capture time.</summary>
public sealed class KimiUsageSnapshot
{
    public QuotaWindowSample? Primary { get; init; }

    public QuotaWindowSample? Secondary { get; init; }

    public DateTimeOffset UpdatedAt { get; init; }

    public ProviderSnapshot ToProviderSnapshot()
    {
        var windows = new List<QuotaWindowSample>(2);
        if (Secondary is not null)
        {
            windows.Add(Secondary);
        }

        if (Primary is not null)
        {
            windows.Add(Primary);
        }

        return new ProviderSnapshot
        {
            Kind = ProviderKind.Kimi,
            Status = ProviderStatus.Ok,
            LastUpdatedUtc = UpdatedAt,
            Accounts = new[]
            {
                new ProviderAccountSnapshot
                {
                    AccountKey = "kimi-cli",
                    Label = "Kimi",
                    SourceLabel = "Kimi Code CLI /status",
                    IsCurrent = true,
                    Windows = windows,
                },
            },
        };
    }
}

/// <summary>
/// Pure parser for `kimi` CLI /status output (spec §1.5): finds the "Weekly limit" and
/// "5h limit"/"5-hour limit" lines, extracts used/left percent and the "resets in ..." delta.
/// </summary>
public static class KimiCliStatusParser
{
    private static readonly Regex WeeklyLine = new(@"Weekly\s+limit", RegexOptions.Compiled);
    private static readonly Regex FiveHourLine = new(@"(?:5h|5-hour)\s+limit", RegexOptions.Compiled);
    private static readonly Regex UsedPercent = new(@"([0-9]{1,3})\s*%\s*used", RegexOptions.Compiled);
    private static readonly Regex LeftPercent = new(@"([0-9]{1,3})\s*%\s*(?:left|remaining)", RegexOptions.Compiled);
    private static readonly Regex DurationPart = new(@"([0-9]+)\s*([dhms])", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public static KimiUsageSnapshot Parse(string output, DateTimeOffset now)
    {
        var raw = output ?? "";
        var cleaned = AnsiText.Strip(raw);

        string? weeklyLine = null;
        string? fiveHourLine = null;
        foreach (var rawLine in cleaned.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r').Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (weeklyLine is null && WeeklyLine.IsMatch(line))
            {
                weeklyLine = line;
            }

            if (fiveHourLine is null && FiveHourLine.IsMatch(line))
            {
                fiveHourLine = line;
            }
        }

        var weekly = ParseWindow(weeklyLine, "Weekly", QuotaWindowRole.Primary, 604800, now);
        var fiveHour = ParseWindow(fiveHourLine, "5h", QuotaWindowRole.Secondary, 18000, now);

        if (weekly is null && fiveHour is null)
        {
            var mentionsTrust = raw.Contains("Trust this folder?", StringComparison.Ordinal) ||
                cleaned.Contains("Trust this folder?", StringComparison.Ordinal);
            throw mentionsTrust
                ? new KimiCliException(
                    KimiCliReason.WorkspaceTrustRequired,
                    "Kimi CLI 需要先信任工作区 / Kimi CLI requires the workspace to be trusted first.")
                : new KimiCliException(
                    KimiCliReason.StatusUnavailable,
                    "Kimi Code CLI /status did not return quota data.");
        }

        return new KimiUsageSnapshot
        {
            Primary = weekly,
            Secondary = fiveHour,
            UpdatedAt = now,
        };
    }

    private static QuotaWindowSample? ParseWindow(
        string? line,
        string name,
        QuotaWindowRole role,
        long windowSeconds,
        DateTimeOffset now)
    {
        if (line is null)
        {
            return null;
        }

        double used;
        var usedMatch = UsedPercent.Match(line);
        if (usedMatch.Success)
        {
            used = int.Parse(usedMatch.Groups[1].Value);
        }
        else
        {
            var leftMatch = LeftPercent.Match(line);
            if (!leftMatch.Success)
            {
                return null;
            }

            used = 100 - int.Parse(leftMatch.Groups[1].Value);
        }

        used = Math.Clamp(used, 0, 100);
        var resetsAt = TryParseResetsAt(line, out var seconds)
            ? now.AddSeconds(seconds)
            : now;

        return new QuotaWindowSample
        {
            Role = role,
            Name = name,
            WindowSeconds = windowSeconds,
            UsedPercent = used,
            ResetsAtUtc = resetsAt,
            CapturedAtUtc = now,
            StartsAtUtc = null,
        };
    }

    /// <summary>Reset strings of the form "... resets in 1d 18h 35m": d=86400/h=3600/m=60/s=1 seconds.</summary>
    internal static bool TryParseResetsAt(string line, out long totalSeconds)
    {
        totalSeconds = 0;
        var searchStart = 0;
        var resetIndex = line.IndexOf("reset", StringComparison.OrdinalIgnoreCase);
        if (resetIndex >= 0)
        {
            var inIndex = line.IndexOf("in ", resetIndex, StringComparison.OrdinalIgnoreCase);
            if (inIndex >= 0)
            {
                searchStart = inIndex + 3;
            }
            else
            {
                return false;
            }
        }
        else
        {
            var inIndex = line.IndexOf("in ", StringComparison.Ordinal);
            if (inIndex < 0)
            {
                return false;
            }

            searchStart = inIndex + 3;
        }

        var tail = line[searchStart..];
        var matched = false;
        foreach (Match match in DurationPart.Matches(tail))
        {
            var amount = long.Parse(match.Groups[1].Value);
            var multiplier = char.ToLowerInvariant(match.Groups[2].Value[0]) switch
            {
                'd' => 86400L,
                'h' => 3600L,
                'm' => 60L,
                's' => 1L,
                _ => 0L,
            };
            if (multiplier == 0)
            {
                continue;
            }

            totalSeconds += amount * multiplier;
            matched = true;
        }

        return matched;
    }
}
