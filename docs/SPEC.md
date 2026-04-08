请实现一个 macOS menu-bar 应用（Swift，macOS 14+），用于监控 MiniMax API 使用量，具体要求：

1. 应用启动后自动调用 MiniMax 余额查询 API（`https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains`），在菜单栏图标旁边显示剩余额度数字（可自定义刷新间隔，默认每 60 秒自动刷新）。点击菜单栏图标展开下拉菜单，显示详细用量信息。
2. 菜单栏下拉内容包含：
   - 当前账户剩余额度（tokens/credits）
   - 最近一次刷新时间
   - 手动刷新按钮
   - 设置入口
3. 设置窗口（NSWindow）包含：
   - MiniMax API Key 输入框（安全存储在 Keychain 中）
   - 刷新间隔设置（秒）
   - 启动时自动刷新开关
   - 保存/测试连接按钮
4. 实时监控模式：可配置达到特定阈值（如剩余低于 20%）时在屏幕右下角显示 NSPanel 警告通知（.hudWindow 材质，无边框胶囊状），警告内容包含当前剩余量和时间戳。
5. 应用以 LSUIElement 模式运行（仅菜单栏图标，无 Dock 图标）。使用 Swift Package Manager 构建，提供 Makefile（build/run/install/clean），构建产物为签名的 .app bundle。