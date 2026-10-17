# 电源 / 防睡眠 / 合盖模式 + SleepHelper 特权助手 + 心跳协议 — Windows 迁移规格

> 源码范围:
> - `AIQuotaBar/Services/Power/`(全部 5 个文件)
> - `AIQuotaBarSleepHelper/main.swift`(特权 helper 守护进程)
> - `AIQuotaBarSleepShared/`(共享协议与 pmset 状态编解码)
> - `AIQuotaBar/Services/Codex/CodexSleepProtectionCoordinator.swift`(协调器,防睡眠与合盖的真正驱动者)
> - 测试:`AIQuotaBar/Tests/Codex/` 下 `PMSetSleepStateTests`、`ClosedLidSafetyPolicyTests`、`ClosedLidBrightnessControllerTests`、`CodexSleepProtectionCoordinatorTests`、`PrivilegedSleepHelperInstallerTests`

本模块分两层:

1. **无特权层(开盖防睡眠)**:`PowerAssertionController` 通过 IOKit `IOPMAssertionCreateWithName` 持有电源断言,App 进程内完成,退出即自动失效。
2. **特权层(合盖继续工作)**:`ClosedLidModeManager`(App 侧)+ `AIQuotaBarSleepHelper`(root LaunchDaemon)通过 XPC + 租约/心跳协议,把 `pmset disablesleep` 设为 1 并在一切结束条件出现后恢复原值。

---

## 1. 防睡眠(开盖):触发条件与保持内容

### 1.1 驱动者:`CodexSleepProtectionCoordinator`

`AIQuotaBar/Services/Codex/CodexSleepProtectionCoordinator.swift`。三个用户设置(UserDefaults,均默认 `true`):

| 键 | 含义 | 默认 |
|---|---|---|
| `codexSleepProtectionEnabled` | 总开关:AI 任务工作时保护 Mac | `true` |
| `codexSleepProtectionKeepDisplayAwake` | 任务期间阻止显示器空闲熄灭 | `true` |
| `codexSleepProtectionPreventScreenSaver` | 任务期间阻止自动屏保 | `true` |

第 4 个设置属于合盖层:`codexSleepProtectionAllowClosedLid`(默认 `false`,见 §3)。

### 1.2 保持的三类系统状态(`PowerAssertionController.swift`)

| macOS 断言 | 何时持有 | 作用 |
|---|---|---|
| `kIOPMAssertPreventUserIdleSystemSleep`(PreventUserIdleSystemSleep) | 只要保护生效就持有(基础断言,`acquire` 时第一个创建) | 阻止**系统空闲休眠**(idle sleep)。不开盖合盖无关,仅覆盖"空闲入睡" |
| `kIOPMAssertPreventUserIdleDisplaySleep`(PreventUserIdleDisplaySleep) | `keepDisplayAwake && isSessionActive` | 阻止**显示器因空闲而关闭** |
| `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` 周期刷新 | `keepDisplayAwake && preventScreenSaver && isSessionActive` | 阻止**自动屏保**(用户活动声明只维持几秒,必须周期刷新) |

- 断言 reason 字符串固定:`"AI Quota Bar: an AI task is working"`。
- 用户活动刷新周期:**45 秒**(timer tolerance 2s)——注释明确说明:单次声明只压屏保几秒,45s 留出低于 1 分钟最短屏保定时器的余量。
- `isSessionActive` 来自 `NSWorkspace.sessionDidResignActiveNotification / sessionDidBecomeActiveNotification`:**切换用户/会话失活时立即降级为 `acquire(keepDisplayAwake: false, declareUserActivity: false)`**——即"手动锁定仍被尊重":只保留系统防睡断言,允许显示器熄灭与屏保。
- `update()` 幂等:已持有时只调整显示策略,不重建系统断言。acquire 半途失败 → `release()` 全部回滚再抛错。
- `deinit` 与协调器 `stop()` 都调用 `release()`,断言 ID 逐一 `IOPMAssertionRelease`。

**对外可见的派生状态**(仪表板与测试均依赖):

```
keepDisplayAwakeEffective    = protectionStatus == .active && hasStarted && isEnabled
                               && hasProtectionNeed && keepDisplayAwake && isSessionActive
preventScreenSaverEffective  = keepDisplayAwakeEffective && preventScreenSaver
```

