// Swift 来源：AIQuotaBar/Models/AppLanguage.swift — enum AppText + text(_:) 双语字典（v1.28.1）
// Windows 形态：全应用用户可见文案的**唯一**来源（规格：语言体系统一）。
// 每键一个静态 AppText(Zh, En) 内联条目，取值一律经 Lang.Get / Lang.Format
// （跟随 LanguageService 三态偏好）。键名对齐 Swift AppText 已有键（refresh/settings/
// quitApp/loading/unknownError/languageTitle…），Windows 端新增键沿用 camelCase 风格。
// 不进本表的文案：Providers/Platform/Core 异常技术消息（日志与诊断用，UI 层经
// ClashErrorText 映射）、品牌名 "AI Quota Bar"、provider 名（GLM/MiniMax/Codex）。

namespace AIQuotaBar.App.Services;

/// <summary>应用文案字符串表（静态类 + 内联双语条目；带参键以 Format 结尾，占位符两语言一一对应）。</summary>
public static class AppStrings
{
    // ---- 通用（Swift 已有键直接沿用命名）----

    /// <summary>Swift refresh。</summary>
    public static readonly AppText Refresh = new("刷新", "Refresh");

    /// <summary>Swift settings。</summary>
    public static readonly AppText Settings = new("设置", "Settings");

    /// <summary>Swift quitApp（Windows 按钮为短文案）。</summary>
    public static readonly AppText QuitApp = new("退出", "Quit");

    /// <summary>Swift loading。</summary>
    public static readonly AppText Loading = new("加载中…", "Loading…");

    /// <summary>刷新动作进行中（按钮旁状态提示）。</summary>
    public static readonly AppText Refreshing = new("刷新中…", "Refreshing…");

    /// <summary>Swift unknownError。</summary>
    public static readonly AppText UnknownError = new("未知错误", "Unknown error");

    // ---- QuotaPanel（控制中心）----

    public static readonly AppText QuotaPanelTitle = new("AI Quota Bar — 配额概览", "AI Quota Bar — Quota overview");

    /// <summary>面板头部标题（主题终稿布局）。</summary>
    public static readonly AppText OverviewTitle = new("配额概览", "Overview");

    /// <summary>命令栏路由按钮（主题终稿布局）。</summary>
    public static readonly AppText RouteButton = new("路由", "Routes");

    /// <summary>命令栏左下提示（主题终稿布局）。</summary>
    public static readonly AppText PanelFooterHint =
        new("左键快速查看 · 右键更多命令", "Left-click for overview · right-click for more");

    /// <summary>“更新于 14:03:25”。</summary>
    public static readonly AppText UpdatedAtFormat = new("更新于 {0}", "Updated {0}");

    /// <summary>Swift percentLeft（“82.4% 剩余”）。</summary>
    public static readonly AppText PercentLeftFormat = new("{0:F1}% 剩余", "{0:F1}% left");

    /// <summary>Swift errorNotConfigured 的面板短状态。</summary>
    public static readonly AppText NotConfigured = new("未配置", "Not configured");

    /// <summary>Swift menuConfigureKeyHint 的面板按钮形态。</summary>
    public static readonly AppText GoConfigureCredentials = new("前往配置凭据 →", "Set up credentials →");

    /// <summary>无模型明细时的整体行（“整体 4/5”）。</summary>
    public static readonly AppText OverallFormat = new("整体 {0}/{1}", "Overall {0}/{1}");

    /// <summary>provider 状态“失败”标签（技术异常消息仍以小字另行展示）。</summary>
    public static readonly AppText Failed = new("失败", "Failed");

    /// <summary>模型行剩余百分比后缀（“（82%）”）。</summary>
    public static readonly AppText ModelPercentFormat = new("（{0}%）", " ({0}%)");

    // ---- RoutePanel（Clash 路由）----

    public static readonly AppText RoutePanelTitle = new("AI Quota Bar — 路由", "AI Quota Bar — Routes");

