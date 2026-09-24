// Swift 来源：
//   - .dependencies/codexbar/Sources/CodexBarCore/AgentSession.swift（CodexRolloutFirstLineParser：
//     只读首行 session_meta；session_id ?? id、cwd、originator、source）
//   - Sources/CodexLocalUsageCore/UsageParser.swift（State.line 的 token_count 分支：
//     last 优先 / total 累计差值、签名去重（signatures[source] + previousSignature）、limit_id）
//   契约样本：local-session-rollout.jsonl、local-session-token-usage.jsonl
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexLocalRolloutReaderTests.cs
//
// 最小实现边界（供后续活动检测阶段扩展）：fork 前缀剔除（resolve）、归档/分页去重、
// 持久化 outbox 均不在此实现。

#nullable enable

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 本地 Codex 会话文件读取（rollout.jsonl 首行元数据 + token-usage 事件流）。
/// 逐行 JSON、单行畸形只计数不失败。
/// </summary>
public static class CodexLocalRolloutReader
{
    private const int FirstLineReadLimitBytes = 256 * 1024;

    // ------------------------------------------------------------------
    // session_meta（rollout 首行）。
    // ------------------------------------------------------------------

    /// <summary>
    /// 解析单行 session_meta（Swift: CodexRolloutFirstLineParser.parse）。type != "session_meta"、
    /// 缺 session_id/id 或非 JSON → null（不抛出）。
    /// </summary>
    public static CodexRolloutMetadata? ParseSessionMeta(string line)
    {
        JsonElement root;
        try
        {
            using var document = JsonDocument.Parse(line);
            root = document.RootElement.Clone();
        }
        catch (JsonException)
        {
            return null;
        }

        if (root.ValueKind != JsonValueKind.Object ||
            CodexJson.String(root, "type") != "session_meta" ||
            !root.TryGetProperty("payload", out var payload) ||
            payload.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var sessionId = CodexJson.String(payload, "session_id") ?? CodexJson.String(payload, "id");
        if (sessionId is null)
        {
            return null;
        }

        return new CodexRolloutMetadata(
            SessionId: sessionId,
            Cwd: CodexJson.String(payload, "cwd"),
            Originator: CodexJson.String(payload, "originator"),
            Source: CodexJson.String(payload, "source"));
    }

    /// <summary>
    /// 只读文件首行（至多 256 KiB，Swift 同上限）并按 session_meta 解析；文件不可读 → null。
    /// </summary>
    public static async Task<CodexRolloutMetadata?> ReadSessionMetaAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        string? firstLine;
        try
        {
            firstLine = await ReadFirstLineAsync(path, cancellationToken).ConfigureAwait(false);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }

        return firstLine is null ? null : ParseSessionMeta(firstLine);
    }

    private static async Task<string?> ReadFirstLineAsync(string path, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var builder = new List<byte>();
        var buffer = new byte[1];
        while (builder.Count < FirstLineReadLimitBytes)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(0, 1), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            if (buffer[0] == (byte)'\n')
            {
                break;
            }

            builder.Add(buffer[0]);
        }

        if (builder.Count == 0)
        {
            return null;
        }