### 1.3 任务计数逻辑

活跃任务数 `activeTurnCount` 是保护持续的唯一依据(`hasProtectionNeed = activeTurnCount > 0 || 宽限期内`)。

**数据来源(全部每 2 秒轮询一次 + Codex hook 事件推送):**

| 来源 | 机制 | 计入 provider |
|---|---|---|
| Codex hook | `CodexHookListener` 收到 `userPromptSubmit`/`stop` 等事件,由 `CodexActivityTracker` 维护 turn 表 | `.codex` |
| Codex 本地检测 | `CodexLocalActivityDetector` 扫描 rollout 文件 | `.codex`(与 hook 会话 ID 取并集去重) |
| Kimi | `KimiLocalActivityDetector` | `.kimi` |
| ZCode(GLM) | `ZcodeActivityDetector` | `.glm` |
| MiniMax CLI | `MiniMaxActivityDetector` | `.miniMax` |
| Claude Code | `ClaudeCodeActivityDetector`,会话 ID 前缀 `glm:claude:` 归 GLM、`minimax:claude:` 归 MiniMax | `.glm` / `.miniMax` |

- `activeTurnCount = Σ protectedProviders 中各 provider 的活跃会话数`(不在保护集合内的 provider 计 0,但**计数仍持续更新**——测试 `testActivityCountRemainsAuthoritativeWhenProtectionIsOff`)。
- 多任务计数:任一任务还在,保护不提前结束(README:"Multiple simultaneous tasks are counted")。
- **幽灵 turn 回收**:hook turn 无 Stop 事件时,TTL **10 分钟**(`CodexActivityTracker.defaultTurnTTL = 10 * 60`)后在合并时被剪除,防止 kill -9 / 丢 hook 把保护永久钉死。
- 客户端型检测器(Kimi/ZCode/MiniMax/Claude Code)没有 turn 生命周期,只有"最近事件新鲜度"信号,靠 2s 轮询的快照增减会话。

### 1.4 任务结束 / 退出 App 的恢复

- **turn 结束宽限期 5 分钟**(`defaultTurnEndGracePeriod = 5 * 60`):最后一个活跃 turn 结束后,断言与合盖租约**继续保留 5 分钟**,桥接 turn 间隙与检测抖动,防止反复启停。宽限期内出现新活动 → 取消待定释放并重置。宽限期到点由一次性 timer(tolerance = min(5, period×0.1))触发 `applyCurrentState()` 释放。
- 释放路径(任一即全量 `release()` + `protectionStatus = .idle`):
  1. 计数归 0 且宽限期过;
  2. `isEnabled = false`(**立即**,不等宽限);
  3. `stop()`(App 退出;即使从未 `start()` 也强制 release 一次);
  4. `acquire` 抛错(failed 状态,先 release);
  5. `deinit`。
- 断言是进程资源:App 崩溃时 macOS 内核自动回收,无需额外机制(与合盖层的关键差异,见 §2)。

---

## 2. 心跳协议(App ↔ SleepHelper)

### 2.1 XPC 接口(`AIQuotaBarSleepShared/SleepHelperProtocol.swift`)

Mach 服务名 `com.techfanseric.aiquotabar.sleep-helper`,`AIQuotaBarSleepHelperProtocol`:

```swift
healthCheck(reply: (Bool, String) -> Void)
acquireClosedLidLease(_ leaseID: String, heartbeatTimeout: TimeInterval,
                      reply: (Bool, String?) -> Void)
heartbeatClosedLidLease(_ leaseID: String, reply: (Bool) -> Void)
releaseClosedLidLease(_ leaseID: String, reply: (Bool, String?) -> Void)
```

### 2.2 精确时序参数

