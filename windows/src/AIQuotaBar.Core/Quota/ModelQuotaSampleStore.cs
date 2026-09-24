// Swift 来源：AIQuotaBar/Services/ModelQuotaSampleStore.swift — final class ModelQuotaSampleStore
// （load/save/clearAll、按 provider 拆分/合并、schema 版本守卫）；以及
// AIQuotaBar/ViewModels/UsageViewModel.swift 的曲线样本保留策略
// （quotaSampleRetention = 90 天、maxSamplesPerModel = 30_000、prunedQuotaSamples(_:now:)）。
// 注意：任务书提到的 "2200 条上限" 属于 utilization history
// （Contracts/UsageHistory.cs 的 ModelUtilizationHistory.MaxEntriesPerModel），不在本 store；
// 曲线样本的上限是 maxSamplesPerModel = 30_000，按 Swift 实现移植。
// JSON 持久化统一走 Contracts 的 QuotaJson.Default（camelCase + Swift .iso8601 日期）。
// 与 Swift 的差异：目录路径经构造函数注入（无 shared 单例、不探查 Application Support —
// 那是 Platform 层职责）；I/O 一律 async Task（编码规范 §3）。
// 对应测试：AIQuotaBar/Tests/ModelQuotaSampleStoreTests.swift

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// 当前窗口曲线样本持久化（含 Weekly fallback 曲线）。按 provider 分文件存
/// {directory}/{provider}.json，内容为 { version, samples }（samples 按 quota identity 键）。
/// 加载 best-effort：文件缺失/损坏/版本过新 → 返回空（Swift try? 语义）。
/// </summary>
public sealed class ModelQuotaSampleStore
{
    private const int CurrentSchemaVersion = 1;

    private readonly string _directoryPath;

    /// <param name="directoryPath">样本目录（Swift 测试专用 init 的 directoryURL 注入同构）。</param>
    public ModelQuotaSampleStore(string directoryPath)
    {
        _directoryPath = directoryPath;
    }

    /// <summary>Swift: fileURL(for:)。文件名 = provider rawValue + ".json"。</summary>
    public string FileFor(UsageProvider provider) =>
        Path.Combine(_directoryPath, provider.RawValue() + ".json");

    /// <summary>
    /// 加载全部 provider 的样本并按 modelId 合并（同 key 按 timestamp 去重，后加载覆盖）。
    /// Swift: loadAll()。
    /// </summary>
    public async Task<IReadOnlyDictionary<string, IReadOnlyList<ModelQuotaSample>>> LoadAllAsync(
        CancellationToken cancellationToken = default)
    {
        var result = new Dictionary<string, IReadOnlyList<ModelQuotaSample>>();
        foreach (var provider in UsageProviders.All)
        {
            var loaded = await LoadAsync(provider, cancellationToken);
            foreach (var (modelId, samples) in loaded)
            {
                result[modelId] = result.TryGetValue(modelId, out var existing)
                    ? MergeSamples(existing, samples)
                    : samples;
            }
        }

        return result;
    }