        return System.Text.Encoding.UTF8.GetString(builder.ToArray());
    }

    // ------------------------------------------------------------------
    // token-usage 事件流。
    // ------------------------------------------------------------------

    /// <summary>
    /// 逐行解析 token-usage 会话文件（Swift: UsageParser.parse）。行为镜像（最小子集）：
    /// 首条 session_meta 记会话 ID/时间；turn_context 记模型；event_msg.token_count 事件
    /// last_token_usage 优先，否则 total_token_usage 相对上一次的差值；同 limit_id 内签名
    /// 重复、或与上一条任意来源签名相同的事件去重（相同时间戳不同 limit_id 不去重）。
    /// </summary>
    public static async Task<CodexLocalTokenUsageResult> ReadTokenUsageAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        string content;
        try
        {
            content = await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false);
        }
        catch (FileNotFoundException)
        {
            return new CodexLocalTokenUsageResult(null, null, Array.Empty<CodexLocalTokenUsageEvent>(), 0);
        }
        catch (DirectoryNotFoundException)
        {
            return new CodexLocalTokenUsageResult(null, null, Array.Empty<CodexLocalTokenUsageEvent>(), 0);
        }

        return ReadTokenUsage(SplitLines(content));
    }

    /// <summary>同 <see cref="ReadTokenUsageAsync"/>，从行集合解析（测试直用）。</summary>
    public static CodexLocalTokenUsageResult ReadTokenUsage(IEnumerable<string> lines)
    {
        var state = new TokenUsageState();
        foreach (var line in lines)
        {
            state.ProcessLine(line);
        }

        return state.ToResult();
    }

    private static IEnumerable<string> SplitLines(string content)
    {
        using var reader = new StringReader(content);
        while (reader.ReadLine() is { } line)
        {
            yield return line;
        }
    }

    /// <summary>Swift: UsageParser.State（token_count 相关子集，internal）。</summary>
    private sealed class TokenUsageState
    {
        private readonly List<CodexLocalTokenUsageEvent> _events = new();
        private string _model = "unknown";
        private CodexTokenUsageCounters? _previousTotal;
        private readonly Dictionary<string, string> _signaturesBySource = new();
        private string? _previousSignature;
        private string? _sessionId;
        private DateTimeOffset? _startedAt;
        private bool _metaSeen;
        private int _issues;

        public void ProcessLine(string line)
        {
            if (line.Length == 0)
            {
                return;
            }

            // 大部分 rollout 字节是会话/工具正文；先做廉价的首字符与子串预筛（Swift 同策略）。
            var first = line[0];
            if (first != '{' && first != ' ')
            {
                _issues++;
                return;
            }

            if (!line.Contains("\"session_meta\"", StringComparison.Ordinal) &&
                !line.Contains("\"turn_context\"", StringComparison.Ordinal) &&
                !line.Contains("\"token_count\"", StringComparison.Ordinal))
            {
                return;
            }

            JsonElement root;
            try
            {
                using var document = JsonDocument.Parse(line);
                root = document.RootElement.Clone();
            }
            catch (JsonException)
            {
                _issues++;
                return;
            }

            if (root.ValueKind != JsonValueKind.Object ||
                CodexJson.String(root, "type") is not { } type ||
                !root.TryGetProperty("payload", out var payload) ||
                payload.ValueKind != JsonValueKind.Object)
            {
                _issues++;
                return;
            }

            switch (type)
            {
                case "session_meta":
                    ProcessSessionMeta(root, payload);
                    return;
                case "turn_context":
                    ProcessTurnContext(payload);
                    return;
                default:
                    if (type == "event_msg")
                    {
                        ProcessTokenCount(root, payload);
                    }

                    return;
            }
        }

        private void ProcessSessionMeta(JsonElement root, JsonElement payload)
        {
            if (_metaSeen)
            {
                return;
            }

            _metaSeen = true;
            _sessionId = CodexJson.String(payload, "id", "thread_id", "threadId");
            _startedAt = CodexJson.Iso8601(CodexJson.String(root, "timestamp"));
        }

        private void ProcessTurnContext(JsonElement payload)
        {
            if (CodexJson.String(payload, "model") is { } model)
            {
                _model = model;
            }
        }

        private void ProcessTokenCount(JsonElement root, JsonElement payload)
        {
            if (CodexJson.String(payload, "type") != "token_count" ||
                !payload.TryGetProperty("info", out var info) ||
                info.ValueKind != JsonValueKind.Object)
            {
                return;
            }

            var total = ParseCounters(info, "total_token_usage");
            var last = ParseCounters(info, "last_token_usage");

            var lastWasObject = info.TryGetProperty("last_token_usage", out var lastElement) &&
                lastElement.ValueKind == JsonValueKind.Object;
            var totalWasObject = info.TryGetProperty("total_token_usage", out var totalElement) &&
                totalElement.ValueKind == JsonValueKind.Object;
            if ((lastWasObject && last is null) || (totalWasObject && total is null))
            {
                _issues++;
                return;
            }

            if (total is null && last is null)
            {
                _issues++;
                return;
            }

            var signature = $"{total?.Signature ?? "-"}/{last?.Signature ?? "-"}";
            var limitId = payload.TryGetProperty("rate_limits", out var rateLimits) &&
                rateLimits.ValueKind == JsonValueKind.Object
                    ? CodexJson.String(rateLimits, "limit_id") ?? "default"
                    : "default";

            var duplicate = total is not null &&
                (_signaturesBySource.TryGetValue(limitId, out var sourceSignature) &&
                    sourceSignature == signature || _previousSignature == signature);
            if (total is not null)
            {
                _signaturesBySource[limitId] = signature;
            }

            _previousSignature = signature;

            CodexTokenUsageCounters? tokens = null;
            var quality = "exact";
            if (last is { } lastCounters)
            {
                tokens = lastCounters;
            }
            else if (total is { } totalCounters)
            {
                quality = "cumulative-delta";
                if (_previousTotal is { } previous)
                {
                    // 无 last_token_usage 时重置语义有歧义：记问题并重建基线（Swift 同策略）。
                    if (totalCounters.Input < previous.Input ||
                        totalCounters.Output < previous.Output ||
                        totalCounters.Cached < previous.Cached ||
                        totalCounters.CacheWrite < previous.CacheWrite ||
                        totalCounters.Reasoning < previous.Reasoning)
                    {
                        _issues++;
                    }
                    else
                    {
                        tokens = new CodexTokenUsageCounters(
                            Input: totalCounters.Input - previous.Input,
                            Cached: totalCounters.Cached - previous.Cached,
                            CacheWrite: totalCounters.CacheWrite - previous.CacheWrite,
                            Output: totalCounters.Output - previous.Output,
                            Reasoning: totalCounters.Reasoning - previous.Reasoning);
                    }
                }
                else
                {
                    tokens = totalCounters;
                }
            }

            if (total is not null)
            {
                _previousTotal = total;
            }

            if (duplicate || tokens is not { Total: > 0 })
            {
                return;
            }

            if (!tokens.IsValid ||
                string.IsNullOrEmpty(_sessionId) ||
                CodexJson.Iso8601(CodexJson.String(root, "timestamp")) is not { } timestamp)
            {
                _issues++;
                return;
            }

            var normalizedModel = _model.Trim().ToLowerInvariant();
            _events.Add(new CodexLocalTokenUsageEvent(
                Timestamp: timestamp,
                Model: normalizedModel.Length == 0 ? "unknown" : normalizedModel,
                LimitId: limitId,
                Tokens: tokens,
                Quality: quality));
        }

        private static CodexTokenUsageCounters? ParseCounters(JsonElement info, string key)
        {
            if (!info.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            if (value.TryGetProperty("input_tokens", out var inputElement) &&
                inputElement.ValueKind == JsonValueKind.Null)
            {
                return null;
            }

            var input = ParseCount(value, "input_tokens");
            var cached = ParseCount(value, "cached_input_tokens");
            var cacheWrite = ParseCount(value, "cache_write_input_tokens");
            var output = ParseCount(value, "output_tokens");
            var reasoning = ParseCount(value, "reasoning_output_tokens");

            // input/output 必填；其余字段缺失按 0（Swift: n(key) 缺省 0）。
            if (input is null || output is null ||
                cached is null || cacheWrite is null || reasoning is null)
            {
                return null;
            }

            var counters = new CodexTokenUsageCounters(input.Value, cached.Value, cacheWrite.Value, output.Value, reasoning.Value);
            return counters.IsValid ? counters : null;
        }

        private static long? ParseCount(JsonElement value, string key)
        {
            if (!value.TryGetProperty(key, out var element))
            {
                return 0;
            }

            if (element.ValueKind != JsonValueKind.Number)
            {
                return null;
            }

            // 必须是有限整数值（Swift: doubleValue.rounded() == doubleValue 且值域校验）。
            var parsed = element.GetDouble();
            if (!double.IsFinite(parsed) ||
                Math.Truncate(parsed) != parsed ||
                parsed < 0 ||
                parsed > CodexTokenUsageCounters.MaxTokenCount)
            {
                return null;
            }

            return (long)parsed;
        }

        public CodexLocalTokenUsageResult ToResult() =>
            new(_sessionId, _startedAt, _events, _issues);
    }
}