| 参数 | 值 | 出处 |
|---|---|---|
| App→helper 心跳间隔 | **30 s**(timer tolerance 3s) | `ClosedLidModeManager.heartbeatInterval` |
| App 申请的心跳超时 | **90 s**(`heartbeatTimeout`) | `ClosedLidModeManager.heartbeatTimeout` |
| helper 端 clamp | `min(120, max(45, heartbeatTimeout))` → 传 90 得 90 | `ClosedLidLeaseService.acquire` |
| helper 过期扫描周期 | **5 s**(DispatchSourceTimer,过滤 `expiresAt <= now`) | `startExpiryTimer` |
| 租约刷新方式 | 心跳成功即 `expiresAt = now + heartbeatTimeout` | `heartbeat` |
| 租约最大时长 | **12 h = 43200 s**(App 侧策略,helper 不管) | `ClosedLidModeManager.maximumLeaseDuration` |
| 心跳租约 ID | App 每个 `ClosedLidModeManager` 实例一个 UUID,重连后复用同一 ID | `leaseID = UUID().uuidString` |

### 2.3 断连后的行为(双向兜底)

**App 侧:**
- 心跳回调 `valid == false`(租约已不存在)→ `hasLease = false`、废弃连接、`reconcile`(下次心跳周期内重新 acquire)。
- XPC error/invalidation → 状态 `.unavailable(error)`,复位 `hasLease/hasVerifiedHelper`,等待重连。
- 30s 心跳 tick 同时做安全网复评(§3.3)与最大租期检查。

**Helper 侧(关键设计,Windows 必须复刻):**
- **故意不注册 XPC invalidation/interruption handler 去释放租约**——XPC 中断是瞬态,客户端可能几秒内重连。真正死亡客户端由**心跳超时**兜底:90s 无心跳 → 5s sweep 过期 → 最后一个租约清空时恢复原睡眠设置。这样"连接抖动不会在合盖状态下意外恢复睡眠"。
- 多租约:`leases: [String: Lease]` 字典,第一个租约 acquire 时才改 pmset,最后一个释放/过期时才恢复。ownerID 按连接隔离(每个 `SleepHelperClient` 一个 UUID),leaseID+ownerID 双重校验。
- Helper 进程崩溃:launchd 自动重启,`init` 时发现残留 marker 文件即自愈恢复(§3.4)。
- 主线程急切初始化 `ClosedLidLeaseService.shared`,保证启动自愈/过期定时器/电源事件监听在首个客户端连接前就绪。

### 2.4 安装后验证流程(App 侧状态机)

`reconcile` 顺序:enabled? → bundle 内有 payload? → `installationStatus()`(missing/outdated → 安装或提示)→ `healthCheck`(通过才置 `hasVerifiedHelper`,状态 `.checking`)→ 任务活跃且安全 → acquire(状态 `.active`);无任务 → release + `.ready`。

---

## 3. 合盖模式(Closed-Lid)

### 3.1 开关与管理员授权流程

- 设置键 `codexSleepProtectionAllowClosedLid`,默认 `false`。仅当它为 on 且任务活跃时才申请租约;UI 文案:"已授权 · 正在等待 AI 任务"。
- **授权 = 安装特权 helper**(`PrivilegedSleepHelperInstaller.install()`),通过
  `osascript -e 'do shell script "<命令串>" with administrator privileges'` 触发系统管理员密码弹窗(未用 SMJobBless,是自定义 legacy 方案)。命令串(shell 单引号转义)依次:

  1. `launchctl bootout system/<helper-bundle-id>`(容错);
  2. `install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools`;
  3. `install -o root -g wheel -m 0755 <bundle内helper> /Library/PrivilegedHelperTools/com.techfanseric.aiquotabar.sleep-helper`;
  4. `install -o root -g wheel -m 0644 <bundle内legacy plist> /Library/LaunchDaemons/com.techfanseric.aiquotabar.sleep-helper.plist`;
  5. 生成授权客户端 marker:`app路径\n<app可执行文件SHA256>` 两行 → `chown root:wheel` + `chmod 0644` → 原子 `mv`;
  6. `launchctl enable` + `launchctl bootstrap system <plist>`。
