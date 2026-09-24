// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：UserNotifications（UNUserNotificationCenter）→ Windows App SDK AppNotificationBuilder Toast）
// 注意：Platform 层不引 Windows App SDK 包——真正的 Toast 实装在 WinUI 3 / App 阶段完成（计划 §4「UserNotifications」行），
// 本接口先钉住上层消费面，避免通知接入时改动调用方。

#nullable enable

namespace AIQuotaBar.Platform.Notifications;

/// <summary>
/// 桌面 Toast 通知门面（配额告警、任务结束提醒等）。
/// </summary>
/// <remarks>
/// macOS 端对应物：UserNotifications 框架。Windows 实装走 Windows App SDK
/// <c>AppNotificationBuilder</c>（AUMID / 打包身份相关接线在 App 层完成）。
/// </remarks>
public interface IToastNotifier
{
    /// <summary>当前环境能否真正弹出 Toast（无实装/未注册 AppUserModelID 时为 false）。</summary>
    bool IsAvailable { get; }

    /// <summary>展示一条文本 Toast。</summary>
    /// <param name="title">标题行。</param>
    /// <param name="body">正文。</param>
    void Show(string title, string body);
}
