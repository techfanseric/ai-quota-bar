# 运营后台

入口：https://ai-quota-bar.pages.dev/admin 。部署于 node.cyberic 账号现有 Pages + D1。

## 登录

独立管理员密码保存在管理员 Mac 钥匙串：服务 `AI Quota Bar Operations`，账户 `https://ai-quota-bar.pages.dev/admin`。可在“钥匙串访问”中搜索该名称查看密码。密码对应生产环境 Pages secret `OPS_ADMIN_SECRET`，不进入代码或客户端。会话有效期 8 小时，使用 Secure / HttpOnly / SameSite=Strict Cookie。退出清除当前浏览器 Cookie；轮换服务端 secret 使所有旧会话失效。登录按来源限速。

## 统计口径

- 匿名统计默认关闭，在设置 → 通用 → 隐私开启，与额度同步独立。
- 以随机安装标识计数，不等同真实人数；重新安装且保留偏好数据不会生成新标识，重置数据或删除统计后重新开启会生成新标识。
- 启动 App、打开菜单或设置计为活跃；活跃上报每 15 分钟最多一次，UTC 跨日会立即记录。后台每小时心跳不计入活跃。
- DAU / WAU / MAU 为包含今天的 1 / 7 / 30 个 UTC 自然日内去重活跃安装数。
- 近期运行：最近 2 小时收到上报，不保证此刻在线。
- 累计接入不包含主动删除统计的安装。趋势支持 7 / 30 / 90 天，保留最近 90 天的每日明细；安装首末上报和最新版本信息保留至主动删除。
- 版本及 macOS 分布以近 30 天上报设备为分母。原有同步设备、团队成员单独展示，不与匿名安装数相加。
- 老版本及未开启统计的用户不在覆盖范围内，首次上线前无历史活跃数据。

## 数据与删除

客户端仅发送随机安装令牌、事件类型、App 版本和构建号、macOS 大版本与次版本。服务端存储安装令牌的 SHA-256 摘要，不收集 Codex 邮箱、对话、文件路径、设备名、用量或成本。登录限速使用短期来源摘要，不作为设备身份。

关闭开关停止后续上报；“停止并删除本机统计”删除该安装的设备行及每日明细，并保留仅含摘要的撤销记录，阻止延迟请求重新写入。网络失败时保持关闭并允许重试删除。

## 部署与验证

先在现有 D1 应用 `cloudflare/migrations/0004_operations.sql`，设置独立随机 `OPS_ADMIN_SECRET`（至少 40 字符，不能与 SYNC_TOKEN 相同），再 `npm run build:pages` 后部署 dist-pages。预览环境需要单独配置 secret，否则管理员接口拒绝服务。

接口：POST `/v1/admin/login`、POST `/v1/admin/logout`、GET `/v1/admin/overview?days=30`；客户端 POST `/v1/telemetry/pulse` 与 POST `/v1/telemetry/forget`。客户端共享同步凭证不能读取运营后台。

验证：`npm test`、`npm run check`；Swift `AnalyticsScheduleTests` 验证默认关闭、节流及 UTC 换日。真实客户端 build 34 已验证首次匿名上报和后台展示。