- 安装后必须 `installationStatus() == .installed` 否则报 verificationFailed。
- **installed 判定**(三个文件齐全 + 两重哈希):helper 存在可执行、plist 存在、marker 存在;已装 helper 的 SHA256 == bundle 内 helper 的 SHA256;marker 第 1 行 == 当前 App 可执行文件路径、第 2 行 == 其 SHA256。helper 或 App 任一变动 → `outdated` → 重新安装(再次管理员授权)。
- `hasBundledPayload`(bundle 内 helper 可执行文件 + legacy plist)缺失(开发构建)→ 状态 `.unavailable("The privileged helper is only available in the packaged app.")`。
- LaunchDaemon plist 要点:`Label`=helper bundle id、`ProgramArguments`=/Library/PrivilegedHelperTools/…、`MachServices[<id>]=true`、`ProcessType=Background`、`AssociatedBundleIdentifiers`(仅 bundle 内置那份 plist 有;实际安装的是 Resources 下 legacy 版)。Makefile 同时产出两份:bundle 内 `Contents/Library/LaunchDaemons/`(SMJobBless 风格)与 `Contents/Resources/….legacy.plist`(实际被安装)。

**Helper 的客户端准入校验**(`shouldAcceptNewConnection`):SecCode 校验连接进程——
- 已 Team 签名:客户端 bundle id 必须 == 主 App id,且 Team ID 与 helper 自身相同;
- ad-hoc 签名(fallback):读 marker 文件,比对客户端可执行文件路径 + SHA256(路径+哈希 pin)。
不匹配 → 拒绝连接。

### 3.2 `pmset` 具体改了什么

**启用**(第一个租约到来时):`pmset -a disablesleep 1`(全部电源源,禁用睡眠——包括合盖睡眠)。启用前先读原状态存 marker。

**恢复**(最后一个租约释放/过期时),按 marker 里的 `PMSetSleepState`:
- 有全局值:`pmset -a disablesleep <0|1>`;
- 否则按源独立恢复:`pmset -b disablesleep <0|1>`(电池)、`-c`(充电器/AC)、`-u`(UPS);
- 什么都没读到(读取失败)→ **fail-safe `pmset -a disablesleep 0`**(宁可恢复默认可睡眠);
- marker 损坏无法解码 → 同样 `pmset -a disablesleep 0` 并删除 marker。

**持续看护(读回校验)**:租约存活期间每 5s sweep 时 `pmset -g` 读回 `SleepDisabled`;Apple Silicon 电源切换/系统更新可能悄悄清掉它——发现被清 0 → 重新 `pmset -a disablesleep 1` 并记录警告(可能与其他电源管理工具冲突)。`IOPSNotificationCreateRunLoopSource` 电源事件也触发该复评,**节流至每 10s 最多一次**(电源通知会在电量跳动时高频触发)。

**状态编解码**(`PMSetSleepStateCodec`,`pmset -g` / `pmset -g custom` 输出解析):
- `pmset -g`:全局 `SleepDisabled  1` 行 → `global`;
- custom 输出按 `Battery Power:` / `AC Power:` / `UPS Power:` 分节读 `disablesleep`;**小节存在但缺 disablesleep 键 → 视为 false**(意味着要恢复为 0);
- `isSleepDisabled`:global 优先;否则所有已报告源全部为 true 才算;**没有任何源 → 视为未禁用**(触发重断言)。

**崩溃自愈 marker**:`/var/db/com.techfanseric.aiquotabar.closed-lid-restore.json`(JSON:`previousState` + `createdAt`,写入后 `chmod 600`)。helper 启动时发现该文件 → 立即恢复原状态(覆盖 helper 被强杀、断电重启等场景)。App 崩溃则由心跳 90s 超时兜底恢复。

### 3.3 安全网规则(精确数值)

`ClosedLidSafetyPolicy.evaluate`,**每次 30s 心跳 tick 与每次 acquire 前评估**;任一触发 → `releaseLease()` + 进入对应挂起状态(**挂起而非关闭功能**,条件解除后下个 tick 自动重新 acquire;例外:最大租期按任务粒度):

| 规则 | 确切判定 | 触发后 |
|---|---|---|
| 热压力 | `ProcessInfo.thermalState ∈ {serious, critical}`(优先于电量判定) | `releaseLease` + `.suspendedThermal`("macOS 报告严重温度压力,合盖模式已暂停") |
| 低电量 | `!isOnACPower && hasInternalBattery && (batteryPercentage ?? 0) < 20`。注意:**电量读不到(nil)按 0 处理→触发**;接 AC 电源时任意电量放行;无内置电池(台式机)放行 | `releaseLease` + `.suspendedLowBattery(百分比)`("电量仅 X%,未接电源时至少需要 20%") |
| 12 小时最大租期 | `now - leaseStartedAt >= 43200s`(边界:43199s 不触发,43200s 触发)。**按任务粒度**:`maximumDurationReachedForCurrentTask` 置位后本任务内不再重试,`setTaskActive(false)` 时复位(下一个新任务重新获得 12h) | `releaseLease` + `.suspendedMaximumDuration`("开盖防休眠仍继续生效") |

