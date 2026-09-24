# windows/contracts/fixtures — Provider API 契约 Fixture 政策

本目录是 AI Quota Bar Windows（C#）移植的契约测试 fixture 种子库，覆盖 Codex / Kimi / GLM / MiniMax / Clash 五个 provider。每个样本的来源、端点与建议断言要点见 [MANIFEST.md](MANIFEST.md)。

## 政策

1. **只有真实流量是权威契约。** provider API 的字段语义、类型双形态（字符串/数字）、时间戳精度、可选字段缺失行为，最终必须以 macOS 实机上抓到的真实请求/响应为准。真实流量与 test-synthesized 样本冲突时，以真实流量为准并修正或删除合成样本。
2. **[test-synthesized] 样本仅作过渡。** 当前全部样本提取自 Swift 测试内嵌 JSON 与 codexbar fixture 文件：字段结构可信（与解析器代码同步演化），但数值是测试合成值，不能证明服务端今天仍返回该形态。它们用于 C# 解析器的先行开发与回归保护，不构成对外承诺。
3. **真实流量录制为 TODO（最高优先级缺口）。** 在 macOS 实机上运行原生 AIQuotaBar / codexbar，通过 mitmproxy（或 Charles/Proxyman）抓取下列端点，脱敏后以 `[real-traffic]` 标签入库，与合成样本并列或替换：
   - Codex：`chatgpt.com/backend-api/wham/usage`、`/wham/rate-limit-reset-credits`、`/remaining_balance`、PAT `whoami`；本机 `~/.codex/auth.json`、`sessions/*.jsonl` 直接脱敏拷贝。
   - Kimi：`www.kimi.com(/.ai)/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`、`MembershipService/GetSubscriptionStats`；CLI `/status` 输出、Desktop `token-store.json`。
   - GLM：`bigmodel.cn/api/monitor/usage/quota/limit`（web 会话与 open.bigmodel.cn API Key 两种）、`/api/biz/customer-package-reset/list`。
   - MiniMax：`platform.minimax.io(/i.com)/v1/token_plan/remains` 与 `v1/api/openplatform/coding_plan/remains`。
   - Clash：本机 `127.0.0.1:9097` 的 `/connections`（REST 与 WebSocket 帧）、`/version`、`/proxies`、`/rules`。
4. **不新增来源不明的样本。** 每个样本必须在 MANIFEST.md 登记来源路径与行号；无法溯源的字段值一律不得入库。
5. **目录职责单一。** 本目录只放 fixture 与政策文档，不放 C# 测试代码（测试代码归 `windows/tests/`），不放各 provider 的移植实现（归 `windows/src/`）。

## 敏感值政策

- 测试占位值（`fixture-token`、`pat@example.com` 等）原样保留。
- 真实流量录制中出现的 token / Cookie / 邮箱 / 会话 ID / 账号 ID，入库前替换为 `<REDACTED-token>`、`<REDACTED-email>`、`<REDACTED-session-id>`、`<REDACTED-account-id>` 等占位，并在 MANIFEST.md 对应行标注脱敏字段。加密信封（如 Kimi safeStorage blob）整段替换为 `<REDACTED-encrypted-blob>` 并保留结构说明。
- 采录时已核查现存样本，未发现真实凭据，故未执行替换（详见 MANIFEST.md 末尾核查记录）。

## 仍缺真实流量样本的 Provider（当前全部待录）

| Provider | 现有 test-synthesized 样本 | 真实流量样本 | 额外缺口 |
| --- | --- | --- | --- |
| Codex | 16 | 0 — 待录 | OAuth 刷新（token refresh）响应无任何样本；OpenAI 网页 dashboard HTML（openai-web 来源）未采 |
| Kimi | 12 | 0 — 待录 | 401/429 错误响应体被 Swift 端刻意不落盘（防泄漏），录制时只需记录状态码契约 |
| GLM | 9 | 0 — 待录 | 旧版辅助端点 `/api/biz/subscription/list` 无样本；TEAM scope 的 reset-allowances 拒绝形态仅由 PERSONAL 改写测试覆盖 |
| MiniMax | 2 | 0 — 待录 | AIQuotaBar 本体无 MiniMax 用量拉取实现；HTML coding-plan 页面解析（codexbar 有 `pro-normal.html` 同类先例）未采；`remains_time` 字段仅见于 docs/api-field-mapping.md 文档，两个 JSON 样本中均未出现该字段 |
| Clash | 2 | 0 — 待录 | `/version`、`/proxies`、`/rules` 三个端点连 test-synthesized 样本都没有（Swift 测试用结构体构造，无 JSON）；Windows 端对应解析器必须先补样本或等待实机录制 |

## 采录范围说明

- 样本来源仅限仓库内只读资产：`AIQuotaBar/Tests/` 内嵌 JSON、`.dependencies/codexbar/` 的测试 fixture、`docs/` 三份字段映射文档（api-field-mapping.md、glm-api-field-mapping.md、codex-local-usage.md）用于字段语义校对。
- 少量非 JSON 线格式按原格式保存：Kimi CLI `/status` 文本（`.txt`）、Codex 本地会话与 Kimi wire（`.jsonl`）、Clash Verge 配置（`.yaml`）。它们与 JSON 样本同等受本政策约束。
