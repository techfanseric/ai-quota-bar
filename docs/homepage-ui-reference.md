# 官网界面与亮点对照

官网使用 HTML/CSS/SVG/Canvas，不使用截图。账号使用 example.com，所有数值为虚构示例，不读取访问者 App 或日志。

| 官网区域 | App 来源 | 保留的信息结构与行为 |
|---|---|---|
| 左键菜单 | Views/MenuView.swift、Views/CodexUsageTrend.swift | Providers/Models 顶栏、Codex 置顶、本机用量、账号标题、额度曲线、元信息、历史周期、Settings/Quit |
| 本机用量 | Settings/Components/CodexLocalUsageSection.swift | 四项指标、时间范围、右侧纵轴、小时/日期横轴、历史账号与未定价提示 |
| 显示设置 | Settings/Components/ModelDisplaySettings.swift | 账号总开关保留模型选择、菜单与手机独立、手机 1–2 项、灰色控件 |
| 手机看板 | Resources/MobileDashboard/index.html、app.css、app.js | 构建时直接复用 HTML、样式及渲染函数；使用示例快照替代联网初始化 |
| 连接监控 | docs/images/control-center.png 及功能文档 | 速率/连接数、60 分钟点阵、New/Old 图例、活跃连接行 |

旧截图只用于对照，不放入网页。以当前源码和已确认交互优先：菜单无历史账号选择器，历史账号只在设置内选择。

亮点围绕：当前与跨周期历史、共享账号与本机消耗、统一显示设置、离开电脑的长任务保护、连接活动与线路诊断。公开版和开发版明确区分；本机统计与统一显示已包含在 v1.17.0，自助团队与邀请不宣称已经实现。

## 手机组件适配

scripts/build-mobile-preview.mjs 在构建时复用客户端资源，并在已检查的启动代码边界前截取渲染函数。边界变化将导致构建失败，要求复查适配器。演示只执行示例渲染和窗口 resize 重绘，不安装原来的配对、联网、唤醒和 online/visibility 事件。iframe 使用 allow-scripts sandbox，CSP 禁止 connect 与表单提交，ready 消息校验来源窗口。

复用中发现并修复状态条条目数变化异常：额度与保护信息依次补充时，重建长度不匹配的节点，避免后续线路/连接区域渲染中断。新增测试覆盖 0→2→1→0 条。这一客户端修复随 v1.17.0 一起发布。