电量为 `Int(round(current/max*100))`,来自 IOKit `IOPSCopyPowerSourcesInfo`(`kIOPSInternalBatteryType` 源,`kIOPSACPowerValue` 判断 AC)。

### 3.4 合盖调光(`ClosedLidBrightnessController`,与租约并行)

合盖时内置屏幕其实已不显示,但背光未必关——App 会把**内置显示器亮度压到 0** 省电,开盖/结束时恢复:

- `armed = closedLidEnabled && isTaskActive`(任务活跃才武装;宽限期同样算活跃)。
- 轮询盖子状态每 **2 s**(tolerance 1),读 `IOPMrootDomain` 的 `AppleClamshellState`(IORegistry bool)。
- 亮度读写走私有 `DisplayServices.framework`(`dlopen` + `DisplayServicesGetBrightness/SetBrightness`);只处理 `CGDisplayIsBuiltin` 的屏幕,**外接屏绝不碰**。
- **绝不盲调暗**:读不到当前亮度就不调暗(没有可恢复的值)。
- 原亮度持久化到 UserDefaults 键 `closedLidDimSavedBrightness`(崩溃恢复);已存在 pending 值时不覆盖(避免用已压黑的值覆盖原始值)。
- 每次 poll 都**重新压暗**(环境光可能自动调亮);恢复时机:开盖、解除武装(armed=false)、`stop()`、以及下次 App 启动时盖子开着 → `recoverPendingRestore()`。盖子仍关着则保留 pending 值。

### 3.5 诊断命令行(App 主程序自带,`SleepHelperCommandLine.swift`)

`AIQuotaBar --sleep-helper-status | --sleep-helper-register | --sleep-helper-health | --sleep-helper-self-test`。
self-test 语义:acquire 租约(传 45s timeout)→ `pmset -g` 验证所有已知电源源的 disablesleep 均为 1 → release → 验证 pmset 状态与测试前完全一致。同步 XPC 调用超时 8s。

---

## 4. Windows(C# .NET 8)映射建议

### 4.1 开盖防睡眠:不需要任何特权助手

`SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)` 完全覆盖 §1.2 的三个断言:

| macOS | Windows 覆盖 |
|---|---|
| PreventUserIdleSystemSleep(阻止空闲睡眠) | `ES_SYSTEM_REQUIRED`(含 Modern Standby/S0ix 下的 idle) |
| PreventUserIdleDisplaySleep(阻止显示器空闲熄灭) | `ES_DISPLAY_REQUIRED` |
| `IOPMAssertionDeclareUserActivity` 45s 刷新(阻止屏保) | `ES_DISPLAY_REQUIRED` 直接重置驱动屏保的 idle 计时器,**不需要 45s 定时器**,也不需要 `SPI_SETSCREENSAVEACTIVE` 改系统设置 |

实现要点:
- 用 `ES_CONTINUOUS` 后标志保持到进程下一次调用或进程退出——与 macOS 断言"退出即失效"的语义一致,**无需心跳兜底**。
- 注意 `SetThreadExecutionState` 的 flags 绑定调用线程,线程池线程死亡会静默失效:在专用常驻线程上调用,或改用 `PowerCreateRequest`(POWER_REQUEST 类型 `PowerRequestSystemRequired` / `PowerRequestDisplayRequired`,句柄关闭即释放,崩溃安全,且在 `powercfg /requests` 里可见 reason)——推荐后者,reason 字符串沿用 "AI Quota Bar: an AI task is working"。
- **手动锁定仍被尊重**(对应 macOS session resign → `acquire(false,false)`):监听 `SystemEvents.SessionSwitch`(SessionLock/SessionUnlock)或 WTS 通知,锁屏时降级为仅 `ES_SYSTEM_REQUIRED`,解锁恢复 display 位。测试 `testManualSessionLockStopsDisplayProtectionButKeepsSystemAwake` 要求的行为:锁屏后系统防睡保持、显示保护关闭。

