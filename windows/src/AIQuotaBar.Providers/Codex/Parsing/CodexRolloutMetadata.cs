// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/AgentSession.swift
//   （CodexRolloutFirstLineParser.parse：session_meta 首行提取；契约样本：local-session-rollout.jsonl）

#nullable enable

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// rollout 首行 session_meta 摘要（Swift: CodexRolloutMetadata 的 Codex 消费子集）。
/// 供本地活动检测（后续阶段）识别会话；解析器只读首行，后续任意行不得使解析失败。
/// </summary>
public sealed record CodexRolloutMetadata(
    string SessionId,
    string? Cwd,
    string? Originator,
    string? Source);
