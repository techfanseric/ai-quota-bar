# 用 Raycast 扩展实现 `minimax-usage-monitor` 的调研

更新时间：2026-04-09

## 结论

这个需求适合迁移为 Raycast 扩展，而且核心价值能比较完整地保留：

1. 可以用 `menu-bar` 命令做常驻菜单栏入口，显示当前主模型剩余额度。
2. 可以用 `view` 命令做详情页，展示各模型额度、刷新时间、错误状态和操作面板。
3. 可以用 Raycast 的扩展偏好项保存 API Key、刷新间隔、阈值和主模型选择。
4. 可以用后台刷新让菜单栏定期更新。
5. 可以用 `Toast` / `HUD` 做轻量提醒。

但它不能 1:1 复制当前原生 macOS 应用的全部体验：

1. 不能像当前 Swift 版那样自定义一个 `NSPanel` 右下角悬浮警告面板。
2. 菜单栏命令不是长期驻留进程，刷新和点击都遵循 Raycast 的命令生命周期。
3. 设置页不是你自己画的 `NSWindow`，而是 Raycast 扩展的 Preferences。
4. 如果想上 Raycast Store，安全存储和配置方式需要尽量走 Raycast 官方能力，而不是直接复用当前 `Security`/`AppKit` 方案。

我建议采用“Raycast 原生重写 UI + 复用现有业务映射逻辑”的方案，而不是把 Swift 应用包进 Raycast。

## 为什么可行

Raycast 官方支持 `menu-bar` 命令，`MenuBarExtra` 可以把扩展内容放进 macOS 菜单栏；而且 `menu-bar` 和 `no-view` 命令都支持按 `interval` 定时后台刷新。

参考：