### 4.2 不需要特权 helper 的部分

§1 全部(空闲睡眠、显示器、屏保、任务计数、宽限期、TTL 回收、状态上报)均可在用户态 .NET 进程内完成。**心跳协议与 Windows 服务仅服务于合盖模式(修改 LIDACTION)**。

### 4.3 合盖模式在 Windows 上的等价行为

合盖不休眠 = 修改电源方案的 LID action(合盖动作),AC/DC 各一份:

```
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0   (0 = Do nothing)
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /SETACTIVE SCHEME_CURRENT        (使修改生效)
```

对应关系:
- `pmset -a disablesleep 1` ≈ 上面的 AC+DC LIDACTION 0(注:语义不完全等价——`disablesleep` 连空闲睡眠一起禁,但 Windows 空闲睡眠已由 `ES_SYSTEM_REQUIRED` 在进程级覆盖,只补 LIDACTION 即可)。
- `pmset -b/-c/-u` 分电源恢复 ≈ `powercfg /q SCHEME_CURRENT SUB_BUTTONS LIDACTION` 解析输出中的 `Current AC Power Setting Index` / `Current DC Power Setting Index`(十六进制),持久化为 marker(等价 `PMSetSleepState{battery, charger}`;Windows 无 UPS 源)。**恢复时写回原 AC/DC 两值**,读不到任何值 → fail-safe 写回 1(Sleep)——对应 `restorationCommands` 的 fail-safe 分支。注意 Windows 上"缺键视为 0(Sleep)"是默认值,LIDACTION 取值域 0/1/2/3(不操作/睡眠/休眠/关机),恢复必须精确写回原值而不是"0/1 布尔"。
- `pmset -g` 读回校验 + 5s 重断言 ≈ 定时 `powercfg /q` 读回 LIDACTION,被外部改掉就重写(组策略/其他工具同样可能改它)。
- **修改 LIDACTION 需要管理员权限**,且它是**持久化设置**(跨重启存活)——这正是心跳 + marker + 自愈机制在 Windows 上同样必需的原因:App 崩溃后必须有人把 LIDACTION 恢复。

特权进程映射(macOS → Windows):
- LaunchDaemon(root 守护进程)→ **Windows 服务**(LocalSystem,开机自启);
- XPC mach service → **命名管道**(`\\.\pipe\aiquota-bar-sleep-helper`),服务端 ACL 限本地 SYSTEM;
- SecCode 客户端校验 → `GetNamedPipeClientProcessId` + 进程可执行文件路径 + SHA256 pin(marker 文件同款方案);签名 Team 校验在 Windows 退化为 Authenticode 签名者证书比对(可选,路径+哈希 pin 已够);
- osascript "with administrator privileges" 一次性安装 → 首次启用时 UAC 提权运行安装命令(`sc create` + 复制二进制 + 写 marker),或 `Process.Start` `runas`;
- 崩溃自愈 marker `C:\ProgramData\AIQuotaBar\closed-lid-restore.json`(等价 /var/db JSON,服务启动时检查并恢复)。
- 心跳协议(30s 间隔 / 90s 超时 clamp [45,120] / 5s sweep / 管道断连不立即释放、只靠超时)可原样平移,数值不变。

其余安全网:
- 电量 20% 规则:`SystemInformation.PowerStatus`(`PowerLineStatus != Offline` 即 AC;`BatteryChargeStatus` 判断有无电池)直接等价。
- 热压力:**Windows 没有等价的 `ProcessInfo.thermalState`**。建议保留策略骨架、热探测默认返回 nominal(即规则空转),可选实现 WMI `MSAcpi_ThermalZoneTemperature`(很多机型不可用/数值不可靠)或以"电池 + 高放电率"代理;不可用时不要虚构阈值。
- 12 小时最大租期、按任务粒度、挂起状态机:纯应用逻辑,原样平移。
- 盖子状态轮询 → `PowerSettingRegisterNotification` + `GUID_LIDSWITCH_STATE_CHANGE` 事件推送(可去掉 2s 轮询)。
- 合盖调光 → WMI `WmiMonitorBrightnessMethods.WmiSetBrightness`(内置面板,一般无需管理员);`WmiMonitorBrightness` 读当前值;只处理内置面板(`WmiMonitorID`/`PanelType` 判断);"读不到亮度不调暗"、pending 值持久化、重复压暗逻辑照搬。

