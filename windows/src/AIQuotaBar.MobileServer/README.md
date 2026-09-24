# AIQuotaBar.MobileServer（占位，暂无 csproj）

Kestrel 移动仪表盘服务端项目，**待 Phase 2 启动**后再创建 csproj 并加入 `windows/AIQuotaBar.Windows.sln`。对应 macOS 端 `AIQuotaBar/Services/MobileDashboard`（NWListener HTTP+WS）的移植。

要点（计划 §5.3、§7）：

- **前端资源单源复用**：静态资源直接复制自仓库 `AIQuotaBar/Resources/MobileDashboard`（macOS 端同一份），禁止在 Windows 侧复制修改（双端长期维护流程 §15.4）。
- Kestrel 承载 HTTP + WebSocket（一等支持）；配对、short code、install credential、只读面等安全机制原样移植。
- Windows 首次监听局域网端口会触发 Defender 防火墙授权弹窗：需首次开启引导（说明弹窗来源、建议仅专用网络）。
- 稳定主机名：mDNS `.local` 对外通告行为待 Phase 0 验证（风险 R8），不行则回退 NetBIOS 名 + IP 列表双通道（现有 IP fallback 已支持）。

依赖方向：MobileServer → Platform → Core，MobileServer → Providers → Core。