- [Menu Bar Commands](https://developers.raycast.com/api-reference/menu-bar-commands)
- [Background Refresh](https://developers.raycast.com/information/lifecycle/background-refresh)
- [Manifest](https://developers.raycast.com/information/manifest)

这些能力和你当前项目最重要的链路基本对齐：

1. 定时请求 MiniMax 配额接口。
2. 在菜单栏显示一个精简状态。
3. 点开后看详细模型列表。
4. 手动刷新。
5. 配置 API Key 和行为选项。

## 与当前 Swift 版的能力映射

### 1. 菜单栏数字

现有 Swift 版：

- `StatusBarController` 负责状态栏文字。
- `UsageViewModel.statusBarText` 负责主模型剩余值格式化。

Raycast 版：

- 用 `mode: "menu-bar"` 的命令返回 `MenuBarExtra`。
- 标题可直接显示类似 `3734/1.25h` 或 `M2 3734`。
- 菜单项中放“刷新”“打开详情”“打开 Preferences”。

适配度：高。

### 2. 下拉详情

现有 Swift 版：

- `MenuView` 里展示模型列表、错误态、刷新按钮、设置按钮。

Raycast 版：

- 方案 A：直接在 `MenuBarExtra` 下拉里展示简版模型列表。
- 方案 B：菜单栏只放摘要，点击“Open Details”跳到一个 `List` 详情命令。

我更建议 B。原因是：

1. Raycast 的 `List` 对搜索、分组、右侧 detail、ActionPanel 支持更成熟。
2. 复杂信息不应该都塞进 Menu Bar Extra。
3. 后续如果要加筛选模型、查看周期/周额度、复制数据，`List` 更顺手。

参考：

- [List](https://developers.raycast.com/api-reference/user-interface/list)
- [Detail](https://developers.raycast.com/api-reference/user-interface/detail)

适配度：高。

### 3. 设置窗口

现有 Swift 版：

- 自定义 `SettingsView`
- Keychain 存 API Key
- `UserDefaults` 存刷新间隔、语言、阈值、选中的模型

Raycast 版：

- API Key 用扩展 `preferences` 里的 `password` 类型。
- 刷新间隔、阈值、默认模型、是否启动后刷新，用扩展/命令偏好项。
- 命令里通过 `getPreferenceValues()` 读取。
- 通过 `openExtensionPreferences()` 或 `openCommandPreferences()` 跳转设置。

参考：

- [Preferences](https://developers.raycast.com/api-reference/preferences)
- [Manifest - Preference properties](https://developers.raycast.com/information/manifest)
- [Security](https://developers.raycast.com/information/security)

注意：

Raycast 官方说明里明确给了安全存储路径：密码型偏好项和本地存储 API。对于要发布的扩展，这是比我们自己在扩展里手写 Keychain 更合适的做法。

适配度：高。

### 4. 本地持久化与缓存

现有 Swift 版：

- `UserDefaults` 保存轻量配置
- 内存中维护 `modelQuotaSamples`

Raycast 版：

- 配置优先用 `preferences`
- 最近一次接口结果、模型快照、上次刷新时间、告警去重状态，可用 `LocalStorage`
- 短期高频缓存可用 `Cache`

参考：

- [Storage / LocalStorage](https://developers.raycast.com/api-reference/storage)
- [Cache](https://developers.raycast.com/api-reference/cache)

建议拆分：

1. `preferences`：用户配置
2. `LocalStorage`：结构化持久状态
3. `Cache`：菜单栏秒开时的快速回显

适配度：高。

### 5. 自动刷新

现有 Swift 版：

- `Timer.scheduledTimer(...)` 常驻刷新

Raycast 版：

- 在 manifest 里给 `menu-bar` 命令配置 `interval`
- 依赖 Raycast 的 background refresh
- 必须接受“不是精确定时”的现实，官方文档说明 macOS 会为了能耗做调度

参考：

- [Background Refresh](https://developers.raycast.com/information/lifecycle/background-refresh)

这个差异很关键：

1. 你现在的原生 App 更像一个常驻 agent。
2. Raycast 更像“由平台托管调度的命令执行”。

所以 60 秒刷新可以做，但不能承诺每次都像自建 `Timer` 那样严格准点。

适配度：中高。

### 6. 低额度警告

现有 Swift 版：

- 自定义 `NSPanel`，右下角浮层提醒

Raycast 版：

- 能做的是 `showToast()` / `showHUD()`
- 也可以在菜单栏标题、command subtitle、详情页空态里强调风险

参考：

- [Toast](https://developers.raycast.com/api-reference/feedback/toast)
- [HUD](https://developers.raycast.com/api-reference/feedback/hud)

这里是最大的不等价点：

1. `NSPanel` 风格提醒无法在 Raycast 扩展里原样复刻。
2. 如果你非常在意系统级常驻提醒体验，Swift 菜单栏 App 仍然更强。

适配度：中。

## 推荐的 Raycast 扩展结构

建议拆成 3 个命令：

### 1. `usage-menu-bar`

类型：

- `mode: "menu-bar"`

职责：

1. 用缓存秒开菜单栏标题
2. 后台刷新最新额度
3. 菜单内展示简版模型状态
4. 提供动作：
   - Refresh Now
   - Open Details
   - Open Preferences

### 2. `usage-details`

类型：

- `mode: "view"`

职责：

1. 用 `List` 展示所有模型
2. 支持按模型名搜索
3. 每个模型展示：
   - 当前周期剩余
   - 周额度剩余
   - 剩余百分比
   - 下次重置时间
4. 右侧 detail 或 metadata 展示更完整字段
5. 提供动作：
   - Refresh
   - Copy JSON
   - Set as Primary Model
   - Open Preferences

### 3. `refresh-usage`

类型：

- `mode: "no-view"`

职责：

1. 主动刷新接口
2. 更新 `LocalStorage` / `Cache`
3. 在需要时调用 `launchCommand()` 触发菜单栏命令刷新显示
4. 失败时显示 `Toast`

参考：

- [Command / launchCommand](https://developers.raycast.com/api-reference/command)

## 建议复用的现有代码

你现在项目里最值得复用的是“领域逻辑”，不是 UI 层。

可以直接迁移或翻译为 TypeScript 的部分：

1. `docs/api-field-mapping.md` 里的字段语义
2. `UsageService.decodeUsageData(...)` 的响应解析逻辑
3. `ModelUsageData` 的衍生字段规则
4. “主模型状态文字”的生成逻辑
5. 阈值判断逻辑

建议不要复用的部分：

1. `AppKit` / `SwiftUI` 视图层
2. `NSStatusItem` / `NSPanel`
3. `KeychainService.swift`
4. `Timer` 常驻刷新模型

## 一个适合迁移的 TypeScript 分层

建议目录：

```text
src/
  commands/
    usage-menu-bar.tsx
    usage-details.tsx
    refresh-usage.ts
  lib/
    api.ts
    types.ts
    storage.ts
    formatter.ts
    warning.ts
```

建议职责：

### `lib/types.ts`

定义：

1. MiniMax API 原始响应类型
2. `UsageSnapshot`
3. `ModelQuota`

### `lib/api.ts`

负责：

1. 拼接 `Authorization` header
2. 请求 `https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains`
3. 解析返回
4. 把 API 字段映射成扩展内统一数据结构

### `lib/storage.ts`

负责：

1. 读写 `LocalStorage`
2. 读写 `Cache`
3. 保存：
   - `lastSnapshot`
   - `lastRefreshAt`
   - `lastWarningAt`
   - `lastWarningSignature`

### `lib/formatter.ts`

负责：

1. `remains_time` 文案
2. 剩余百分比
3. 菜单栏标题
4. 模型 detail 展示文案

### `lib/warning.ts`

负责：

1. 判断是否低于阈值
2. 是否要避免重复提醒
3. 触发 `showToast` / `showHUD`

## 配置建议

建议把这些做成扩展级 preferences：

1. `apiKey`：`password`
2. `refreshInterval`：`dropdown`
3. `warningThreshold`：`dropdown` 或 `textfield`
4. `primaryModel`：`textfield`
5. `showWarnings`：`checkbox`
6. `showWeeklyQuota`：`checkbox`

原因：

1. 这些都属于跨命令共享配置。
2. `menu-bar`、`view`、`no-view` 命令都要访问它们。

## 一个现实可落地的 MVP

如果目标是尽快把 Swift 版能力迁到 Raycast，我建议 MVP 只做下面这些：

### 必做

1. `menu-bar` 常驻状态
2. API Key 配置
3. 手动刷新
4. 后台定时刷新
5. `List` 模型详情页
6. 低额度 `Toast`

### 先不做

1. 图表趋势
2. `NSPanel` 风格悬浮提醒
3. 应用更新检查
4. 多语言切换

原因：

1. Raycast 本身已经承担了“宿主应用更新”。
2. 趋势图在 Raycast 里不是不能做，但不是最优先。
3. 多语言可以等功能闭环后再加。
4. 告警先用 `Toast` 就够验证价值。

## 不建议 1:1 保留的现有功能

### 1. 应用内更新检查

Swift 版当前有 GitHub Release 检查逻辑。

Raycast 扩展通常不需要自己做“应用更新”这一层，因为扩展更新由 Raycast 平台管理。除非你还想检查“MiniMax API 配置规范变更”这类业务更新，否则这个模块大概率可以删掉。

### 2. 独立设置窗口

Raycast 的体验约定是配置进入 Preferences，而不是你自绘一个窗口。强行做额外配置视图会让体验割裂。

### 3. 原生面板式警告

如果你要的是“像系统守护进程一样”的提醒，Raycast 不是最好宿主。

## 关键技术风险

### 1. 刷新不是严格准点

官方文档明确说明 background refresh 会受 macOS 调度影响。

影响：

1. 60 秒不是硬 SLA。
2. 短周期额度模型的“实时性”会比原生常驻 App 弱一点。

### 2. 命令不是常驻进程

菜单栏命令会被加载、执行、卸载；不是一个一直活着的 agent。

影响：

1. 必须高度依赖缓存。
2. 所有展示都要围绕“快速读缓存 + 后台补新数据”设计。

### 3. 提醒形式受限

只能做 Raycast 支持的反馈形式，不能复刻 `NSPanel`。

## 最适合本项目的实现策略

### 策略 A：完全迁到 Raycast

适合：

1. 你主要追求快速查看额度
2. 接受轻量提醒替代悬浮面板
3. 希望减少独立 App 的维护成本

推荐度：高

### 策略 B：Swift 菜单栏 App + Raycast 快捷入口并存

做法：

1. 保留现有 Swift 菜单栏 App 负责强提醒和常驻刷新
2. 额外做一个 Raycast 扩展，提供搜索式查看和快捷操作

适合：

1. 你既要原生常驻提醒
2. 又想在 Raycast 里快速搜和看详情

推荐度：最高

这是我个人更推荐的方向，因为它几乎不牺牲现有强项。

### 策略 C：把现有 Swift App 嵌进 Raycast

不建议。

原因：

1. 技术上别扭
2. 体验上不符合 Raycast 扩展范式
3. 发布和维护都会更复杂

## 一个最小 manifest 草案

下面只是结构示意，不是可直接发布的完整文件：

```json
{
  "$schema": "https://www.raycast.com/schemas/extension.json",
  "name": "minimax-usage-monitor",
  "title": "MiniMax Usage Monitor",
  "description": "Monitor MiniMax coding plan quota in Raycast",
  "icon": "icon.png",
  "preferences": [
    {
      "name": "apiKey",
      "type": "password",
      "required": true,
      "title": "MiniMax API Key",
      "description": "Bearer token used to fetch MiniMax quota"
    },
    {
      "name": "refreshInterval",
      "type": "dropdown",
      "required": true,
      "title": "Refresh Interval",
      "description": "Background refresh interval",
      "default": "1m",
      "data": [
        { "title": "1 minute", "value": "1m" },
        { "title": "5 minutes", "value": "5m" },
        { "title": "15 minutes", "value": "15m" }
      ]
    }
  ],
  "commands": [
    {
      "name": "usage-menu-bar",
      "title": "MiniMax Usage",
      "mode": "menu-bar",
      "interval": "1m"
    },
    {
      "name": "usage-details",
      "title": "Open MiniMax Usage Details",
      "mode": "view"
    },
    {
      "name": "refresh-usage",
      "title": "Refresh MiniMax Usage",
      "mode": "no-view"
    }
  ]
}
```

注意：

`Manifest` 文档一处写了最小值 `1m`，`Background Refresh` 文档示例页写了 `10s`。以当前 manifest 说明页为准更稳妥，建议别把正式方案设计在 1 分钟以下。

参考：

- [Manifest](https://developers.raycast.com/information/manifest)
- [Background Refresh](https://developers.raycast.com/information/lifecycle/background-refresh)

这里我做了一个基于官方文档冲突的判断。

## 对这个仓库的直接建议

如果下一步要真的开做，我建议这样推进：

1. 新建一个独立目录 `raycast-extension/`
2. 用 TypeScript 重写数据获取和展示层
3. 先把 `docs/api-field-mapping.md` 里的规则翻译成 TS
4. 先完成 `usage-details` 命令
5. 再补 `menu-bar` 命令
6. 最后决定要不要保留 Swift 版强提醒

这样做的好处是：

1. 不会打断现有 Swift 版可用状态
2. 可以并行验证 Raycast 体验
3. 后续容易做 A/B 选择

## 我对这件事的最终判断

如果你的目标是“在 Raycast 里快速看 MiniMax 额度”，这件事非常适合做。

如果你的目标是“完全替代当前原生菜单栏 App，包括强提醒和准实时守护”，Raycast 可以覆盖 70% 到 85%，但很难完整替代。

更稳妥的方向是：

1. Raycast 扩展负责查询、搜索、快捷操作。
2. Swift 菜单栏 App 负责强提醒和原生常驻体验。