### 4.4 状态上报(移动仪表板 `MobileProtectionSnapshot`)

`MobileDashboardSnapshotBuilder.protectionSnapshot` 产出的 JSON 字段(必须逐字段保持兼容,前端已依赖):

```
isEnabled: Bool                     // codexSleepProtectionEnabled
activeTaskCount: Int                // activeTurnCount(跨 provider 合计)
hasActiveTasks: Bool                // activeTurnCount > 0
status: "idle" | "active" | "failed"
statusDetail: String?               // 当前恒为 nil(failed 时消息不透出)
keepDisplayAwake: Bool              // 用户设置
keepDisplayAwakeEffective: Bool     // §1.2 派生公式
preventScreenSaver: Bool
preventScreenSaverEffective: Bool
hookStatus: "notChecked" | "installed" | "helperMissing" | "failed"
hookActionRequired: Bool            // helperMissing/failed → true
closedLidEnabled: Bool
closedLidStatus: "disabled" | "requiresInstallation" | "installing" | "checking"
                | "ready" | "active" | "lowBattery" | "thermal"
                | "maximumDuration" | "unavailable"
closedLidDetail: String?            // 仅 lowBattery:电量百分比十进制字符串;unavailable 的错误消息不透出
closedLidActionRequired: Bool       // requiresInstallation / unavailable → true
lastActivityAt: Date?               // 全部来源最近事件时间
```

活动摘要侧(同一协调器输出,`MobileActivitySummarySnapshot`):`state`(idle/working/stale/unavailable)、`activeTaskCount`(上限 **99** `mobileActivityTaskCountLimit`)、新鲜度窗口 **10 分钟**(`mobileActivityFreshnessWindow`)、`recentEvents` 上限 5 条、`activeProviders` 取值 `"kimi"/"codex"/"glm"/"minimax"`(working 任务按来源去重、按首现顺序)。

---

## 5. 测试揭示的必须一致的精确行为

以下断言来自 XCTest,Windows 版本须逐条对齐:

**安全策略(`ClosedLidSafetyPolicyTests`)**
1. 电量 19%、电池供电、thermal nominal → `lowBattery(19)`;20% 放行(严格 `< 20`)。
2. 接 AC 时电量 5% → `allowed`(AC 使电量规则完全失效)。
3. 无电池台式机(percentage nil, no battery, no AC)→ `allowed`。
4. `serious` 与 `critical` 热压力 → `thermalPressure`(即使接 AC、满电);`nominal`/`fair` 放行。
5. 最大租期边界:43199s → 未达;43200s(`>=`)→ 达到。

**pmset 编解码(`PMSetSleepStateTests`)**
6. `pmset -g` 全局 `SleepDisabled 1` → `global=true`,battery/charger 为 nil。
7. custom 输出有小节但缺 `disablesleep` 键 → 该源视为 `false`(恢复为 0)。
8. 各源不同值独立保留(battery=0/charger=1/ups=0)→ 恢复命令依次 `-b 0`、`-c 1`、`-u 0`。
9. 有 global 时恢复计划**只**用 `pmset -a disablesleep <global>`(忽略分源值)。
10. 完全无源可读 → fail-safe `pmset -a disablesleep 0`。
11. `isSleepDisabled`:global 优先;多源须全部 true;未知状态视为未禁用。

**合盖调光(`ClosedLidBrightnessControllerTests`)**
12. 武装 + 合盖 → 亮度 0,保存原值;开盖 → 恢复原值并清除保存键。恢复序列精确:`appliedValues == [0, 0.75]`。
13. 武装但开盖:从不碰亮度。未武装时合盖 refresh 永不调暗。
14. 解除武装 / `stop()` → 立即恢复(不等开盖)。
15. 读不到亮度 → 永不调暗(appliedValues 保持空),开盖也不恢复。
16. 被外部调亮后每次 poll 重新压暗(`[0, 0, 0.75]`),保存值不被已压黑的值覆盖。
17. 重启恢复:盖子开着 → 恢复 pending 值并清除;盖子仍关着 → 保留 pending 值,下次调暗沿用。
18. 亮度武装仅当 `isEnabled && taskActive`;开关关闭、`stop()` 均解除武装;`start()` 无 pending 值时恢复是 no-op。

