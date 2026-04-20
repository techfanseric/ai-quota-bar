# GLM API 字段理解

## 请求来源

GLM 支持来自 BigModel/Z.ai 控制台的额度接口：

```
GET https://bigmodel.cn/api/monitor/usage/quota/limit
```

用户在设置页粘贴浏览器 DevTools 复制的 curl。应用会解析并保存这些请求信息：

- `authorization`
- `bigmodel-organization`
- `bigmodel-project`
- cookie 中的会话信息（如果 curl 中存在）
- 接口 URL

## 返回结构

公开实现中该接口返回结构为：

```json
{
  "code": 200,
  "msg": "操作成功",
  "data": {
    "limits": [
      {
        "type": "TOKENS_LIMIT",
        "currentValue": 500000,
        "usage": 10000000,
        "percentage": 5,
        "nextResetTime": 1776696000000
      }
    ]
  },
  "success": true
}
```

## 字段语义

GLM 和 MiniMax 的字段语义不同，不能直接套用 MiniMax 的 `_usage_count` 逻辑。

| GLM 字段 | 含义 | 应用内换算 |
| --- | --- | --- |
| `currentValue` | 已用数量 | `currentIntervalUsedCount` |
| `usage` | 总限额 | `currentIntervalTotal` |
| `percentage` | 已用百分比 | 仅用于理解，应用内由数量重新计算 |
| `nextResetTime` | 下次重置时间，毫秒时间戳 | `endTime` |

## 模型映射

| `type` | 显示名称 | 周期 |
| --- | --- | --- |
| `TOKENS_LIMIT` | `GLM Tokens (5h)` | 5 小时 |
| `TIME_LIMIT` | `GLM MCP (month)` | 月度 |

## 换算公式

```
剩余数量 = usage - currentValue
已用百分比 = currentValue / usage * 100
剩余百分比 = (usage - currentValue) / usage * 100
```
