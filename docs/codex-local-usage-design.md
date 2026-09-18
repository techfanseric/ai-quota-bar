# Codex 本机用量、成员归属与团队上报方案

日期：2026-09-17。此文保留初始设计；实现及验证说明见 [codex-local-usage.md](codex-local-usage.md)。生产部署尚未执行。

## 结论

新增独立的本机用量采集链路，以 Codex 本地 JSONL 中的用量事件作为来源，按成员、设备、模型和时间汇总。保留现有账号额度展示用于判断剩余容量，但不能以额度下降量推算个人贡献，也不能把多个设备读到的同一账号额度相加。

默认首页展示“我的本机用量”；团队视图展示成员汇总，可展开设备。一位成员可绑定多台设备，一个共享 Codex 账号可关联多位成员。账号身份与成员身份必须分开。

## 已验证的现状

- ai-quota-bar 已克隆，基线提交 `de876b2b125c29f7c061cc8f2eab281ae31ba447`。
- `AIQuotaBar/Services/Codex/CodexService.swift` 经 CodexBarCore 获取账号额度，而且 Codex App 未运行时会跳过；本机历史采集应独立运行，不能依赖此成功条件。
- `AIQuotaBar/Services/CloudSyncService.swift` 已有 deviceID、失败重试及状态展示；`CloudSyncQueue.swift` 提供持久化队列，但现有 payload 专用于额度快照，需新增用量队列类型或独立 outbox。
- `cloudflare/schema.sql` 目前是 devices、quota_samples、settings，没有成员与实际 token 事件表。`cloudflare/src/worker.js` 的账号汇总逻辑也不是个人消耗统计。
- 当前 Worker 使用共享 Bearer token；客户端内有默认服务凭据。成员归属不能只相信请求 body 里的 memberID，否则任何持有共享凭据的客户端都能冒充其他成员。团队上报需新增服务端设备注册和身份绑定，避免继续扩大共享凭据的权限。
- 本机 sessions 目录找到 1,210 个 JSONL 文件。仅抽样最近 8 个文件，发现 248 条 token_count 事件，均有 total_token_usage 和 last_token_usage。该结果验证格式可用，不代表已完成全量统计。
- 抽样字段包含 input_tokens、cached_input_tokens、cache_write_input_tokens、output_tokens、reasoning_output_tokens、total_tokens；未导出对话文本、提示词、工具参数或凭据。
- 源码构建依赖同级 `../codexbar`，README 指向 steipete/CodexBar。本次未拉取该构建依赖、未运行应用构建，因为没有业务代码修改。

## CC Switch 可借鉴的实现

参考版本：`06082e189d65e6d6dbadc35dacdac1ce6c79d89a`。

主要源码：

