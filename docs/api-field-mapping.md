# MiniMax API 字段理解

## 核心理解

**所有 `_usage_count` 字段 = 剩余数量（不是已用！）**

这是一个反直觉的字段命名：
- `current_interval_usage_count` = 当前周期**剩余**数量
- `current_weekly_usage_count` = 周**剩余**数量

## 字段对照表

| API 字段 | 含义 | 示例 |
|----------|------|------|
| `current_interval_total_count` | 当前周期总限额 | 4500 |
| `current_interval_usage_count` | 当前周期**剩余**数量 | 3734 |
| `current_weekly_total_count` | 周总限额 | 133000 |
| `current_weekly_usage_count` | 周**剩余**数量 | 133000 |
| `remains_time` | 距离重置的秒数 | 1618725 (~18.7天) |
| `start_time` / `end_time` | 当前周期时间范围（毫秒时间戳） | 1775649600000 |

## 换算公式

```
已用数量 = 总量 - 剩余数量
        = xxx_total_count - xxx_usage_count

已用百分比 = 已用数量 / 总量 × 100
          = (total - usage_count) / total × 100

剩余百分比 = 剩余数量 / 总量 × 100
          = usage_count / total × 100
```

## 示例数据

以 speech-hd 为例：

```json
{
    "model_name": "speech-hd",
    "current_interval_total_count": 19000,
    "current_interval_usage_count": 19000,
    "current_weekly_total_count": 133000,
    "current_weekly_usage_count": 133000,
    "remains_time": 1618725
}
```

对应显示：
- 剩余: 19000 / 19000 (100%)
- 已用: 0 / 19000 (0%) ← 根本没用过！
- 周剩余: 133000 / 133000 ← 周也没用过，满的！
- 重置时间: ~18.7天后

## 常见误区

**错误理解：**
- ❌ `current_interval_usage_count` = 已用数量
- ❌ `current_weekly_usage_count` = 周已用数量
- ❌ `xxx_total_count - xxx_usage_count` = 剩余

**正确理解：**
- ✅ `_usage_count` = 剩余数量
- ✅ `xxx_total_count - xxx_usage_count` = 已用数量

## 时间格式

`start_time`、`end_time` 为毫秒时间戳。

`remains_time` 为**毫秒**（不是秒！），是距离重置的倒计时。

### 重置周期类型

有两种不同的重置逻辑：

**1. 5小时周期 (如 MiniMax-M*)**
- 使用 `start_time` 和 `end_time` 表示周期范围
- 例如: 20:00-00:00 (UTC+8)
- `remains_time` 表示距离当前周期结束的毫秒数

**2. 每日重置 (其他模型)**
- 每天 00:00 (UTC+8) 重置
- 使用 `start_time` 和 `end_time` 表示"今天"范围
- 例如: 2026/04/08 00:00 - 2026/04/09 00:00

### `remains_time` 转换

`remains_time` 是毫秒数，转换为：
- < 3,600,000ms (< 1小时): Xm
- < 86,400,000ms (< 1天): Xh
- >= 86,400,000ms (>= 1天): Xd

## 周额度说明

- `current_weekly_total_count = 0`: 无周限制
- `current_weekly_usage_count = current_weekly_total_count`: 周额度满的（没用过）

## 更新日志

- 2026-04-08: 初始文档，纠正字段理解错误
- 2026-04-08: 补充 `current_weekly_usage_count` 也是剩余数量而非已用