    public static readonly AppText ClashRoutesTitle = new("Clash 路由", "Clash routes");

    /// <summary>组头“GROUP · 当前 DIRECT”。</summary>
    public static readonly AppText GroupCurrentFormat = new("{0} · 当前 {1}", "{0} · Current {1}");

    /// <summary>切换成功后的“当前 {0}”。</summary>
    public static readonly AppText CurrentRouteFormat = new("当前 {0}", "Current {0}");

    public static readonly AppText TestButton = new("测速", "Test");

    public static readonly AppText Testing = new("测速中…", "Testing…");

    /// <summary>延迟徽章：0 = 超时。</summary>
    public static readonly AppText TimeoutBadge = new("超时", "Timeout");

    /// <summary>延迟徽章：null = 未测。</summary>
    public static readonly AppText UntestedBadge = new("未测", "n/a");

    public static readonly AppText SwitchFailedFormat = new("切换失败：{0}", "Switch failed: {0}");

    public static readonly AppText TestFailedFormat = new("测速失败：{0}", "Test failed: {0}");

    public static readonly AppText ControllerNotFound =
        new("未发现本机 Clash 控制器（安装 Clash Verge Rev 或检查 external-controller 配置）。",
            "No local Clash controller was found. Install Clash Verge Rev or check the external-controller setting.");

    /// <summary>未映射异常的兜底（技术消息随后文展示）。</summary>
    public static readonly AppText ClashRequestFailedFormat = new("Clash 请求失败：{0}", "Clash request failed: {0}");

    // ---- Clash 错误映射（Providers 异常 → 可操作提示；见 ClashErrorText）----

    public static readonly AppText ClashErrorExternalControllerDisabled = new(
        "Clash 已安装但外部控制未开启：打开 Clash Verge → 设置 → 开启「外部控制」。",
        "Clash is installed but its external controller is off: enable it in Clash Verge settings.");

    public static readonly AppText ClashErrorConfigurationNotFound = new(
        "未找到 Clash 配置文件：请确认本机已安装 Clash Verge Rev。",
        "Clash configuration was not found: make sure Clash Verge Rev is installed.");

    public static readonly AppText ClashErrorControllerUnavailable = new(
        "Clash 控制器不可达：请确认 Clash 正在运行，或稍后重试。",
        "The Clash controller is unreachable: make sure Clash is running, then retry.");

    public static readonly AppText ClashErrorUnsafeControllerHostFormat = new(
        "Clash 控制器未绑定本机地址（{0}）：请在 Clash 配置中把 external-controller 改为 127.0.0.1。",
        "The Clash controller is not bound to a local address ({0}): set external-controller to 127.0.0.1 in the Clash config.");

    public static readonly AppText ClashErrorInvalidControllerAddressFormat = new(
        "Clash 控制器地址无效：{0}",
        "Invalid Clash controller address: {0}");

    public static readonly AppText ClashErrorIncompatibleResponse = new(
        "Clash 返回了无法解析的响应（版本可能不兼容）。",
        "Clash returned a response that cannot be parsed (the version may be unsupported).");

    public static readonly AppText ClashErrorStrategyGroupNotFound = new(
        "未找到策略组：请检查 Clash 配置中的策略组。",
        "No proxy group was found: check the groups in the Clash config.");

    public static readonly AppText ClashErrorApiFailureFormat = new(
        "Clash API 请求失败（HTTP {0}）：{1}",
        "Clash API request failed (HTTP {0}): {1}");

    /// <summary>Swift errorNetwork 的带详情形态（HttpRequestException 兜底）。</summary>
    public static readonly AppText ErrorNetworkFormat = new("网络请求失败：{0}", "Network request failed: {0}");

    // ---- SettingsWindow ----

    public static readonly AppText SettingsTitle = new("AI Quota Bar — 设置", "AI Quota Bar — Settings");

    public static readonly AppText ThemeLabel = new("主题", "Theme");

    public static readonly AppText ThemeFollow = new("跟随系统", "Follow system");

