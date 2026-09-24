// Swift 来源：无（骨架占位：Toast 实装待 WinUI 3 / App 阶段接入 Windows App SDK AppNotificationBuilder）
// 对应接口：AIQuotaBar.Platform/Notifications/IToastNotifier.cs

#nullable enable

using System;

namespace AIQuotaBar.Platform.Notifications;

/// <summary>
/// <see cref="IToastNotifier"/> 的显式未实装占位：Platform 层不引 Windows App SDK 包
/// （计划 §4「UserNotifications → AppNotificationBuilder」行），实装随 App 阶段落地后替换注册。
/// </summary>
public sealed class NotImplementedToastNotifier : IToastNotifier
{
    /// <inheritdoc />
    public bool IsAvailable => false;

    /// <inheritdoc />
    /// <exception cref="NotImplementedException">恒抛出——占位实现。</exception>
    public void Show(string title, string body) =>
        throw new NotImplementedException(
            "Toast 通知尚未实装：待 WinUI 3 / App 阶段接入 Windows App SDK AppNotificationBuilder（计划 §4）。");
}
