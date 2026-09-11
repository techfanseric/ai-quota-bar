# 智谱 GLM Coding Plan 额度接口

## 接入方式

优先在设置中填写个人版 Coding Plan API Key，应用发起：

```http
GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
Authorization: Bearer <API Key>
```

项目本地依赖 CodexBar 的 `ZaiAPIRegion.bigmodelCN` / `ZaiUsageFetcher` 已使用此端点和认证方式。其解析器目前只支持 `TOKENS_LIMIT` / `TIME_LIMIT`，因此本项目保留自己的解析器来支持新版积分额度。

备用方式：在 [智谱用量页面](https://bigmodel.cn/coding-plan/personal/usage) 打开 DevTools → Network，刷新后找到 `quota/limit`，选择 Copy as cURL，粘贴到设置中。网页请求使用 `https://bigmodel.cn/api/monitor/usage/quota/limit`。应用只解析请求，不执行 cURL 命令；保留 authorization、组织、项目和 Cookie。两种凭据都由现有钥匙串存储管理。网页会话过期时需要重新复制；已保存的旧 JSON 凭据仍使用原来的端点与认证头。

官方也提供[个人套餐用量查询插件](https://docs.bigmodel.cn/cn/coding-plan/extension/usage-query-plugin)。本次在 Chrome 验证了网页接口的实际响应；API Key 接入依据本地 CodexBar 实现，未用用户密钥进行在线调用验证。

## 新版积分额度

2026-09-11 在已登录 Chrome 的个人用量页面核对到以下结构（示例数值已替换）：

```json
{
  "code": 200,
  "success": true,
  "data": {
    "level": "lite",
    "limits": [
      {
        "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
        "usage": 2000, "currentValue": 0, "remaining": 2000, "percentage": 0
      },
      {
        "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
        "usage": 10000, "currentValue": 500, "remaining": 9499, "percentage": 5,
        "nextResetTime": 1800000000000
      }
    ]
  }
}
```

| 字段 | 含义 / 应用处理 |
| --- | --- |
| `usage` | 总额度 |
| `currentValue` | 已用量 |
| `remaining` | 服务端剩余量，优先采用；独立取整时不一定等于 `usage - currentValue` |
| `percentage` | 已用百分比；缺少总量时使用百分比模式 |
| `nextResetTime` | 毫秒时间戳，可缺失；缺失时不伪造周期起止时间 |
| `level` | 套餐等级 |
| `unit` / `number` | 周期单位与数量：1 天、3 小时、5 分钟、6 周（与 CodexBar 的枚举一致） |

当前两条积分记录分别显示为 `GLM Credits (5h)` 与 `GLM Credits (weekly)`，有独立 ID、历史和菜单栏选择。周窗口起点由重置时间减去 7 天计算，5 小时窗口同理。

应用的历史字段 `currentIntervalUsed` 实际存放**剩余量**，不能直接写入 API 的 `currentValue`。剩余百分比由剩余量 / 总量计算，并限制在有效范围。

## 兼容旧额度

- `TOKENS_LIMIT`：保留 Tokens 显示；缺少周期字段时按旧版 5 小时窗口处理。
- `TIME_LIMIT`：保留 MCP/Search 显示。仅旧网页凭证且缺少重置时间时尝试 `/api/biz/subscription/list`，API Key 与新版积分额度不调用该辅助接口。
- 空额度或不可用的额度数据返回错误，避免“连接成功但没有数据”。
