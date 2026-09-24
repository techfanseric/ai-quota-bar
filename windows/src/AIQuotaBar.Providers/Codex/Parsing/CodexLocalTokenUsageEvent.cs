// Swift 来源：Sources/CodexLocalUsageCore/UsageModels.swift（struct LocalUsageEvent；
//   id 的 SHA-256 摘要与 accountID 哈希裁剪——W1-E 只需关键字段，去重签名由
//   CodexLocalTokenUsageResult 层保留）

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 会话文件里一条去重后的 token_count 事件（Swift: LocalUsageEvent 的消费子集）。
/// </summary>
/// <param name="Timestamp">事件时间（行内 timestamp，ISO 8601）。</param>
/// <param name="Model">turn_context / info.model 的模型名（小写归一；缺失为 "unknown"）。</param>
/// <param name="LimitId">rate_limits.limit_id；缺失为 "default"。参与去重。</param>
/// <param name="Tokens">last_token_usage 优先；否则 total_token_usage 的累计差值。</param>
/// <param name="Quality">"exact"（last）或 "cumulative-delta"（total 差值）。</param>
public sealed record CodexLocalTokenUsageEvent(
    DateTimeOffset Timestamp,
    string Model,
    string LimitId,
    CodexTokenUsageCounters Tokens,
    string Quality);