    /// <summary>加载单个 provider 的样本；任何失败都返回空（Swift: load(for:) 的 try? 链）。</summary>
    public async Task<IReadOnlyDictionary<string, IReadOnlyList<ModelQuotaSample>>> LoadAsync(
        UsageProvider provider,
        CancellationToken cancellationToken = default)
    {
        var path = FileFor(provider);
        if (!File.Exists(path))
        {
            return Empty();
        }

        try
        {
            var json = await File.ReadAllTextAsync(path, cancellationToken);
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return Empty();
            }

            var fileVersion = 0;
            if (document.RootElement.TryGetProperty("version", out var versionElement) &&
                versionElement.ValueKind == JsonValueKind.Number &&
                versionElement.TryGetInt32(out var parsedVersion))
            {
                fileVersion = parsedVersion;
            }

            if (fileVersion > CurrentSchemaVersion)
            {
                return Empty();
            }

            var payload = JsonSerializer.Deserialize<StoreFile>(json, QuotaJson.Default);
            if (payload?.Samples is null)
            {
                return Empty();
            }

            var result = new Dictionary<string, IReadOnlyList<ModelQuotaSample>>(payload.Samples.Count);
            foreach (var (modelId, samples) in payload.Samples)
            {
                result[modelId] = samples.ToList();
            }

            return result;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Swift：JSONSerialization/decode 任一步失败都静默返回空（best-effort 加载）。
            return Empty();
        }
    }

    /// <summary>按 provider 拆分后逐个保存。Swift: saveAll(_:)。</summary>
    public async Task SaveAllAsync(
        IReadOnlyDictionary<string, IReadOnlyList<ModelQuotaSample>> samples,
        CancellationToken cancellationToken = default)
    {
        foreach (var provider in UsageProviders.All)
        {
            await SaveAsync(SamplesFor(samples, provider), provider, cancellationToken);
        }
    }

    /// <summary>保存单个 provider 的样本；失败仅吞掉（Swift save 只在 DEBUG print，不通知）。</summary>
    public async Task SaveAsync(
        IReadOnlyDictionary<string, IReadOnlyList<ModelQuotaSample>> samples,
        UsageProvider provider,
        CancellationToken cancellationToken = default)
    {
        try
        {
            Directory.CreateDirectory(_directoryPath);
            var payload = new StoreFile(
                Version: CurrentSchemaVersion,
                Samples: samples.ToDictionary(
                    static pair => pair.Key,
                    static pair => pair.Value.ToList()));
            var json = JsonSerializer.Serialize(payload, QuotaJson.Default);
            await AtomicFileWriter.WriteAsync(FileFor(provider), json, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // best-effort 持久化：保存失败不打断刷新流程（与 Swift 行为一致，无通知通道）。
        }
    }

    /// <summary>删除全部 provider 的样本文件。Swift: clearAll()。</summary>
    public Task ClearAllAsync(CancellationToken cancellationToken = default)
    {
        // 删除是纯元数据操作（Swift 同步 removeItem），无需异步内核调用。
        cancellationToken.ThrowIfCancellationRequested();
        foreach (var provider in UsageProviders.All)
        {
            var path = FileFor(provider);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }

        return Task.CompletedTask;
    }

    // ------------------------------------------------------------------ 曲线样本保留策略
    // Swift 来源：AIQuotaBar/ViewModels/UsageViewModel.swift（static let / static func）。

    /// <summary>按年龄保留的窗口：90 天（Swift: quotaSampleRetention = 90 * 86_400 秒）。</summary>
    public static readonly TimeSpan QuotaSampleRetention = TimeSpan.FromDays(90);

    /// <summary>单 model 样本条数上限（Swift: maxSamplesPerModel = 30_000；超出丢最旧）。</summary>
    public const int MaxSamplesPerModel = 30_000;

    /// <summary>
    /// 曲线样本本地保留策略：按年龄保留 <see cref="QuotaSampleRetention"/>（90 天），
    /// 并按 <see cref="MaxSamplesPerModel"/> 封顶，超出丢最旧。
    /// Swift: UsageViewModel.prunedQuotaSamples(_:now:)（纯函数，放本类便于 Core 复用与测试）。
    /// </summary>
    public static IReadOnlyList<ModelQuotaSample> PrunedQuotaSamples(
        IReadOnlyList<ModelQuotaSample> samples,
        DateTimeOffset now)
    {
        var cutoff = now - QuotaSampleRetention;
        var result = samples
            .Where(sample => sample.Timestamp >= cutoff)
            .OrderBy(static sample => sample.Timestamp)
            .ToList();
        if (result.Count > MaxSamplesPerModel)
        {
            result.RemoveRange(0, result.Count - MaxSamplesPerModel);
        }

        return result;
    }

    // ------------------------------------------------------------------ 私有辅助

    // Swift private static samples(_:for:)：key 是 provider 本身或以 "provider:" 开头（quota identity）。
    private static Dictionary<string, IReadOnlyList<ModelQuotaSample>> SamplesFor(
        IReadOnlyDictionary<string, IReadOnlyList<ModelQuotaSample>> samples,
        UsageProvider provider)
    {
        var prefix = provider.RawValue() + ":";
        return samples
            .Where(pair => pair.Key == provider.RawValue() || pair.Key.StartsWith(prefix, StringComparison.Ordinal))
            .ToDictionary(static pair => pair.Key, static pair => pair.Value);
    }

    // Swift private static mergedSamples(_:_:)：按 timestamp（Swift id）去重，rhs 覆盖 lhs，再按时间升序。
    private static IReadOnlyList<ModelQuotaSample> MergeSamples(
        IReadOnlyList<ModelQuotaSample> lhs,
        IReadOnlyList<ModelQuotaSample> rhs)
    {
        var byTimestamp = new Dictionary<DateTimeOffset, ModelQuotaSample>();
        foreach (var sample in lhs)
        {
            byTimestamp[sample.Timestamp] = sample;
        }

        foreach (var sample in rhs)
        {
            byTimestamp[sample.Timestamp] = sample;
        }

        return byTimestamp.Values.OrderBy(static sample => sample.Timestamp).ToList();
    }

    private static Dictionary<string, IReadOnlyList<ModelQuotaSample>> Empty() => new();

    /// <summary>磁盘文件内容（Swift private struct StoreFile）。samples 为 null 时序列化省略（Swift encodeIfPresent）。</summary>
    private sealed record StoreFile(int Version, Dictionary<string, List<ModelQuotaSample>>? Samples);
}
