// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexRateWindowNormalizer.swift
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexUsageParserTests.cs（free-weekly-only / unknown-window /
//   pat-team-weekly 等 fixture 场景）

#nullable enable

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 主/周窗口归一（Swift: CodexRateWindowNormalizer）。窗口角色按分钟数判定：
/// 300 = 会话（5h）、10080 = 周、其余 = 未知。free 计划把 604800s 的窗口放在 primary
/// 时必须移到 secondary；primary/secondary 逆转（周在前）时交换；未知窗口保留在 primary。
/// </summary>
public static class CodexRateWindowNormalizer
{
    private const int SessionWindowMinutes = 300;
    private const int WeeklyWindowMinutes = 10080;

    public static (CodexRateWindow? Primary, CodexRateWindow? Secondary) Normalize(
        CodexRateWindow? primary,
        CodexRateWindow? secondary)
    {
        if (primary is { } primaryWindow && secondary is { } secondaryWindow)
        {
            return (Role(primaryWindow), Role(secondaryWindow)) switch
            {
                (WindowRole.Session, WindowRole.Weekly) or
                (WindowRole.Session, WindowRole.Unknown) or
                (WindowRole.Unknown, WindowRole.Weekly) => (primaryWindow, secondaryWindow),
                (WindowRole.Weekly, WindowRole.Session) or
                (WindowRole.Weekly, WindowRole.Unknown) => (secondaryWindow, primaryWindow),
                _ => (primaryWindow, secondaryWindow),
            };
        }

        if (primary is { } onlyPrimary)
        {
            return Role(onlyPrimary) == WindowRole.Weekly
                ? (null, onlyPrimary)
                : (onlyPrimary, null);
        }

        if (secondary is { } onlySecondary)
        {
            return Role(onlySecondary) == WindowRole.Weekly
                ? (null, onlySecondary)
                : (onlySecondary, null);
        }

        return (null, null);
    }

    private enum WindowRole
    {
        Session,
        Weekly,
        Unknown,
    }

    private static WindowRole Role(CodexRateWindow window) => window.WindowMinutes switch
    {
        SessionWindowMinutes => WindowRole.Session,
        WeeklyWindowMinutes => WindowRole.Weekly,
        _ => WindowRole.Unknown,
    };
}