    public static readonly AppText ThemeLight = new("亮色", "Light");

    public static readonly AppText ThemeDark = new("暗色", "Dark");

    /// <summary>Swift languageTitle。</summary>
    public static readonly AppText LanguageTitle = new("界面语言", "App language");

    public static readonly AppText LanguageFollow = new("跟随系统", "Follow system");

    public static readonly AppText LanguageChinese = new("中文", "Chinese");

    public static readonly AppText LanguageEnglish = new("English", "English");

    public static readonly AppText CredentialsSectionLabel = new("Provider 凭据", "Provider credentials");

    public static readonly AppText CredentialsHint = new(
        "凭据保存到 Windows 凭据管理器（Credential Manager），不明文落盘。GLM 支持 API key 或 cURL 导入串；MiniMax 填 API token。",
        "Credentials are stored in Windows Credential Manager, never on disk in plain text. GLM accepts an API key or an imported cURL string; MiniMax takes an API token.");

    public static readonly AppText GlmCredentialLabel = new("GLM 凭据", "GLM credential");

    public static readonly AppText MinimaxTokenLabel = new("MiniMax token", "MiniMax token");

    public static readonly AppText ProxyLabel = new(
        "网络代理（可选，如 http://10.0.0.181:7897）",
        "Web proxy (optional, e.g. http://10.0.0.181:7897)");

    /// <summary>Swift refreshInterval 的 Windows 输入框形态。</summary>
    public static readonly AppText RefreshIntervalLabel = new("刷新间隔（秒）", "Refresh interval (seconds)");

    /// <summary>Swift launchAtLogin 的勾选框形态。</summary>
    public static readonly AppText AutostartLabel = new(
        "开机自启（登录后静默启动，仅托盘图标，不弹面板）",
        "Launch at login (silent start: tray icon only, no panel)");

    /// <summary>Swift saveChanges。</summary>
    public static readonly AppText SaveButton = new("保存", "Save");

    public static readonly AppText CloseButton = new("关闭", "Close");

    /// <summary>Swift settingsSaved 的 Windows 带时间戳形态。</summary>
    public static readonly AppText SettingsSavedFormat = new(
        "已保存（{0}）。切换到控制中心点「刷新」立即生效。",
        "Saved ({0}). Open the control center and click Refresh to apply.");

    /// <summary>Swift apiKeySaveFailed 的整窗保存失败形态。</summary>
    public static readonly AppText SaveFailedFormat = new("保存失败：{0}", "Save failed: {0}");

    public static readonly AppText AutostartSaveFailedFormat = new(
        "开机自启设置失败：{0}",
        "Failed to apply the autostart setting: {0}");

    public static readonly AppText AutostartUnavailable = new(
        "开机自启不可用：安装路径不可用。",
        "Autostart is unavailable: the install path cannot be resolved.");

    // ---- 托盘 ----

    public static readonly AppText TrayOpenQuota = new("配额概览", "Quota overview");

    public static readonly AppText TrayOpenRoutes = new("Clash 路由…", "Clash routes…");

    public static readonly AppText TrayRefreshNow = new("立即刷新", "Refresh now");

    public static readonly AppText TrayLaunchAtLogin = new("登录 Windows 时启动", "Launch at login");

    public static readonly AppText TraySettings = new("设置…", "Settings…");

    public static readonly AppText TrayExit = new("退出 AI Quota Bar", "Exit AI Quota Bar");

    public static readonly AppText ThemeSaveFailedFormat = new(
        "主题偏好保存失败：{0}",
        "Failed to save the theme preference: {0}");

    /// <summary>未配置任何 provider 时的 tooltip 摘要。</summary>
    public static readonly AppText TrayNotConfiguredSummary = new(
        "AI Quota Bar（未配置 — 左键打开设置）",
        "AI Quota Bar (not configured — click to open settings)");

    /// <summary>顶层未处理异常气泡。</summary>
    public static readonly AppText ExceptionBalloonFormat = new("发生异常：{0}", "An error occurred: {0}");
}
