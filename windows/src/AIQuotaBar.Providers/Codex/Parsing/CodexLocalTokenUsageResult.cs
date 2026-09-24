// Swift 来源：Sources/CodexLocalUsageCore/UsageParser.swift（仓库根 Sources/ 的 App 自有 target
//   CodexLocalUsageCore——非 .dependencies/codexbar；struct ParsedUsageFile 的消费子集）
//   —— 最小实现：会话 ID + 去重后事件 + 问题计数；fork/归档合并（resolve）属后续阶段。

#nullable enable

using System;
using System.Collections.Generic;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>token-usage.jsonl 的解析结果（Swift: ParsedUsageFile 的最小子集）。</summary>
/// <param name="SessionId">首条 session_meta 的会话 ID（payload.id ?? thread_id ?? threadId）。</param>
/// <param name="StartedAt">首条 session_meta 的 timestamp。</param>
/// <param name="Events">去重后的 token_count 事件（按出现顺序）。</param>
/// <param name="Issues">畸形行计数（解析器不因单行畸形失败）。</param>
public sealed record CodexLocalTokenUsageResult(
    string? SessionId,
    DateTimeOffset? StartedAt,
    IReadOnlyList<CodexLocalTokenUsageEvent> Events,
    int Issues);
