# 项目文档

这里区分当前说明、运维记录和历史设计资料。实现行为以代码和“当前”文档为准；带日期的方案与调研用于保留决策背景。

## 当前文档

- [产品规格](./SPEC.md)：v1.16.0 的功能、数据来源、安全边界和设置结构。
- [MiniMax API 字段](./api-field-mapping.md)：MiniMax 剩余额度字段与时间单位。
- [GLM API 字段](./glm-api-field-mapping.md)：GLM API Key、网页 cURL、新旧额度类型及周期映射。
- [云同步后端](../cloudflare/README.md)：Worker API、D1 结构、部署和迁移。

## 发布说明

- [v1.23.1](./releases/v1.23.1.zh-CN.md)：菜单到期行与副标题打磨，官网团队面板预览对齐。
- [v1.23.0](./releases/v1.23.0.zh-CN.md)：常驻性能、存储显示与上传修复。

- [v1.16.0](./releases/v1.16.0.md)
- [v1.15.0](./releases/v1.15.0.md)
- [全部发布说明](https://github.com/techfanseric/ai-quota-bar/releases)

## 运维与历史资料

- [常驻负载与本机用量审查](./performance-audit-2026-09-20.md)：2026-09-20 的现场测量、修复与边界说明。

- [D1 读成本迁移记录](../cloudflare/DEPLOYMENT_NOTES.md)：2026-09-02 的生产迁移和验证结果。
- [云同步实现沿革](./cloud-sync-implementation-summary.md)：从初版到当前内置服务的变化。
- [Raycast 扩展调研](./raycast-extension-research.md)：2026-05-07 的替代实现调研，当前没有实施。

- [Windows 端移植计划](./windows-port-plan-2026-09-24.md)：2026-09-24 的跨平台方案与执行进度（§0 持续更新）。已批准执行：W0/Phase 0/W1 落地于 `windows/` 目录（CI 226/226 绿），待远程 Win10 机启动 S2~S6 与 W2。
- [早期运行排查记录](./run-experience-2026-04-09.md)：早期 Debug/Release 验证经验，部分命令和界面已变化。
- `superpowers/specs` 与 `superpowers/plans`：已执行或被后续实现替代的设计与实施记录。