- [Codex 会话解析器](https://github.com/farion1231/cc-switch/blob/06082e189d65e6d6dbadc35dacdac1ce6c79d89a/src-tauri/src/services/session_usage_codex.rs)
- [成本计算器](https://github.com/farion1231/cc-switch/blob/06082e189d65e6d6dbadc35dacdac1ce6c79d89a/src-tauri/src/proxy/usage/calculator.rs)
- [用量功能说明](https://github.com/farion1231/cc-switch/blob/06082e189d65e6d6dbadc35dacdac1ce6c79d89a/docs/user-manual/en/4-proxy/4.4-usage.md)

解析器扫描 sessions 与 archived_sessions，读取 session_meta、turn_context 和 event_msg/token_count。其重要行为是先过滤重复快照，再优先使用 last_token_usage；缺失时才计算累计值差。累计值基线跨模型和额度桶维持，不能切模型就从零重新算。

额度刷新可能从不同 limit_id 重发相同快照。重复检测结合完整 total/last 快照签名和来源，而非只凭时间戳或本次 token 数；两个合法请求完全可能恰好使用相同 token 数。

分叉任务可能复制父任务的事件前缀，需要依据父会话关系、分叉时间及事件签名去除继承部分。缺失父记录时应进入待解析状态，不能直接把继承的累计用量记到子任务。

文件大小与修改时间共同参与变更判断，完整重放受变更影响的文件并通过稳定事件键去重。写入事件与推进游标应在事务内提交。归档移动、续页、revert 和截断都要单独覆盖。

不能照搬旧实现的字段假设：本机已出现 cache_write_input_tokens，而该参考版本的 Codex 解析器主要提取输入、缓存读取和输出。新实现应保留原始数值，先验证缓存写入语义，再决定归一化和定价。

## 指标定义

| 指标 | 建议口径 |
| --- | --- |
| 总 token | 验证后按输入 + 输出计算；缓存读取通常已包含在输入，推理输出通常已包含在输出，不重复累加。原始 total_tokens 同时保留用于对账 |
| 输入 / 输出 | 分别展示；缓存读取和缓存写入作为输入明细，在格式语义明确后归一化 |
| 缓存命中率 | SUM(cached_input_tokens) / SUM(input_tokens)，输入为 0 显示“—”；跨成员与日期按 token 加权，不平均百分比 |
| 请求数 | 第一版标为“有效用量记录数”：去重后、包含正用量的事件数。累计差值回退可能跨多个请求，不能声称是准确 HTTP 请求数 |
| 估算成本 | 对已知模型和已验证 token 语义采用版本化价格表；缓存读取、缓存写入分别计价，金额用 Decimal 或整数微美元 |
| 价格缺失 | 显示“未定价”，同时给出已定价覆盖比例，不按 0 元或近似型号静默处理 |
| 成功率 / 失败请求 | 仅凭本地 token 日志无法可靠给出，第一版不展示；将来代理采集可另行提供 |
| 数据完整性 | 展示最近采集时间、覆盖起点、解析错误、待解析分叉、未定价数量 |

成本属于 API 等价估算，不等同订阅实际扣费、额度百分比或团队应付账单。第一版不内置未经核验的模型价格；价格表需记录来源、币种、有效期、版本以及缓存写入计价规则。

## 本地采集设计

建议新增 `CodexLocalUsageCollector`（后台 actor）、`CodexUsageParser`（纯解析）、`CodexUsageStore`（SQLite）、`CodexUsagePricing`（版本化定价），不要塞进账号额度 mapper。

1. 尊重 CODEX_HOME，默认 ~/.codex，允许配置额外本地数据目录；扫描活动会话和归档会话。
2. 首次回填历史，之后按文件大小、修改时间和文件身份发现变化；仅重解析变化文件。大文件后续可加入安全检查点，但必须保存去重状态、模型、累计基线及父子关系。
3. 流式读取，仅提取时间、会话/父会话标识、模型、token 数和版本信息。日志正文不进入持久化统计表。
4. 未完成尾行延迟处理；完整坏行记录诊断。截断、替换、归档移动和多页 rollout 不能仅依赖文件路径去重。
5. 保留原始计数、规范化计数、来源与解析器版本；未知模型归 unknown，缺失时间不改写成“现在”。无法确定的用量进入待核验区。
6. SQLite 保存事件、文件状态、价格表、成员绑定历史和上报 outbox；事件入库、游标更新、outbox 生成在同一事务提交。
7. 启动时扫描，运行时采用文件通知加周期补扫，休眠恢复后补扫。与账号额度刷新完全解耦，Codex App 关闭或 OAuth 失效时仍能读取已有历史。

## 成员身份及历史归属

注册设备时生成持久化 deviceID；服务端发放绑定 teamID/memberID/deviceID 的可撤销设备凭据，保存在 Keychain。成员显示名可改，但稳定 memberID 不变。一位成员的多台机器使用同一 memberID。

同一电脑若被多人轮用，需要明确切换成员或依赖不同操作系统用户配置。绑定变更只作用于生效时间后的事件，不把全量历史自动改给新成员。已有历史默认列为“未分配”，通过一次明确的历史归属操作处理。

日志通常不能可靠证明当前事件属于哪个 OpenAI 登录账号，更不能以当前 auth 文件反推全部历史。accountRef 只作可选维度；无法确认则保留 unknown，不阻碍按成员统计。

远程执行、云端任务或同步拷贝到本机的历史并不自动等于本机原创消耗。第一版应将范围标为“本机日志记录的用量”，限制到本地可信目录；团队内同一事件跨设备重复上传时由服务端去重并标记归属冲突。

## 上报与服务端

建议新增接口，与 `/v1/quota-samples` 分离：

- `POST /v1/usage-events/batch`：批量提交去重事件，返回已确认事件及拒绝原因。
- `GET /v1/usage-summary?from=...&to=...&group_by=member|device|model`：依据认证团队范围聚合，支持时区及成员筛选。

建议事件字段：eventID、occurredAt、modelRaw、modelNormalized、inputTokens、cachedInputTokens、cacheWriteInputTokens、outputTokens、reasoningOutputTokens、source、parserVersion、quality、可选 accountRef。身份由服务端凭据解析，不能仅取客户端声明。

服务端表：members、device_memberships（带生效区间）、usage_events、usage_daily_rollups、model_prices。成员、设备和事件均带 team_id 隔离。

事件唯一键用团队范围内稳定事件标识，例如以团队专用密钥对“原始 rollout 标识 + 稳定事件定位信息”做 HMAC。设备 ID 不应成为跨设备去重键的一部分，否则拷贝日志会重复计费。必须保留合法同 token 请求，不可只哈希 token 数；续页和重写事件身份需在 fixture 中验证后定稿。

批量写入采用幂等插入；只对真正新增或明确修订的事件更新汇总。重传相同批次、重启、断网补传不增加计数。发生同一事件被不同成员申报时保留首次归属并标记冲突，不静默挪用或双算。

解析器修正不能通过改 eventID 制造新消费，应采用版本化修订或指定范围重建并原子更新汇总。客户端只在收到服务端确认后清理 outbox；网络错误指数退避，认证错误暂停并提示，单条坏数据隔离，避免阻塞整个队列。

原始明细保留期与日汇总保留期分开。清理明细时要保留去重墓碑或明确拒绝过旧事件，否则旧设备重传会再记一次。沿用 D1 批量写和用量监控，减少高频全量快照导致的写入开销。

仅上传统计字段及必要的不透明标识，不上传提示词、对话、代码、目录路径、邮箱或 OpenAI 凭据。首次启用成员上报时展示团队、成员、设备和将上传的字段范围；本地统计不依赖启用云同步。

## 界面与实施顺序

1. 本地 MVP：菜单增加今日 token、估算成本、有效用量记录数、缓存命中率；详情支持今日/7天/30天、模型拆分、缓存明细及数据完整性。先用合成 fixture 验证，再与本机抽样对账。
2. 成员上报：实现设备注册、成员绑定、用量事件接口、持久化补传与服务端幂等；复用现有同步状态展示，但分别显示额度同步与用量同步状态。
3. 团队面板：每个成员一行，展示消耗和缓存情况，可展开设备、按模型筛选；账号额度放在独立区域，不作为成员消耗分摊依据。

建议先完成第一阶段的解析和去重验收，再贯通第二阶段；统计口径错误会被上报和团队汇总进一步放大。

## 验收重点

- 重扫、重启、归档移动、相同批次重传：总量保持不变。
- 相同 total/last 快照随额度刷新重发：不新增消费；两个真实的相同大小请求仍均计入。
- 模型切换、累计值回退、多额度桶、仅 last/仅 total、零输入：计算合理且标注精度。
- 父子分叉、多层分叉、缺失父日志、续页、revert：继承历史不重复，未确定项可见且可恢复。
- 半行写入、坏行、截断替换、mtime 不变但 size 增长：无丢失或重复。
- 缓存读取/写入/推理字段：不双算；未知定价显示未定价，金额精度可验证。
- 多设备归同一成员、成员切换、跨设备复制日志：身份和去重正确。
- 超时重试、部分拒绝、乱序批次、跨团队请求、修改 memberID、撤销凭据：幂等与隔离成立。
- 时间范围跨午夜和夏令时、迟到事件、明细保留期后重传：汇总不漂移。

本次交付为基于源码和本机格式抽样的可实施方案；未实现统计界面、采集器或云端接口，未上传本机用量。
