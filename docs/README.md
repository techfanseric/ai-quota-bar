# 项目文档

这里区分当前说明、运维记录和历史设计资料。实现行为以代码和“当前”文档为准；带日期的方案与调研用于保留决策背景。

## 当前文档

- [产品规格](./SPEC.md)：v1.15.0 的功能、数据来源、安全边界和设置结构。
- [MiniMax API 字段](./api-field-mapping.md)：MiniMax 剩余额度字段与时间单位。
- [GLM API 字段](./glm-api-field-mapping.md)：GLM API Key、网页 cURL、新旧额度类型及周期映射。
- [云同步后端](../cloudflare/README.md)：Worker API、D1 结构、部署和迁移。

## 发布说明

- [v1.15.0](./releases/v1.15.0.md)
- [全部发布说明](https://github.com/techfanseric/ai-quota-bar/releases)

## 运维与历史资料

- [D1 读成本迁移记录](../cloudflare/DEPLOYMENT_NOTES.md)：2026-09-02 的生产迁移和验证结果。
- [云同步实现沿革](./cloud-sync-implementation-summary.md)：从初版到当前内置服务的变化。
- [Raycast 扩展调研](./raycast-extension-research.md)：2026-05-07 的替代实现调研，当前没有实施。
- [早期运行排查记录](./run-experience-2026-04-09.md)：早期 Debug/Release 验证经验，部分命令和界面已变化。
- `superpowers/specs` 与 `superpowers/plans`：已执行或被后续实现替代的设计与实施记录。
