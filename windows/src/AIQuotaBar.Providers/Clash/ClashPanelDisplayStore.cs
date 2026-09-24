// Swift 来源：AIQuotaBar/Services/Clash/ClashPanelDisplayStore.swift — @MainActor @Observable ClashPanelDisplayStore（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashPanelDisplayStoreTests.swift
//
// 持久化差异：Swift 存 UserDefaults（JSON blob，键 clashPanelDisplayPreferences）；
// Windows 端改为注入路径的 JSON 文件（Swift raw value "routes"/"connections" 编解码）。
// 说明：构造函数与写回为同步小文件 IO（构造函数无法 async，Swift init 同步语义一致），
// 是 Providers 层 async 规范（coding-conventions §3）的显式例外；App 层接管时可改为
// 注入 IPreferenceStore 异步化。

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// 右键面板两个 OpenAI 分区（routes / connections）的折叠状态：
/// 「跟随运行中的应用」开启时由 Codex 运行状态自动对齐；用户手动点击写入同一集合，
/// 最后一次操作生效；面板重开与 App 重启后保持。
/// </summary>
public sealed class ClashPanelDisplayStore
{
    public const string StorageKey = "clashPanelDisplayPreferences";

    private readonly string _filePath;

    public ClashPanelDisplayStore(string filePath)
    {
        _filePath = filePath;
        CollapsedSections = LoadCollapsedSections(filePath);
    }

    public IReadOnlySet<ClashPanelSection> CollapsedSections { get; private set; }

    public bool IsRoutesCollapsed => CollapsedSections.Contains(ClashPanelSection.Routes);

    public bool IsConnectionsCollapsed => CollapsedSections.Contains(ClashPanelSection.Connections);

    /// <summary>用户手动点击分区标题，或自动对齐写入；变化时持久化。</summary>
    public void SetCollapsed(bool collapsed, ClashPanelSection section)
    {
        var updated = new HashSet<ClashPanelSection>(CollapsedSections);
        if (collapsed)
        {
            updated.Add(section);
        }
        else
        {
            updated.Remove(section);
        }

        if (updated.SetEquals(CollapsedSections))
        {
            return;
        }

        CollapsedSections = updated;
        Persist();
    }

    public void Toggle(ClashPanelSection section)
    {
        SetCollapsed(!CollapsedSections.Contains(section), section);
    }

    /// <summary>跟随运行中的应用开启时，把两段对齐到 Codex 的运行状态；跟随关闭时不做任何自动变动。</summary>
    public void AlignWithCodexPresence(bool isRunning, bool followRunningAppsEnabled)
    {
        if (!followRunningAppsEnabled)
        {
            return;
        }

        SetCollapsed(!isRunning, ClashPanelSection.Routes);
        SetCollapsed(!isRunning, ClashPanelSection.Connections);
    }

    private static IReadOnlySet<ClashPanelSection> LoadCollapsedSections(string filePath)
    {
        try
        {
            if (File.Exists(filePath))
            {
                var data = File.ReadAllText(filePath);
                return JsonSerializer.Deserialize<HashSet<ClashPanelSection>>(data, QuotaJson.Default)
                    ?? new HashSet<ClashPanelSection>();
            }
        }
        catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
        {
            // 损坏/不可读的偏好文件视作空集合（Swift 解码失败同样回退空集）。
        }

        return new HashSet<ClashPanelSection>();
    }

    private void Persist()
    {
        try
        {
            var directory = Path.GetDirectoryName(Path.GetFullPath(_filePath));
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(_filePath, JsonSerializer.Serialize(CollapsedSections, QuotaJson.Default));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Swift 端 UserDefaults set 失败同样被吞掉；保持静默。
        }
    }
}
