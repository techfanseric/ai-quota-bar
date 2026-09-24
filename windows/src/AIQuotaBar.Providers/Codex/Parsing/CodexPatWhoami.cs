// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexPAT/CodexPATUsageFetcher.swift
//   （struct CodexPATWhoami + WhoamiResponse；契约样本：whoami-response-pat.json）

#nullable enable

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// PAT whoami 响应（Swift: CodexPATWhoami）。字段 trim 后空白视为 null；
/// chatgpt_account_id 需回填后续 usage 请求的 ChatGPT-Account-Id 头。
/// </summary>
public sealed record CodexPatWhoami(
    string? AccountId,
    string? Email,
    string? PlanType);