**协调器(`CodexSleepProtectionCoordinatorTests`)**
19. hook turn 开始 → `acquire(true, true)` + `protectionStatus == .active`;Stop → 立即 `release` + `.idle`(宽限期为 0 时)。
20. `stop()` 无条件 release(即使没 start 过也至少 release 一次),计数归 0。
21. 会话失活(sessionDidResignActive)→ **仍持断言**但最后一次 acquire 参数是 `(false, false)`(系统防睡保持,显示/屏保保护撤除)。
22. `isEnabled = false` → 立即 release + `.idle`(不等宽限)。
23. 保护关闭时任务计数仍照常更新(状态可见性独立于保护动作)。
24. 仅本地检测(无 hook)快照同样触发保护;快照清空 → 释放。
25. 多 provider:任一 provider 仍有任务则保护持续,全部结束才释放;`activeProviders` 集合与 per-provider 计数正确。
26. 宽限期:turn 结束后保护延续宽限期;宽限期内新 turn 取消待定释放(timer 边界:0.2s 时仍持有,0.8s 时已释放,period=0.5)。
27. 幽灵 turn:hook 起始 +10min TTL 后的下一次合并即回收,断言释放。
28. 移动摘要:hook 与本地会话按 sessionID 去重合并;`oldestStartedAt` 只在所有会话都有可靠 hook 起始时间时非 nil;超过 10 分钟新鲜度窗口 → `stale`(计数保留、时间字段清空、recentEvents 清空);计数上限 99。
29. 测试 fixture 中 `ClosedLidModeManager.enabledKey` 显式写 false(默认关闭合盖),协调器测试不依赖 helper。

**安装器(`PrivilegedSleepHelperInstallerTests`)**
30. 三文件齐 + 哈希全匹配才是 `installed`;已装 helper 内容变化 → `outdated`;App 可执行文件变化(marker 不再匹配)→ `outdated`。

---

## 6. 迁移实现清单(Windows 速查)

| macOS 组件 | Windows 对应 |
|---|---|
| `PowerAssertionController`(IOKit 断言) | `PowerCreateRequest`(System/Display)或 `SetThreadExecutionState`,专用线程 |
| 45s user-activity 刷新 | 不需要(`ES_DISPLAY_REQUIRED` 常驻) |
| `NSWorkspace` session 通知 | `SystemEvents.SessionSwitch`(锁屏降级) |
| 任务计数 / 宽限 300s / TTL 600s / 轮询 2s | 原样平移(纯逻辑) |
| `ClosedLidModeManager` 状态机(10 态) | 原样平移;`unavailable` 涵盖"非打包构建无 helper" |
| helper 安装(osascript 管理员) | 一次性 UAC 提权:装 Windows 服务 + marker |
| XPC mach service | 命名管道 + 客户端 PID/路径/SHA256 校验 |
| 心跳 30s / 超时 90s(clamp 45–120)/ sweep 5s | 原样平移;管道断连不释放,只靠超时 |
| `pmset -a disablesleep 1` | `powercfg /SETACVALUEINDEX + /SETDCVALUEINDEX SUB_BUTTONS LIDACTION 0 + /SETACTIVE` |
| `pmset -g` 读回 + 5s 重断言 | 定时 `powercfg /q` 读回 LIDACTION 重断言 |
| marker JSON + 启动自愈 | `ProgramData` 下 JSON + 服务启动自愈 |
| 电量 20% / 12h / 热压力 | 电量用 `PowerStatus`;12h 原样;热压力降级为空实现 |
| 盖态轮询 2s(AppleClamshellState) | `PowerSettingRegisterNotification(GUID_LIDSWITCH_STATE_CHANGE)` |
| DisplayServices 亮度 0/恢复 | `WmiMonitorBrightnessMethods.WmiSetBrightness`(仅内置屏,读不到不动) |
| `MobileProtectionSnapshot` 字段 | 逐字段保持(§4.4) |
