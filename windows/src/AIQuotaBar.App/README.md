# AIQuotaBar.App（占位，暂无 csproj）

UI 宿主项目。**UI 框架（WinUI 3 vs WPF）待 Phase 0 spike S6/S7 定稿后再创建 csproj 并加入 `windows/AIQuotaBar.Windows.sln`**，届时本项目才开始承载代码。

计划分工（计划 §6）：

- **设置窗与图表**：WinUI 3（Fluent、Win11 观感）。
- **托盘**：`Shell_NotifyIcon` 直调，实现在 `AIQuotaBar.Platform`，不在本项目。
- **弹层**（左键控制中心 / 右键路由面板）：无边框 Acrylic Win32 窗口 + WinUI 3 内容，失焦自动关闭、随任务栏对齐。
- **兜底**：若 S6/S7 发现 WinUI 3 阻断问题（聚焦、DPI、部署运行时），设置窗降级 WPF——Core / Providers / Platform 三层不受影响。

依赖方向：App → Platform → Core，App → Providers → Core。
