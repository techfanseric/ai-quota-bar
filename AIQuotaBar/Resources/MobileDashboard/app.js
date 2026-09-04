(() => {
  "use strict";

  const TOKEN_KEY = "aiQuotaBar.mobileDashboard.token";
  const WAKE_INTENT_KEY =
    "aiQuotaBar.mobileDashboard.experimentalWakeIntent";
  const EVENTS_PATH = "/api/v1/events";
  const HEALTH_PATH = "/api/v1/health";
  const PWA_BOOTSTRAP_PATH = "/api/v1/pwa/bootstrap";
  const PWA_CLAIM_PATH = "/api/v1/pwa/claim";
  const MANUAL_CLAIM_PATH = "/api/v1/pwa/manual-claim";
  const MANIFEST_URL = "/manifest.webmanifest";
  const INSTALL_CLAIM_RETRY_MS = [0, 400, 1_200];
  const SAVED_ADDRESSES_KEY = "aiQuotaBar.mobileDashboard.lanAddresses.v1";
  const ACTIVE_BASE_KEY = "aiQuotaBar.mobileDashboard.activeBaseURL.v1";
  const DEFAULT_LAN_PORT = 18_765;
  const MAX_SAVED_ADDRESSES = 8;
  const ADDRESS_CHECK_TIMEOUT_MS = 1_500;
  const MANUAL_CLAIM_TIMEOUT_MS = 3_000;
  const DIM_AFTER_MS = 30_000;
  const PIXEL_SHIFT_MS = 60_000;
  const CONTENT_ROTATE_MS = 180_000;
  const STATUS_BOOST_MS = 2_400;
  const IDLE_CONFIRM_MS = 2_000;
  const IDLE_SCREENSAVER_MOVE_MIN_MS = 7_000;
  const IDLE_SCREENSAVER_MOVE_JITTER_MS = 5_000;
  const MAX_RETRY_MS = 30_000;
  const TASK_TELEMETRY_MAX_LANES = 5;
  const TASK_TELEMETRY_REFERENCE_ROOT_FONT_SIZE_PX = 14;
  const TASK_TELEMETRY_REFERENCE_SPEED_PX_PER_SECOND = 44;
  const TASK_TELEMETRY_SPEEDS_PX_PER_SECOND = Object.freeze([
    48,
    40,
    34,
    29,
    25,
  ]);
  const TASK_TELEMETRY_AGE_THRESHOLDS_SECONDS = Object.freeze([
    3 * 60,
    10 * 60,
    30 * 60,
    90 * 60,
  ]);
  const TASK_TELEMETRY_REFERENCE_GAP_PX = 48;
  const TASK_TELEMETRY_ANIMATION_DISTANCE_PX = 1_000_000;
  const TASK_TELEMETRY_MAINTENANCE_MS = 500;
  const TASK_TELEMETRY_FIELD_ORDER = Object.freeze([
    "title",
    "state",
    "phase",
    "project",
    "gitBranch",
    "source",
    "model",
    "modelProvider",
    "reasoningEffort",
    "sandboxPolicy",
    "approvalMode",
    "tokensUsed",
    "activeSubtasks",
    "subtaskNames",
    "createdAt",
    "startedAt",
    "elapsed",
    "lastUpdated",
    "cliVersion",
    "tool",
    "recentEvent",
    "progress",
  ]);
  const TASK_TELEMETRY_FIELDS = new Set(TASK_TELEMETRY_FIELD_ORDER);
  const ACTIVITY_EFFECTS = new Set([
    "grainyDigitalRain",
    "dotWaves",
    "taskTelemetryMarquee",
  ]);
  const COLOR_SCHEMES = new Set(["auto", "dark", "light"]);
  const systemColorScheme = window.matchMedia("(prefers-color-scheme: light)");
  const THEME_COLORS = Object.freeze({
    dark: "#000000",
    light: "#f6f7f4",
  });
  const ACTIVITY_STATES = new Set([
    "idle",
    "working",
    "stale",
    "unavailable",
  ]);
  const ACTIVITY_EVENT_COPY_KEYS = Object.freeze({
    taskStarted: "eventTaskStarted",
    toolStarted: "eventToolStarted",
    permissionRequested: "eventPermissionRequested",
    toolFinished: "eventToolFinished",
    subtaskStarted: "eventSubtaskStarted",
    subtaskFinished: "eventSubtaskFinished",
    taskFinished: "eventTaskFinished",
    sessionEnded: "eventSessionEnded",
  });
  const ACTIVITY_PHASE_COPY_KEYS = Object.freeze({
    thinking: "phaseThinking",
    usingTool: "phaseUsingTool",
    waitingForPermission: "phaseWaitingForPermission",
    editing: "phaseEditing",
    testing: "phaseTesting",
    delegating: "phaseDelegating",
    finishing: "phaseFinishing",
    unknown: "phaseUnknown",
  });
  const ACTIVITY_TOOL_CATEGORY_COPY_KEYS = Object.freeze({
    shell: "toolShell",
    fileEdit: "toolFileEdit",
    web: "toolWeb",
    mcp: "toolMCP",
    subagent: "toolSubagent",
    other: "toolOther",
  });
  const ACTIVITY_TOOL_STATUS_COPY_KEYS = Object.freeze({
    inProgress: "toolInProgress",
    completed: "toolCompleted",
    failed: "toolFailed",
    declined: "toolDeclined",
    unknown: "toolStatusUnknown",
  });
  const MATRIX_GLYPHS = Object.freeze([
    "0", "1", "A", "I", "C", "O", "D", "E", "X", "/", ":", "·",
    "░", "▒", "╎", "┆",
  ]);

  const copy = {
    en: {
      documentTitle: "AI Quota — Mobile status",
      skip: "Skip to status",
      pageTitle: "Monitor",
      connecting: "Connecting to your Mac…",
      reconnecting: "Reconnecting…",
      live: "Live",
      disconnected: "Offline · last status",
      offline: "Phone offline · last status",
      pairingIndex: "LOCAL / READ ONLY",
      pairingTitle: "Pair this browser",
      pairingCopy:
        "Enter the temporary 8-digit pairing code shown in AI Quota Bar settings on your Mac, or scan its QR code.",
      pairingInvalid:
        "This saved token is no longer valid. Enter the current 8-digit code from AI Quota Bar settings on your Mac.",
      installCopy:
        "For a dedicated display, open this page in Safari and choose Add to Home Screen. It installs as AI Quota.",
      reinstallCopy:
        "This installed display needs pairing. Enter the temporary 8-digit code shown in AI Quota Bar settings on your Mac.",
      pairingRetry: "Retry secure pairing",
      pairingRetryLabel:
        "Retry secure pairing using the install credential held only in this page's memory.",
      pairingRetryCopy:
        "The Mac service may still be starting. The install credential is no longer in the URL and is held only in this page's memory; retry when the service is ready.",
      savedAddresses: "Saved LAN addresses",
      addressHint:
        "Enter a saved Mac address and its temporary 8-digit code. Checks never send a token.",
      addressPlaceholder: "192.168.1.8 or mac.local:18765",
      pairingCodePlaceholder: "8-digit code",
      pairingCodeLabel: "Temporary 8-digit pairing code from Mac settings",
      addAddress: "Save / pair",
      checkAllAddresses: "Check all",
      checkAddress: "Check",
      pairAddress: "Pair",
      connectAddress: "Connect",
      deleteAddress: "Delete",
      noSavedAddresses: "No saved addresses.",
      invalidAddress:
        "Use a private IPv4 or single-name .local host, with no path, query, or public address.",
      addressSaved: "Address saved.",
      pairLinkSaved: "Legacy pair link accepted. Select Connect to continue.",
      addressNeedsPair:
        "Enter the temporary 8-digit code from Mac settings to pair.",
      pairingCodeInvalid: "Enter the current 8-digit code from Mac settings.",
      addressPairing: "Pairing securely…",
      addressPaired: "Paired · connecting…",
      pairingCodeRejected: "Code invalid, expired, or already used elsewhere.",
      pairingRateLimited: "Too many attempts · wait and try a new code.",
      pairingUnavailable: "Pairing is temporarily unavailable on the Mac.",
      pairingRequestFailed: "Pairing failed · verify the address and try again.",
      addressChecking: "Checking without a token…",
      addressReachable: "HTTP reachable · identity not verified",
      addressUnavailable: "No response · saved address kept",
      addressConnecting: "Connecting to the selected Mac…",
      addressCheckDisclosure:
        "Checks send no token and only rank HTTP reachability.",
      quotaTitle: "Quota",
      tasksTitle: "Protection",
      routeTitle: "Route",
      connectionsTitle: "Connections",
      footer: "Local · read only · screen may sleep",
      mac: "Mac",
      codex: "Codex",
      reachable: "Reachable",
      unreachable: "Unreachable",
      checking: "Checking",
      activeTasks: "Active tasks",
      noActiveTasks: "None active",
      taskUnit: ["task", "tasks"],
      taskStateKicker: "Codex activity",
      taskStateKickerKimi: "Kimi activity",
      taskStateKickerGeneric: "Activity",
      taskWorking: "Working",
      taskIdle: "Idle",
      idleBlackout: "IDLE",
      dashboardProtectionOff: "Protection off",
      dashboardProtectionFailed: "Protection failed",
      workingDetail: "{n} active",
      idleDetail: "No active tasks",
      protectionOffDetail: "Mac sleep protection is disabled",
      protectionFailedDetail: "Mac sleep protection needs attention",
      activeProtectionOffWarning: "Protection off",
      activeProtectionFailedWarning: "Protection failed · action required",
      oldestActive: "Oldest active",
      elapsed: "Elapsed",
      lastActivity: "Last activity",
      activityStale: "stale signal",
      eventTaskStarted: "Task started",
      eventToolStarted: "Tool started",
      eventPermissionRequested: "Permission requested",
      eventToolFinished: "Tool finished",
      eventSubtaskStarted: "Subtask started",
      eventSubtaskFinished: "Subtask finished",
      eventTaskFinished: "Task finished",
      eventSessionEnded: "Session ended",
      phaseThinking: "Thinking",
      phaseUsingTool: "Using tool",
      phaseWaitingForPermission: "Waiting for permission",
      phaseEditing: "Editing",
      phaseTesting: "Testing",
      phaseDelegating: "Delegating",
      phaseFinishing: "Finishing",
      phaseUnknown: "Working",
      activityTool: "Tool",
      toolShell: "Shell",
      toolFileEdit: "File edit",
      toolWeb: "Web",
      toolMCP: "MCP",
      toolSubagent: "Subagent",
      toolOther: "Other",
      toolInProgress: "In progress",
      toolCompleted: "Completed",
      toolFailed: "Failed",
      toolDeclined: "Declined",
      toolStatusUnknown: "Status unknown",
      taskTelemetryLabel: "Task {n}",
      taskTelemetryUntitled: "Active task",
      taskTelemetryProject: "Project",
      taskTelemetryBranch: "Branch",
      taskTelemetrySource: "Source",
      taskTelemetryModel: "Model",
      taskTelemetryProvider: "Provider",
      taskTelemetryReasoning: "Reasoning",
      taskTelemetrySandbox: "Sandbox",
      taskTelemetryApproval: "Approval",
      taskTelemetryTokens: "Tokens",
      taskTelemetrySubtasks: "Subtasks {n}",
      taskTelemetrySubtaskNames: "Agents",
      taskTelemetryCreated: "Created",
      taskTelemetryStarted: "Started",
      taskTelemetryUpdated: "Updated",
      taskTelemetryCLI: "CLI",
      primaryQuota: "Primary quota",
      remaining: "remaining",
      unavailable: "Unavailable",
      activeConnections: "Connections",
      noActiveConnections: "None active",
      monitoring: "Monitoring",
      activeCountCompact: "{n} active",
      connectionUnit: ["connection", "connections"],
      lastUpdated: "Updated",
      loadingQuota: "Waiting for the first quota snapshot.",
      emptyQuota: "No quota data is available yet.",
      subscription: "Subscription",
      subscriptionEnds: "ends",
      account: "Account",
      defaultAccount: "Default account",
      modelUnit: ["model", "models"],
      resets: "Resets",
      window: "Window",
      currentBalance: "Current",
      weeklyBalance: "Weekly",
      usedCompact: "Used",
      unlimited: "Unlimited",
      paceAhead: "ahead of pace",
      paceBehind: "behind pace",
      paceOnTrack: "on pace",
      recentSamples: "Recent samples",
      recentSamplesLabel: "Quota remaining across recent samples",
      recentCycles: "Recent cycles",
      shortCycles: "5h cycles",
      weeklyCycles: "Week cycles",
      cycleLabel: "left",
      noSamples: "No sample history yet.",
      enabled: "Enabled",
      disabled: "Disabled",
      status: "Status",
      protectedTasks: "Protected tasks",
      protectionMaster: "Task protection",
      threshold: "Threshold",
      displayAwake: "Keep display awake",
      screenSaver: "Prevent screen saver",
      activityHook: "Activity hook",
      closedLid: "Closed-lid mode",
      sleepHelper: "Sleep helper",
      effective: "effective",
      standby: "standby",
      onCompact: "ON",
      offCompact: "OFF",
      actionRequired: "action required",
      lastActivity: "Last activity",
      idle: "Idle",
      active: "Active",
      failed: "Failed",
      installed: "Installed",
      notChecked: "Not checked",
      helperMissing: "Helper missing",
      installing: "Installing",
      ready: "Ready",
      lowBattery: "Paused · low battery",
      thermal: "Paused · thermal pressure",
      maximumDuration: "Paused · maximum duration",
      requiresInstallation: "Installation required",
      group: "Policy group",
      route: "Route",
      type: "Type",
      delay: "Latency",
      client: "Client",
      autoRecovery: "Auto recovery",
      lastTest: "Last latency test",
      speedTesting: "Testing latency",
      recentSwitches: "Recent",
      noSwitches: "No recent route switches.",
      from: "from",
      upload: "Upload",
      download: "Download",
      uploadCompact: "Up",
      downloadCompact: "Down",
      connectionsCompact: "Conn.",
      observed: "Observed",
      liveSampling: "Live sampling",
      backgroundSampling: "Background sampling",
      history60m: "Last 60 minutes",
      historyLabel: "Active OpenAI connection count over the last 60 minutes",
      noHistory: "No connection history yet.",
      currentConnections: "Active connections",
      longestActive: "Longest active",
      activeLinkMap: "Active link map",
      noConnections: "No active OpenAI connections.",
      network: "Network",
      duration: "Duration",
      rate: "Rate",
      justNow: "just now",
      secondsAgo: "{n}s ago",
      minutesAgo: "{n}m ago",
      hoursAgo: "{n}h ago",
      daysAgo: "{n}d ago",
      ago: "ago",
      appVersion: "AI Quota {version}",
      readOnly: "read only",
      unknown: "Unknown",
      loading: "Loading",
      unavailableState: "Unavailable",
      exhausted: "Exhausted",
      full: "Unused",
      shortWindow: "Short window",
      total: "total",
      remainingCount: "left",
      websocketError: "The status stream could not be read.",
    },
    zh: {
      documentTitle: "AI Quota — 手机状态",
      skip: "跳到状态内容",
      pageTitle: "监看",
      connecting: "正在连接 Mac…",
      reconnecting: "正在重新连接…",
      live: "实时",
      disconnected: "离线 · 末次状态",
      offline: "手机离线 · 末次状态",
      pairingIndex: "局域网 / 只读",
      pairingTitle: "配对此浏览器",
      pairingCopy: "请输入 Mac 上 AI Quota Bar 设置中显示的 8 位短时配对码，或扫描二维码。",
      pairingInvalid: "已保存的令牌已失效，请输入 Mac 上 AI Quota Bar 设置中的当前 8 位配对码。",
      installCopy: "需要独立监控屏时，请在 Safari 中打开本页并选择“添加到主屏幕”，应用名称为 AI Quota。",
      reinstallCopy: "此独立显示需要配对，请输入 Mac 上 AI Quota Bar 设置中显示的 8 位短时配对码。",
      pairingRetry: "重试安全配对",
      pairingRetryLabel: "使用仅保留在当前页内存中的安装凭证重试安全配对。",
      pairingRetryCopy: "Mac 服务可能仍在启动。安装凭证已从 URL 清除，仅保留在当前页内存中；服务就绪后可重试。",
      savedAddresses: "已保存的局域网地址",
      addressHint: "输入已保存的 Mac 地址和 8 位短时配对码；检查地址时绝不发送令牌。",
      addressPlaceholder: "192.168.1.8 或 mac.local:18765",
      pairingCodePlaceholder: "8 位配对码",
      pairingCodeLabel: "Mac 设置中的 8 位短时配对码",
      addAddress: "保存 / 配对",
      checkAllAddresses: "检查全部",
      checkAddress: "检查",
      pairAddress: "配对",
      connectAddress: "连接",
      deleteAddress: "删除",
      noSavedAddresses: "暂无已保存地址。",
      invalidAddress: "请输入私网 IPv4 或单标签 .local 主机，不能包含路径、查询或公网地址。",
      addressSaved: "地址已保存。",
      pairLinkSaved: "已接收旧版配对链接，请点击“连接”继续。",
      addressNeedsPair: "请先输入 Mac 设置中的 8 位短时配对码。",
      pairingCodeInvalid: "请输入 Mac 设置中当前的 8 位配对码。",
      addressPairing: "正在安全配对…",
      addressPaired: "配对成功 · 正在连接…",
      pairingCodeRejected: "配对码错误、已过期，或已在其他设备使用。",
      pairingRateLimited: "尝试次数过多 · 请稍后使用新配对码重试。",
      pairingUnavailable: "Mac 上的配对服务暂时不可用。",
      pairingRequestFailed: "配对失败 · 请核对地址后重试。",
      addressChecking: "正在无令牌检查…",
      addressReachable: "HTTP 可达 · 未验证身份",
      addressUnavailable: "无响应 · 已保留原地址",
      addressConnecting: "正在连接所选 Mac…",
      addressCheckDisclosure: "检查不发送令牌，仅用于排序 HTTP 可达性。",
      quotaTitle: "配额",
      tasksTitle: "保护",
      routeTitle: "线路",
      connectionsTitle: "连接",
      footer: "局域网 · 只读 · 允许锁屏",
      mac: "Mac",
      codex: "Codex",
      reachable: "可连接",
      unreachable: "不可连接",
      checking: "检查中",
      activeTasks: "活跃任务",
      noActiveTasks: "暂无",
      taskUnit: ["个任务", "个任务"],
      taskStateKicker: "Codex 活动",
      taskStateKickerKimi: "Kimi 活动",
      taskStateKickerGeneric: "活动",
      taskWorking: "工作中",
      taskIdle: "空闲",
      idleBlackout: "空闲",
      dashboardProtectionOff: "保护已关闭",
      dashboardProtectionFailed: "保护失败",
      workingDetail: "{n} 活跃",
      idleDetail: "暂无活跃任务",
      protectionOffDetail: "Mac 睡眠保护已关闭",
      protectionFailedDetail: "Mac 睡眠保护需要处理",
      activeProtectionOffWarning: "保护已关闭",
      activeProtectionFailedWarning: "保护失败 · 需要处理",
      oldestActive: "最早任务",
      elapsed: "已持续",
      lastActivity: "最近活动",
      activityStale: "信号已过期",
      eventTaskStarted: "任务开始",
      eventToolStarted: "工具开始",
      eventPermissionRequested: "等待授权",
      eventToolFinished: "工具完成",
      eventSubtaskStarted: "子任务开始",
      eventSubtaskFinished: "子任务完成",
      eventTaskFinished: "任务完成",
      eventSessionEnded: "会话结束",
      phaseThinking: "正在思考",
      phaseUsingTool: "正在使用工具",
      phaseWaitingForPermission: "等待授权",
      phaseEditing: "正在编辑",
      phaseTesting: "正在测试",
      phaseDelegating: "正在分派",
      phaseFinishing: "正在收尾",
      phaseUnknown: "工作中",
      activityTool: "工具",
      toolShell: "命令行",
      toolFileEdit: "文件编辑",
      toolWeb: "网页",
      toolMCP: "MCP",
      toolSubagent: "子任务",
      toolOther: "其他",
      toolInProgress: "进行中",
      toolCompleted: "已完成",
      toolFailed: "失败",
      toolDeclined: "已拒绝",
      toolStatusUnknown: "状态未知",
      taskTelemetryLabel: "任务 {n}",
      taskTelemetryUntitled: "活跃任务",
      taskTelemetryProject: "项目",
      taskTelemetryBranch: "分支",
      taskTelemetrySource: "来源",
      taskTelemetryModel: "模型",
      taskTelemetryProvider: "提供商",
      taskTelemetryReasoning: "推理",
      taskTelemetrySandbox: "沙箱",
      taskTelemetryApproval: "审批",
      taskTelemetryTokens: "Token",
      taskTelemetrySubtasks: "子任务 {n}",
      taskTelemetrySubtaskNames: "子任务名称",
      taskTelemetryCreated: "创建",
      taskTelemetryStarted: "开始",
      taskTelemetryUpdated: "更新",
      taskTelemetryCLI: "CLI",
      primaryQuota: "主要配额",
      remaining: "剩余",
      unavailable: "暂无",
      activeConnections: "连接",
      noActiveConnections: "暂无",
      monitoring: "监测正常",
      activeCountCompact: "{n} 个活跃",
      connectionUnit: ["个连接", "个连接"],
      lastUpdated: "更新于",
      loadingQuota: "正在等待首次配额快照。",
      emptyQuota: "暂无可显示的配额数据。",
      subscription: "订阅",
      subscriptionEnds: "截止",
      account: "账户",
      defaultAccount: "默认账户",
      modelUnit: ["个模型", "个模型"],
      resets: "重置",
      window: "周期",
      currentBalance: "当前",
      weeklyBalance: "每周",
      usedCompact: "已用",
      unlimited: "无限制",
      paceAhead: "快于消耗节奏",
      paceBehind: "慢于消耗节奏",
      paceOnTrack: "符合消耗节奏",
      recentSamples: "近期样本",
      recentSamplesLabel: "近期样本中的配额剩余比例",
      recentCycles: "近期周期",
      shortCycles: "5 小时周期",
      weeklyCycles: "周周期",
      cycleLabel: "剩余",
      noSamples: "暂无样本历史。",
      enabled: "已开启",
      disabled: "已关闭",
      status: "状态",
      protectedTasks: "受保护任务",
      protectionMaster: "任务保护",
      threshold: "阈值",
      displayAwake: "保持屏幕唤醒",
      screenSaver: "阻止屏幕保护",
      activityHook: "活动钩子",
      closedLid: "合盖模式",
      sleepHelper: "睡眠辅助程序",
      effective: "正在生效",
      standby: "待命",
      onCompact: "开",
      offCompact: "关",
      actionRequired: "需要处理",
      lastActivity: "最近活动",
      idle: "空闲",
      active: "生效中",
      failed: "失败",
      installed: "已安装",
      notChecked: "未检查",
      helperMissing: "缺少辅助程序",
      installing: "安装中",
      ready: "就绪",
      lowBattery: "已暂停 · 电量低",
      thermal: "已暂停 · 温度压力",
      maximumDuration: "已暂停 · 已达最长时限",
      requiresInstallation: "需要安装",
      group: "策略组",
      route: "线路",
      type: "类型",
      delay: "延迟",
      client: "客户端",
      autoRecovery: "自动恢复",
      lastTest: "最近测速",
      speedTesting: "正在测速",
      recentSwitches: "最近切换",
      noSwitches: "近期没有线路切换。",
      from: "来自",
      upload: "上传",
      download: "下载",
      uploadCompact: "上传",
      downloadCompact: "下载",
      connectionsCompact: "连接",
      observed: "采样于",
      liveSampling: "实时采样",
      backgroundSampling: "后台采样",
      history60m: "最近 60 分钟",
      historyLabel: "最近 60 分钟内的 OpenAI 活跃连接数",
      noHistory: "暂无连接历史。",
      currentConnections: "活跃连接",
      longestActive: "最长活跃",
      activeLinkMap: "活跃链接点阵",
      noConnections: "当前没有活跃的 OpenAI 连接。",
      network: "网络",
      duration: "持续",
      rate: "速率",
      justNow: "刚刚",
      secondsAgo: "{n} 秒前",
      minutesAgo: "{n} 分钟前",
      hoursAgo: "{n} 小时前",
      daysAgo: "{n} 天前",
      ago: "前",
      appVersion: "AI Quota {version}",
      readOnly: "只读",
      unknown: "未知",
      loading: "加载中",
      unavailableState: "不可用",
      exhausted: "已耗尽",
      full: "未使用",
      shortWindow: "短周期",
      total: "总量",
      remainingCount: "剩余",
      websocketError: "无法读取状态流。",
    },
  };

  const elements = {
    page: document.getElementById("page"),
    gate: document.getElementById("gate"),
    gateTitle: document.getElementById("gate-title"),
    gateCopy: document.getElementById("gate-copy"),
    installCopy: document.getElementById("install-copy"),
    pairingRetryButton: document.getElementById("pairing-retry-button"),
    dashboard: document.getElementById("dashboard"),
    machineName: document.getElementById("machine-name"),
    liveState: document.getElementById("live-state"),
    liveStateText: document.getElementById("live-state-text"),
    taskHero: document.getElementById("task-hero"),
    taskStateKicker: document.getElementById("task-state-kicker"),
    taskStateTitle: document.getElementById("task-state-title"),
    taskStateDetail: document.getElementById("task-state-detail"),
    taskStateWarning: document.getElementById("task-state-warning"),
    taskDuration: document.getElementById("task-duration"),
    taskRecentActivity: document.getElementById("task-recent-activity"),
    taskWatermark: document.getElementById("task-watermark"),
    matrixRainCanvas: document.getElementById("matrix-rain-canvas"),
    taskTelemetryMarquee: document.getElementById("task-telemetry-marquee"),
    wakeAmbientVideo: document.getElementById("wake-ambient-video"),
    quotaTime: document.getElementById("quota-time"),
    quotaErrors: document.getElementById("quota-errors"),
    quotaContent: document.getElementById("quota-content"),
    protectionContent: document.getElementById("protection-content"),
    routeContent: document.getElementById("route-content"),
    connectionsTime: document.getElementById("connections-time"),
    connectionsContent: document.getElementById("connections-content"),
    footerCopy: document.getElementById("footer-copy"),
    footerMeta: document.getElementById("footer-meta"),
    idleBlackout: document.getElementById("idle-blackout"),
    idleScreensaverWord: document.querySelector(".idle-screensaver-word"),
  };
  const taskTelemetryLaneStates = new WeakMap();

  const state = {
    token: "",
    activeBaseURL: "",
    connectionEpoch: 0,
    manualClaimEpoch: 0,
    manualClaimController: null,
    pairedServerInstances: new Map(),
    installCredential: "",
    installCredentialRejected: false,
    installClaimInFlight: null,
    automaticClaimInFlight: null,
    installCookieClaimRetryAvailable: false,
    savedAddresses: [],
    addressResults: new Map(),
    addressCheckInFlight: false,
    recordedSuccessfulOrigin: "",
    language: navigator.language.toLowerCase().startsWith("zh") ? "zh" : "en",
    snapshot: null,
    connected: false,
    controller: null,
    retryTimer: null,
    retryCount: 0,
    dimTimer: null,
    shiftTimer: null,
    contentRotateTimer: null,
    statusBoostTimer: null,
    idleConfirmTimer: null,
    idleScreensaverTimer: null,
    idleScreensaverPosition: null,
    displayedActiveTaskCount: null,
    explicitHasActiveTasks: null,
    activitySummary: null,
    activeProviderMix: "none",
    activityBackgroundEffect: "grainyDigitalRain",
    taskTelemetryFields: new Set(TASK_TELEMETRY_FIELD_ORDER),
    colorScheme: COLOR_SCHEMES.has(document.documentElement.dataset.colorScheme)
      ? document.documentElement.dataset.colorScheme
      : "auto",
    resolvedColorScheme: null,
    idleBlackoutMarqueeEnabled: false,
    idleBlackoutActive: false,
    rainTimer: null,
    rainGeneration: 0,
    rainKey: "",
    rainColumns: [],
    rainFrame: 0,
    taskTelemetryViewportScale: 1,
    taskTelemetryOrderSalt:
      Math.floor(Math.random() * 0xffff_ffff) || 1,
    taskTelemetryMaintenanceTimer: null,
    connectionsView: null,
    connectionMapFrame: null,
    pendingConnectionMap: null,
    connectionMapSignature: "",
    lastTaskSignal: null,
    latestProtection: null,
    bootstrapInFlight: null,
    oledProtectionEnabled: true,
    experimentalWakeMediaEnabled: false,
    wakeIntent: false,
    wakeLockSentinel: null,
    wakeLockRequestInFlight: null,
    wakeMediaPlayInFlight: null,
    wakeVisibilityAttempted: false,
    wakeGeneration: 0,
    suppressWakeMediaEvents: false,
    wakeFallbackInterrupted: false,
    wakeWorkActive: false,
    protectionTicker: null,
    protectionTickerSemantic: "",
    fingerprints: Object.create(null),
  };

  function t(key, values = {}) {
    const table = copy[state.language] || copy.en;
    let value = table[key] ?? copy.en[key] ?? key;
    if (Array.isArray(value)) return value;
    for (const [name, replacement] of Object.entries(values)) {
      value = value.replaceAll(`{${name}}`, String(replacement));
    }
    return value;
  }

  function element(tagName, className = "", text = null) {
    const node = document.createElement(tagName);
    if (className) node.className = className;
    if (text != null) node.textContent = String(text);
    return node;
  }

  function emptyState(message) {
    return element("p", "empty-state", message);
  }

  function appendMetricDetail(parent, detail) {
    if (detail) parent.append(element("span", "metric-detail", detail));
  }

  function safeNumber(value, fallback = 0) {
    const number = Number(value);
    return Number.isFinite(number) ? number : fallback;
  }

  function cssToken(name, fallback = "") {
    const value = window.getComputedStyle(document.documentElement)
      .getPropertyValue(name)
      .trim();
    return value || fallback;
  }

  function cssRGBToken(name, fallback) {
    const values = cssToken(name, fallback)
      .split(",")
      .map((value) => Number(value.trim()));
    return values.length === 3 && values.every(Number.isFinite)
      ? values
      : fallback.split(",").map((value) => Number(value.trim()));
  }

  function clamp(value, minimum, maximum) {
    return Math.min(maximum, Math.max(minimum, safeNumber(value)));
  }

  function fingerprint(value) {
    return JSON.stringify(value);
  }

  function hasChanged(key, value, force) {
    const next = fingerprint(value);
    if (!force && state.fingerprints[key] === next) return false;
    state.fingerprints[key] = next;
    return true;
  }

  function shuffledCopy(values, random = Math.random) {
    const result = [...values];
    for (let index = result.length - 1; index > 0; index -= 1) {
      const sample = Number(random());
      const unit = Number.isFinite(sample)
        ? Math.min(0.999_999, Math.max(0, sample))
        : 0.5;
      const swapIndex = Math.floor(unit * (index + 1));
      [result[index], result[swapIndex]] = [result[swapIndex], result[index]];
    }
    return result;
  }

  function randomUnit(random = Math.random) {
    const sample = Number(random());
    return Number.isFinite(sample)
      ? Math.min(0.999_999, Math.max(0, sample))
      : 0.5;
  }

  function idleScreensaverPosition(random = Math.random, previous = null) {
    let x = 36 + randomUnit(random) * 28;
    let y = 32 + randomUnit(random) * 36;
    if (previous && Math.hypot(x - previous.x, y - previous.y) < 15) {
      x = previous.x < 50 ? 64 : 36;
      y = previous.y < 50 ? 68 : 32;
    }
    return {
      x: Number(x.toFixed(2)),
      y: Number(y.toFixed(2)),
    };
  }

  function randomizeIdleScreensaver(random = Math.random) {
    const position = idleScreensaverPosition(
      random,
      state.idleScreensaverPosition,
    );
    state.idleScreensaverPosition = position;
    elements.idleScreensaverWord.style.setProperty("--idle-x", `${position.x}vw`);
    elements.idleScreensaverWord.style.setProperty("--idle-y", `${position.y}vh`);
    return position;
  }

  function stopIdleScreensaverMotion() {
    window.clearTimeout(state.idleScreensaverTimer);
    state.idleScreensaverTimer = null;
  }

  function scheduleIdleScreensaverMove(random = Math.random) {
    stopIdleScreensaverMotion();
    if (!state.idleBlackoutActive) return;
    const delay = IDLE_SCREENSAVER_MOVE_MIN_MS
      + Math.round(randomUnit(random) * IDLE_SCREENSAVER_MOVE_JITTER_MS);
    state.idleScreensaverTimer = window.setTimeout(() => {
      state.idleScreensaverTimer = null;
      if (!state.idleBlackoutActive) return;
      randomizeIdleScreensaver();
      scheduleIdleScreensaverMove();
    }, delay);
  }

  function idleBlackoutEligible({ enabled, activityState, connected, hidden }) {
    return (
      enabled === true &&
      activityState === "idle" &&
      connected === true &&
      hidden === false
    );
  }

  function setIdleBlackout(active) {
    const nextActive = active === true;
    if (nextActive === state.idleBlackoutActive) return;
    state.idleBlackoutActive = nextActive;
    if (nextActive) {
      randomizeIdleScreensaver();
      document.body.dataset.idleBlackout = "true";
      elements.page.inert = true;
      elements.page.setAttribute("aria-hidden", "true");
      elements.idleBlackout.hidden = false;
      elements.idleBlackout.setAttribute("aria-hidden", "false");
      scheduleIdleScreensaverMove();
      stopTaskRain({ clear: true });
      stopTaskTelemetryMotion();
      clearDimming();
      return;
    }
    stopIdleScreensaverMotion();
    delete document.body.dataset.idleBlackout;
    elements.page.inert = false;
    elements.page.removeAttribute("aria-hidden");
    elements.idleBlackout.hidden = true;
    elements.idleBlackout.setAttribute("aria-hidden", "true");
    configureTaskRain(true);
    configureTaskTelemetryMotion();
  }

  function configureIdleBlackout(enabled, rawActivitySummary) {
    state.idleBlackoutMarqueeEnabled = enabled === true;
    setIdleBlackout(idleBlackoutEligible({
      enabled: state.idleBlackoutMarqueeEnabled,
      activityState: rawActivitySummary?.state,
      connected: state.connected,
      hidden: document.hidden,
    }));
  }

  function applyStaticCopy() {
    document.documentElement.lang = state.language === "zh" ? "zh-Hans" : "en";
    document.title = t("documentTitle");
    document.querySelector(".skip-link").textContent = t("skip");
    document.querySelector("#gate .gate-kicker").textContent = t("pairingIndex");
    elements.gateTitle.textContent = t("pairingTitle");
    if (!elements.gateCopy.dataset.error) elements.gateCopy.textContent = t("pairingCopy");
    elements.installCopy.textContent = t("installCopy");
    elements.pairingRetryButton.textContent = t("pairingRetry");
    elements.pairingRetryButton.setAttribute(
      "aria-label",
      t("pairingRetryLabel"),
    );
    document.querySelectorAll("[data-address-title]").forEach((node) => {
      node.textContent = t("savedAddresses");
    });
    document.querySelectorAll("[data-address-hint]").forEach((node) => {
      node.textContent = t("addressHint");
    });
    document.querySelectorAll("[data-address-input]").forEach((node) => {
      node.placeholder = t("addressPlaceholder");
      node.setAttribute("aria-label", t("addressHint"));
    });
    document.querySelectorAll("[data-pairing-code-input]").forEach((node) => {
      node.placeholder = t("pairingCodePlaceholder");
      node.setAttribute("aria-label", t("pairingCodeLabel"));
    });
    document.querySelectorAll("[data-address-add]").forEach((node) => {
      node.textContent = t("addAddress");
    });
    document.querySelectorAll("[data-address-check-all]").forEach((node) => {
      node.textContent = t("checkAllAddresses");
      node.setAttribute("aria-label", t("addressCheckDisclosure"));
    });
    document.querySelector("#quota-title").textContent = t("quotaTitle");
    document.querySelector("#protection-title").textContent = t("tasksTitle");
    document.querySelector("#route-title").textContent = t("routeTitle");
    document.querySelector("#connections-title").textContent = t("connectionsTitle");
    elements.taskStateKicker.textContent = t("taskStateKicker");
    elements.idleBlackout.setAttribute("aria-label", t("idleBlackout"));
    elements.idleScreensaverWord.textContent = t("idleBlackout");
    elements.footerCopy.textContent = t("footer");
    refreshWakeMediaState();
    renderAddressPanels();
  }

  function resolveColorScheme(value) {
    if (value === "light" || value === "dark") return value;
    return systemColorScheme.matches ? "light" : "dark";
  }

  function applyColorScheme(value) {
    const next = COLOR_SCHEMES.has(value) ? value : "auto";
    const resolved = resolveColorScheme(next);
    const changed =
      next !== state.colorScheme || resolved !== state.resolvedColorScheme;
    state.colorScheme = next;
    state.resolvedColorScheme = resolved;
    document.documentElement.dataset.colorScheme = next;
    const themeColor = document.querySelector('meta[name="theme-color"]');
    if (themeColor) themeColor.content = THEME_COLORS[resolved];
    const colorScheme = document.querySelector('meta[name="color-scheme"]');
    if (colorScheme) {
      colorScheme.content = next === "auto" ? "light dark" : resolved;
    }
    const statusBar = document.querySelector(
      'meta[name="apple-mobile-web-app-status-bar-style"]',
    );
    if (statusBar) {
      statusBar.content = resolved === "light" ? "default" : "black";
    }
    return changed;
  }

  function refreshThemeDependentVisuals() {
    state.fingerprints = Object.create(null);
    const snapshot = state.snapshot;
    if (!snapshot) {
      configureTaskRain(true);
      return;
    }
    renderQuota(snapshot.quota, true);
    renderProtection(snapshot.protection, true, snapshot.activitySummary);
    configureTaskRain(true);
    renderRoute(snapshot.route, true);
    renderConnections(snapshot.connections, true);
  }

  function extractToken() {
    const fragment = window.location.hash.startsWith("#")
      ? window.location.hash.slice(1)
      : "";
    const parameters = new URLSearchParams(fragment);
    const tokenFromURL = parameters.get("token");
    const installFromURL = parameters.get("install");
    if (installFromURL && installFromURL.length <= 256) {
      state.installCredential = installFromURL;
      state.installCredentialRejected = false;
    }
    if (tokenFromURL || installFromURL) {
      window.history.replaceState(
        null,
        "",
        `${window.location.pathname}${window.location.search}`,
      );
    }
    if (tokenFromURL && tokenFromURL.length <= 512) {
      const currentBase = normalizeLANAddress(window.location.origin)?.origin;
      if (currentBase) setActiveBaseURL(currentBase);
      try {
        window.localStorage.setItem(TOKEN_KEY, tokenFromURL);
      } catch {
        // Private browsing may reject local storage; the in-memory token still works.
      }
      return tokenFromURL;
    }
    try {
      return window.localStorage.getItem(TOKEN_KEY) || "";
    } catch {
      return "";
    }
  }

  function clearToken() {
    state.token = "";
    try {
      window.localStorage.removeItem(TOKEN_KEY);
    } catch {
      // Nothing else is required if storage is unavailable.
    }
  }

  function storeToken(token) {
    state.token = token;
    try {
      window.localStorage.setItem(TOKEN_KEY, token);
    } catch {
      // The in-memory token remains usable when storage is unavailable.
    }
  }

  function normalizeLANAddress(input) {
    const raw = String(input || "").trim();
    if (!raw || raw.length > 1_024) return null;
    const candidate = /^http:\/\//i.test(raw) ? raw : `http://${raw}`;
    let url;
    try {
      url = new URL(candidate);
    } catch {
      return null;
    }
    if (
      url.protocol !== "http:" ||
      url.username ||
      url.password ||
      url.search ||
      (url.pathname && url.pathname !== "/")
    ) {
      return null;
    }

    const hostname = url.hostname.toLowerCase();
    if (!hostname || hostname === "localhost" || hostname.includes(":")) {
      return null;
    }
    const rawAuthority = raw
      .replace(/^http:\/\//i, "")
      .split(/[\/?#]/u, 1)[0];
    const portSeparator = rawAuthority.lastIndexOf(":");
    const hasExplicitPort = portSeparator >= 0;
    const rawHost = hasExplicitPort
      ? rawAuthority.slice(0, portSeparator)
      : rawAuthority;
    const rawPort = hasExplicitPort
      ? rawAuthority.slice(portSeparator + 1)
      : "";
    const octets = hostname.split(".").map(Number);
    const isIPv4 =
      octets.length === 4 &&
      octets.every((octet) => Number.isInteger(octet) && octet >= 0 && octet <= 255) &&
      /^\d+\.\d+\.\d+\.\d+$/u.test(hostname) &&
      rawHost === hostname;
    const isPrivateIPv4 = isIPv4 && (
      octets[0] === 10 ||
      (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] === 192 && octets[1] === 168) ||
      (octets[0] === 169 && octets[1] === 254)
    );
    const isSingleLabelLocal =
      /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.local$/u.test(hostname);
    if (!isPrivateIPv4 && !isSingleLabelLocal) return null;

    if (hasExplicitPort && !/^\d{1,5}$/u.test(rawPort)) return null;
    const port = hasExplicitPort ? Number(rawPort) : DEFAULT_LAN_PORT;
    if (!Number.isInteger(port) || port < 1 || port > 65_535) return null;
    let token = "";
    if (url.hash) {
      const fragment = new URLSearchParams(url.hash.slice(1));
      const keys = [...fragment.keys()];
      token = fragment.get("token") || "";
      if (
        keys.length !== 1 ||
        keys[0] !== "token" ||
        !/^[A-Za-z0-9._~-]{1,512}$/u.test(token)
      ) {
        return null;
      }
    }
    return { origin: `http://${hostname}:${port}`, token };
  }

  function loadActiveBaseURL() {
    try {
      const normalized = normalizeLANAddress(
        window.localStorage.getItem(ACTIVE_BASE_KEY) || "",
      );
      return normalized?.origin || "";
    } catch {
      return "";
    }
  }

  function baseAwareURL(path, baseURL = state.activeBaseURL) {
    const base = baseURL || window.location.origin;
    return new URL(path, `${base.replace(/\/$/u, "")}/`).href;
  }

  function setActiveBaseURL(origin, { persist = true } = {}) {
    const normalized = normalizeLANAddress(origin);
    const nextBase = normalized?.origin || "";
    state.activeBaseURL = nextBase;
    if (!persist) return nextBase;
    try {
      if (nextBase) window.localStorage.setItem(ACTIVE_BASE_KEY, nextBase);
      else window.localStorage.removeItem(ACTIVE_BASE_KEY);
    } catch {
      // The active base remains valid in memory for this page.
    }
    return nextBase;
  }

  function loadSavedAddresses() {
    try {
      const stored = JSON.parse(
        window.localStorage.getItem(SAVED_ADDRESSES_KEY) || "[]",
      );
      if (!Array.isArray(stored)) return [];
      const unique = new Map();
      for (const entry of stored) {
        const normalized = normalizeLANAddress(entry?.origin);
        if (!normalized || unique.has(normalized.origin)) continue;
        unique.set(normalized.origin, {
          origin: normalized.origin,
          lastUsedAt: Math.max(0, safeNumber(entry.lastUsedAt)),
          lastSuccessAt: Math.max(0, safeNumber(entry.lastSuccessAt)),
          lastReachableAt: Math.max(0, safeNumber(entry.lastReachableAt)),
        });
      }
      return [...unique.values()]
        .sort((left, right) => right.lastUsedAt - left.lastUsedAt)
        .slice(0, MAX_SAVED_ADDRESSES);
    } catch {
      return [];
    }
  }

  function persistSavedAddresses() {
    const safeEntries = state.savedAddresses
      .map(({ origin, lastUsedAt, lastSuccessAt, lastReachableAt }) => ({
        origin,
        lastUsedAt,
        lastSuccessAt,
        lastReachableAt,
      }))
      .sort((left, right) => right.lastUsedAt - left.lastUsedAt)
      .slice(0, MAX_SAVED_ADDRESSES);
    state.savedAddresses = safeEntries;
    try {
      window.localStorage.setItem(
        SAVED_ADDRESSES_KEY,
        JSON.stringify(safeEntries),
      );
    } catch {
      // The in-memory address book remains available for this page.
    }
  }

  function updateSavedAddress(origin, changes = {}, touch = false) {
    const existing = state.savedAddresses.find((entry) => entry.origin === origin);
    const record = existing || {
      origin,
      lastUsedAt: 0,
      lastSuccessAt: 0,
      lastReachableAt: 0,
    };
    Object.assign(record, changes);
    if (touch) record.lastUsedAt = Date.now();
    state.savedAddresses = [
      record,
      ...state.savedAddresses.filter((entry) => entry.origin !== origin),
    ];
    persistSavedAddresses();
  }

  function sortedSavedAddresses() {
    return [...state.savedAddresses].sort((left, right) =>
      right.lastSuccessAt - left.lastSuccessAt ||
      right.lastReachableAt - left.lastReachableAt ||
      right.lastUsedAt - left.lastUsedAt,
    );
  }

  function setAddressFeedback(key) {
    document.querySelectorAll("[data-address-feedback]").forEach((node) => {
      node.textContent = key ? t(key) : "";
    });
  }

  function renderAddressPanels() {
    const entries = sortedSavedAddresses();
    document.querySelectorAll("[data-address-check-all]").forEach((button) => {
      button.disabled = state.addressCheckInFlight || entries.length === 0;
    });
    document.querySelectorAll("[data-address-list]").forEach((list) => {
      const items = [];
      if (entries.length === 0) {
        items.push(element("li", "lan-address-empty", t("noSavedAddresses")));
      }
      for (const entry of entries) {
        const item = element("li", "lan-address-item");
        const copy = element("div", "lan-address-copy");
        copy.append(element("strong", "lan-address-origin", entry.origin));
        const resultKey = state.addressResults.get(entry.origin);
        if (resultKey) {
          copy.append(element("small", `lan-address-result ${resultKey}`, t(resultKey)));
        }
        const actions = element("div", "lan-address-actions");
        const check = element("button", "lan-address-check-one", t("checkAddress"));
        check.type = "button";
        check.disabled = state.addressCheckInFlight;
        check.dataset.addressAction = "check";
        check.dataset.origin = entry.origin;
        const connect = element("button", "lan-address-connect", t("connectAddress"));
        connect.type = "button";
        connect.dataset.addressAction = "connect";
        connect.dataset.origin = entry.origin;
        const pair = element("button", "lan-address-pair", t("pairAddress"));
        pair.type = "button";
        pair.dataset.addressAction = "pair";
        pair.dataset.origin = entry.origin;
        const remove = element("button", "lan-address-delete", t("deleteAddress"));
        remove.type = "button";
        remove.dataset.addressAction = "delete";
        remove.dataset.origin = entry.origin;
        actions.append(check, pair, connect, remove);
        item.append(copy, actions);
        items.push(item);
      }
      list.replaceChildren(...items);
    });
  }

  function markActiveBaseSuccessful() {
    const base = state.activeBaseURL || window.location.origin;
    if (state.recordedSuccessfulOrigin === base) return;
    const normalized = normalizeLANAddress(base);
    if (!normalized) return;
    state.recordedSuccessfulOrigin = normalized.origin;
    updateSavedAddress(
      normalized.origin,
      { lastSuccessAt: Date.now(), lastReachableAt: Date.now() },
      true,
    );
    state.addressResults.set(normalized.origin, "addressReachable");
    renderAddressPanels();
  }

  function stopConnectionForBaseChange() {
    state.connectionEpoch += 1;
    window.clearTimeout(state.retryTimer);
    state.retryTimer = null;
    if (state.controller) state.controller.abort();
    state.controller = null;
    state.connected = false;
    setIdleBlackout(false);
    stopTaskRain({ clear: true });
    state.retryCount = 0;
    state.recordedSuccessfulOrigin = "";
    deactivateWorkingWake();
  }

  function cancelManualClaim() {
    state.manualClaimEpoch += 1;
    if (state.manualClaimController) state.manualClaimController.abort();
    state.manualClaimController = null;
  }

  function selectActiveBase(origin, { preserveManualClaim = false } = {}) {
    const normalized = normalizeLANAddress(origin);
    if (!normalized) return false;
    if (!preserveManualClaim) cancelManualClaim();
    stopConnectionForBaseChange();
    setActiveBaseURL(normalized.origin);
    updateSavedAddress(normalized.origin, {}, true);
    return true;
  }

  async function checkSavedAddress(origin) {
    state.addressResults.set(origin, "addressChecking");
    renderAddressPanels();
    const controller = new AbortController();
    const timer = window.setTimeout(
      () => controller.abort(),
      ADDRESS_CHECK_TIMEOUT_MS,
    );
    try {
      const response = await fetch(baseAwareURL("/api/v1/health", origin), {
        method: "GET",
        mode: "cors",
        credentials: "omit",
        redirect: "error",
        cache: "no-store",
        signal: controller.signal,
      });
      const payload = response.ok ? await response.json() : null;
      if (response.status !== 200 || payload?.status !== "ok") {
        throw new Error("health_not_ok");
      }
      state.addressResults.set(origin, "addressReachable");
      updateSavedAddress(origin, { lastReachableAt: Date.now() });
      return true;
    } catch {
      state.addressResults.set(origin, "addressUnavailable");
      return false;
    } finally {
      window.clearTimeout(timer);
      renderAddressPanels();
    }
  }

  async function checkAllSavedAddresses() {
    if (state.addressCheckInFlight) return;
    state.addressCheckInFlight = true;
    renderAddressPanels();
    try {
      for (const entry of sortedSavedAddresses()) {
        await checkSavedAddress(entry.origin);
      }
    } finally {
      state.addressCheckInFlight = false;
      setAddressFeedback("addressCheckDisclosure");
      renderAddressPanels();
    }
  }

  function connectSavedAddress(origin) {
    const normalized = normalizeLANAddress(origin);
    if (!normalized) return;
    if (!state.token) {
      state.addressResults.set(normalized.origin, "addressNeedsPair");
      setAddressFeedback("addressNeedsPair");
      renderAddressPanels();
      return;
    }
    selectActiveBase(normalized.origin);
    state.addressResults.set(normalized.origin, "addressConnecting");
    renderAddressPanels();
    void prepareAndConnect();
  }

  function beginPairingAddress(origin, panel) {
    const normalized = normalizeLANAddress(origin);
    if (!normalized) return;
    const addressInput = panel.querySelector("[data-address-input]");
    const codeInput = panel.querySelector("[data-pairing-code-input]");
    addressInput.value = normalized.origin;
    codeInput.value = "";
    codeInput.focus();
    setAddressFeedback("addressNeedsPair");
  }

  function manualClaimErrorKey(status, errorCode) {
    if (status === 401 && errorCode === "invalid_pairing_code") {
      return "pairingCodeRejected";
    }
    if (status === 429 && errorCode === "pairing_rate_limited") {
      return "pairingRateLimited";
    }
    if (status === 503 && errorCode === "pairing_unavailable") {
      return "pairingUnavailable";
    }
    return "pairingRequestFailed";
  }

  async function claimWithTemporaryCode(origin, submittedCode) {
    const normalized = normalizeLANAddress(origin);
    const code = String(submittedCode || "").trim();
    if (!normalized) {
      setAddressFeedback("invalidAddress");
      return false;
    }
    updateSavedAddress(normalized.origin, {}, true);
    if (!/^\d{8}$/u.test(code)) {
      state.addressResults.set(normalized.origin, "pairingCodeInvalid");
      setAddressFeedback("pairingCodeInvalid");
      renderAddressPanels();
      return false;
    }

    state.manualClaimEpoch += 1;
    const claimEpoch = state.manualClaimEpoch;
    if (state.manualClaimController) state.manualClaimController.abort();
    const controller = new AbortController();
    state.manualClaimController = controller;
    const timer = window.setTimeout(
      () => controller.abort(),
      MANUAL_CLAIM_TIMEOUT_MS,
    );
    state.addressResults.set(normalized.origin, "addressPairing");
    setAddressFeedback("addressPairing");
    renderAddressPanels();

    try {
      const response = await fetch(
        baseAwareURL(MANUAL_CLAIM_PATH, normalized.origin),
        {
          method: "POST",
          mode: "cors",
          headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ code }),
          cache: "no-store",
          credentials: "omit",
          redirect: "error",
          signal: controller.signal,
        },
      );
      const payload = await response.json().catch(() => ({}));
      if (claimEpoch !== state.manualClaimEpoch) return false;
      if (!response.ok) {
        const errorKey = manualClaimErrorKey(response.status, payload?.error);
        state.addressResults.set(normalized.origin, errorKey);
        setAddressFeedback(errorKey);
        return false;
      }
      const token = typeof payload?.token === "string" ? payload.token : "";
      const serverInstanceID =
        typeof payload?.serverInstanceID === "string"
          ? payload.serverInstanceID
          : "";
      if (
        !/^[A-Za-z0-9._~-]{1,512}$/u.test(token) ||
        !/^[A-Za-z0-9_-]{22}$/u.test(serverInstanceID)
      ) {
        state.addressResults.set(normalized.origin, "pairingRequestFailed");
        setAddressFeedback("pairingRequestFailed");
        return false;
      }

      storeToken(token);
      state.pairedServerInstances.set(normalized.origin, serverInstanceID);
      state.addressResults.set(normalized.origin, "addressPaired");
      setAddressFeedback("addressPaired");
      selectActiveBase(normalized.origin, { preserveManualClaim: true });
      updateSavedAddress(
        normalized.origin,
        { lastSuccessAt: Date.now(), lastReachableAt: Date.now() },
        true,
      );
      elements.gate.hidden = true;
      elements.pairingRetryButton.hidden = true;
      delete document.body.dataset.pairingRequired;
      renderAddressPanels();
      void prepareAndConnect();
      return true;
    } catch (error) {
      if (claimEpoch !== state.manualClaimEpoch) return false;
      const errorKey = "pairingRequestFailed";
      state.addressResults.set(normalized.origin, errorKey);
      setAddressFeedback(errorKey);
      return false;
    } finally {
      window.clearTimeout(timer);
      if (state.manualClaimController === controller) {
        state.manualClaimController = null;
      }
      if (claimEpoch === state.manualClaimEpoch) renderAddressPanels();
    }
  }

  function addSavedAddress(rawValue) {
    const normalized = normalizeLANAddress(rawValue);
    if (!normalized) {
      setAddressFeedback("invalidAddress");
      return false;
    }
    updateSavedAddress(normalized.origin, {}, true);
    if (normalized.token) storeToken(normalized.token);
    setAddressFeedback(normalized.token ? "pairLinkSaved" : "addressSaved");
    renderAddressPanels();
    return true;
  }

  function loadWakeIntent() {
    try {
      return window.localStorage.getItem(WAKE_INTENT_KEY) === "1";
    } catch {
      return false;
    }
  }

  function setWakeMediaPresentation(kind) {
    if (!state.experimentalWakeMediaEnabled || kind === "off") {
      delete document.body.dataset.wakeMediaState;
      return;
    }
    document.body.dataset.wakeMediaState = kind;
  }

  function refreshWakeMediaState() {
    const kind = document.body.dataset.wakeMediaState;
    if (kind) setWakeMediaPresentation(kind);
  }

  function stopWakeMedia({ reset = false } = {}) {
    const video = elements.wakeAmbientVideo;
    state.suppressWakeMediaEvents = true;
    video.pause();
    if (reset) {
      try {
        video.currentTime = 0;
      } catch {
        // Metadata may not have loaded yet; pausing is sufficient.
      }
    }
    window.setTimeout(() => {
      state.suppressWakeMediaEvents = false;
    }, 0);
  }

  async function releaseWakeLock() {
    const sentinel = state.wakeLockSentinel;
    state.wakeLockSentinel = null;
    if (!sentinel) return;
    try {
      await sentinel.release();
    } catch {
      // The platform may have released it before this cleanup runs.
    }
  }

  function showWakeFallback(interrupted = false) {
    if (!isWorkingWakeEligible()) return;
    state.wakeFallbackInterrupted = interrupted;
    setWakeMediaPresentation(interrupted ? "interrupted" : "needs-tap");
  }

  function isExplicitWorkingProtection(protection) {
    return (
      protection?.hasActiveTasks === true &&
      protection?.status === "active"
    );
  }

  function workingWakeEligible({ enabled, workActive, connected, hidden }) {
    return (
      enabled === true &&
      workActive === true &&
      connected === true &&
      hidden === false
    );
  }

  function isWorkingWakeEligible() {
    return workingWakeEligible({
      enabled: state.experimentalWakeMediaEnabled,
      workActive: state.wakeWorkActive,
      connected: state.connected,
      hidden: document.hidden,
    });
  }

  async function requestWakeLock(generation) {
    if (
      !isWorkingWakeEligible() ||
      !navigator.wakeLock ||
      typeof navigator.wakeLock.request !== "function"
    ) {
      return false;
    }
    if (state.wakeLockSentinel && !state.wakeLockSentinel.released) {
      setWakeMediaPresentation("wake-lock");
      return true;
    }
    if (state.wakeLockRequestInFlight) return state.wakeLockRequestInFlight;

    state.wakeLockRequestInFlight = (async () => {
      try {
        const sentinel = await navigator.wakeLock.request("screen");
        if (
          generation !== state.wakeGeneration ||
          !isWorkingWakeEligible()
        ) {
          await sentinel.release();
          return false;
        }
        state.wakeLockSentinel = sentinel;
        sentinel.addEventListener("release", () => {
          if (state.wakeLockSentinel !== sentinel) return;
          state.wakeLockSentinel = null;
          if (isWorkingWakeEligible()) {
            state.wakeVisibilityAttempted = false;
            void attemptWakeForVisiblePage();
          }
        });
        stopWakeMedia();
        setWakeMediaPresentation("wake-lock");
        return true;
      } catch {
        return false;
      } finally {
        state.wakeLockRequestInFlight = null;
      }
    })();
    return state.wakeLockRequestInFlight;
  }

  async function playWakeMedia() {
    if (
      !isWorkingWakeEligible() ||
      state.wakeLockSentinel
    ) {
      return false;
    }
    if (state.wakeMediaPlayInFlight) return state.wakeMediaPlayInFlight;
    const generation = state.wakeGeneration;
    const video = elements.wakeAmbientVideo;
    video.muted = true;
    video.defaultMuted = true;
    video.playsInline = true;
    video.disablePictureInPicture = true;
    video.disableRemotePlayback = true;
    setWakeMediaPresentation("starting");

    state.wakeMediaPlayInFlight = (async () => {
      try {
        const playResult = video.play();
        if (playResult && typeof playResult.then === "function") {
          await playResult;
        }
        if (
          generation !== state.wakeGeneration ||
          !isWorkingWakeEligible() ||
          video.paused
        ) {
          stopWakeMedia();
          return false;
        }
        state.wakeFallbackInterrupted = false;
        setWakeMediaPresentation("playing");
        return true;
      } catch {
        if (
          generation === state.wakeGeneration &&
          isWorkingWakeEligible()
        ) {
          showWakeFallback(state.wakeIntent);
        }
        return false;
      } finally {
        state.wakeMediaPlayInFlight = null;
      }
    })();
    return state.wakeMediaPlayInFlight;
  }

  async function attemptWakeForVisiblePage() {
    if (
      !isWorkingWakeEligible() ||
      state.wakeVisibilityAttempted
    ) {
      return;
    }
    state.wakeVisibilityAttempted = true;
    const generation = state.wakeGeneration;
    if (await requestWakeLock(generation)) return;
    if (
      generation !== state.wakeGeneration ||
      !isWorkingWakeEligible()
    ) {
      return;
    }
    if (state.wakeIntent) {
      await playWakeMedia();
    } else {
      showWakeFallback(false);
    }
  }

  function deactivateWorkingWake({ reset = false } = {}) {
    state.wakeGeneration += 1;
    state.wakeVisibilityAttempted = false;
    state.wakeFallbackInterrupted = false;
    stopWakeMedia({ reset });
    void releaseWakeLock();
    setWakeMediaPresentation("off");
  }

  function configureExperimentalWakeMedia(enabled, protection) {
    const wasEligible = isWorkingWakeEligible();
    const nextEnabled = enabled === true;
    const nextWorkActive = isExplicitWorkingProtection(protection);
    const changed =
      nextEnabled !== state.experimentalWakeMediaEnabled ||
      nextWorkActive !== state.wakeWorkActive;
    state.experimentalWakeMediaEnabled = nextEnabled;
    state.wakeWorkActive = nextWorkActive;
    const isEligible = isWorkingWakeEligible();
    if (!isEligible) {
      if (
        changed ||
        wasEligible ||
        state.wakeLockSentinel ||
        !elements.wakeAmbientVideo.paused
      ) {
        deactivateWorkingWake({ reset: !nextEnabled });
      } else {
        setWakeMediaPresentation("off");
      }
      return;
    }
    if (changed || !wasEligible) {
      state.wakeGeneration += 1;
      state.wakeVisibilityAttempted = false;
    }
    refreshWakeMediaState();
    void attemptWakeForVisiblePage();
  }

  async function suspendExperimentalWakeForBackground() {
    if (
      !state.experimentalWakeMediaEnabled &&
      !state.wakeLockSentinel &&
      elements.wakeAmbientVideo.paused
    ) {
      return;
    }
    deactivateWorkingWake();
  }

  function resumeExperimentalWakeOnce() {
    if (!isWorkingWakeEligible()) return;
    void attemptWakeForVisiblePage();
  }

  function isStandaloneDisplay() {
    return (
      window.matchMedia("(display-mode: standalone)").matches ||
      window.navigator.standalone === true
    );
  }

  function refreshManifestLink() {
    const current = document.querySelector('link[rel="manifest"]');
    if (!current) return;
    const replacement = current.cloneNode(false);
    replacement.href = MANIFEST_URL;
    replacement.dataset.sessionRefreshed = "true";
    current.replaceWith(replacement);
  }

  async function refreshPWABootstrap() {
    if (!state.token) return false;
    const requestBase = state.activeBaseURL || window.location.origin;
    if (new URL(requestBase).origin !== window.location.origin) return true;
    const requestToken = state.token;
    const requestEpoch = state.connectionEpoch;
    const requestKey = `${requestEpoch}:${requestBase}`;
    if (state.bootstrapInFlight?.key === requestKey) {
      return state.bootstrapInFlight.promise;
    }

    const promise = (async () => {
      try {
        const response = await fetch(
          baseAwareURL(PWA_BOOTSTRAP_PATH, requestBase),
          {
            method: "POST",
            headers: {
              Accept: "application/json",
              Authorization: `Bearer ${requestToken}`,
              "Cache-Control": "no-store",
            },
            cache: "no-store",
            credentials: "include",
          },
        );
        if (response.status === 401) {
          if (
            requestEpoch === state.connectionEpoch &&
            requestBase === (state.activeBaseURL || window.location.origin) &&
            requestToken === state.token
          ) {
            clearToken();
          }
          return false;
        }
        if (!response.ok) return false;
        const payload = await response.json();
        const isReady = payload?.status === "ready";
        if (
          isReady &&
          requestEpoch === state.connectionEpoch &&
          requestBase === (state.activeBaseURL || window.location.origin)
        ) {
          refreshManifestLink();
        }
        return isReady;
      } catch {
        // Pairing renewal is best-effort while the live stream reconnects.
        return true;
      } finally {
        if (state.bootstrapInFlight?.promise === promise) {
          state.bootstrapInFlight = null;
        }
      }
    })();
    state.bootstrapInFlight = { key: requestKey, promise };
    return promise;
  }

  async function claimStandaloneToken() {
    if (!isStandaloneDisplay() || state.token) return Boolean(state.token);
    const credential = state.installCredential;
    if (credential.length > 256) return false;
    if (state.installClaimInFlight) return state.installClaimInFlight;

    state.installClaimInFlight = (async () => {
      state.installCookieClaimRetryAvailable = false;
      for (const retryDelay of INSTALL_CLAIM_RETRY_MS) {
        if (retryDelay > 0) {
          await new Promise((resolve) => window.setTimeout(resolve, retryDelay));
        }
        try {
          const headers = {
            Accept: "application/json",
            "Cache-Control": "no-store",
          };
          if (credential) {
            headers.Authorization = `PWAInstall ${credential}`;
          }
          const response = await fetch(
            baseAwareURL(PWA_CLAIM_PATH, window.location.origin),
            {
              method: "POST",
              headers,
              cache: "no-store",
              credentials: "include",
            },
          );
          if (response.status === 401) {
            state.installCredential = "";
            state.installCredentialRejected = true;
            state.installCookieClaimRetryAvailable = false;
            return false;
          }
          if (!response.ok) continue;
          const payload = await response.json();
          const token = typeof payload?.token === "string" ? payload.token : "";
          if (!token || token.length > 512) continue;
          storeToken(token);
          const currentBase = normalizeLANAddress(window.location.origin)?.origin;
          if (currentBase) {
            selectActiveBase(currentBase);
          }
          state.installCredential = "";
          state.installCredentialRejected = false;
          state.installCookieClaimRetryAvailable = false;
          return true;
        } catch {
          // The local service may still be starting. The credential remains
          // only in this page's memory and the bounded loop retries it.
        }
      }
      state.installCookieClaimRetryAvailable = !credential;
      return false;
    })();

    try {
      return await state.installClaimInFlight;
    } finally {
      state.installClaimInFlight = null;
    }
  }

  async function claimTokenWithoutPairingCode() {
    if (state.token) return true;
    if (state.automaticClaimInFlight) return state.automaticClaimInFlight;

    state.automaticClaimInFlight = (async () => {
      try {
        const requestBase = window.location.origin;
        const healthResponse = await fetch(
          baseAwareURL(HEALTH_PATH, requestBase),
          {
            method: "GET",
            headers: {
              Accept: "application/json",
              "Cache-Control": "no-store",
            },
            cache: "no-store",
            credentials: "omit",
          },
        );
        if (!healthResponse.ok) return false;
        const health = await healthResponse.json();
        if (
          health?.status !== "ok" ||
          health?.requiresPairingCode !== false
        ) {
          return false;
        }

        const response = await fetch(
          baseAwareURL(PWA_CLAIM_PATH, requestBase),
          {
            method: "POST",
            headers: {
              Accept: "application/json",
              "Cache-Control": "no-store",
            },
            cache: "no-store",
            credentials: "include",
          },
        );
        if (!response.ok) return false;
        const payload = await response.json();
        const token = typeof payload?.token === "string" ? payload.token : "";
        if (!/^[A-Za-z0-9._~-]{1,512}$/u.test(token)) return false;
        storeToken(token);
        const currentBase = normalizeLANAddress(requestBase)?.origin;
        if (currentBase) selectActiveBase(currentBase);
        state.installCredential = "";
        state.installCredentialRejected = false;
        state.installCookieClaimRetryAvailable = false;
        return true;
      } catch {
        return false;
      }
    })();

    try {
      return await state.automaticClaimInFlight;
    } finally {
      state.automaticClaimInFlight = null;
    }
  }

  function setConnectionStatus(kind, message) {
    const dot = elements.liveState.querySelector(".state-dot");
    dot.className = `state-dot state-${kind}`;
    elements.liveStateText.textContent = message;
  }

  function showPairingGate(isInvalid = false) {
    state.connected = false;
    setIdleBlackout(false);
    stopTaskRain({ clear: true });
    deactivateWorkingWake({ reset: true });
    delete document.body.dataset.dashboardState;
    document.body.dataset.pairingRequired = "true";
    delete document.body.dataset.connectionRecovery;
    elements.gate.hidden = false;
    elements.dashboard.hidden = true;
    elements.gateCopy.dataset.error = isInvalid ? "true" : "";
    elements.gateCopy.textContent = isInvalid ? t("pairingInvalid") : t("pairingCopy");
    elements.installCopy.textContent = isStandaloneDisplay()
      ? state.installCredential || state.installCookieClaimRetryAvailable
        ? t("pairingRetryCopy")
        : t("reinstallCopy")
      : t("installCopy");
    elements.pairingRetryButton.hidden = !(
      isStandaloneDisplay() &&
      (state.installCredential || state.installCookieClaimRetryAvailable)
    );
    setConnectionStatus(isInvalid ? "error" : "waiting", t("connecting"));
  }

  function plural(count, forms) {
    return count === 1 ? forms[0] : forms[1];
  }

  function formatPercent(value, digits = 0) {
    if (value == null || !Number.isFinite(Number(value))) return t("unavailable");
    return `${new Intl.NumberFormat(state.language === "zh" ? "zh-CN" : "en", {
      maximumFractionDigits: digits,
    }).format(Number(value))}%`;
  }

  function formatInteger(value) {
    const number = Number(value);
    if (!Number.isSafeInteger(number) || number < 0) return t("unavailable");
    return new Intl.NumberFormat(state.language === "zh" ? "zh-CN" : "en", {
      maximumFractionDigits: 0,
    }).format(number);
  }

  function formatDate(value, options = {}) {
    const date = new Date(value);
    if (!value || Number.isNaN(date.getTime())) return t("unavailable");
    return new Intl.DateTimeFormat(state.language === "zh" ? "zh-CN" : "en", {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      ...options,
    }).format(date);
  }

  function formatRelative(value) {
    const date = new Date(value);
    if (!value || Number.isNaN(date.getTime())) return t("unavailable");
    const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
    if (seconds < 10) return t("justNow");
    if (seconds < 60) return t("secondsAgo", { n: seconds });
    const minutes = Math.round(seconds / 60);
    if (minutes < 60) return t("minutesAgo", { n: minutes });
    const hours = Math.round(minutes / 60);
    if (hours < 24) return t("hoursAgo", { n: hours });
    return t("daysAgo", { n: Math.round(hours / 24) });
  }

  function formatDuration(value) {
    const seconds = Math.max(0, Math.round(safeNumber(value)));
    if (seconds < 60) return `${seconds}s`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
    const hours = Math.floor(seconds / 3600);
    return `${hours}h ${Math.floor((seconds % 3600) / 60)}m`;
  }

  function formatBytesPerSecond(value) {
    let bytes = Math.max(0, safeNumber(value));
    const units = ["B/s", "KB/s", "MB/s", "GB/s"];
    let unit = 0;
    while (bytes >= 1000 && unit < units.length - 1) {
      bytes /= 1000;
      unit += 1;
    }
    const digits = bytes >= 100 || unit === 0 ? 0 : bytes >= 10 ? 1 : 2;
    return `${bytes.toFixed(digits)} ${units[unit]}`;
  }

  function booleanText(value) {
    return value ? t("enabled") : t("disabled");
  }

  function statusClass(value) {
    if (["failed", "unavailable", "unreachable"].includes(value)) return "danger";
    if (["loading", "unknown", "idle", "notChecked"].includes(value)) return "warning";
    if (["active", "ready", "reachable", "installed"].includes(value)) return "good";
    return "";
  }

  function translatedStatus(value, detail) {
    const known = {
      unknown: "unknown",
      idle: "idle",
      active: "active",
      failed: "failed",
      notChecked: "notChecked",
      installed: "installed",
      helperMissing: "helperMissing",
      disabled: "disabled",
      requiresInstallation: "requiresInstallation",
      installing: "installing",
      checking: "checking",
      ready: "ready",
      lowBattery: "lowBattery",
      thermal: "thermal",
      maximumDuration: "maximumDuration",
      unavailable: "unavailableState",
      loading: "loading",
      reachable: "reachable",
      unreachable: "unreachable",
    };
    const label = t(known[value] || "unknown");
    return detail ? `${label} · ${detail}` : label;
  }

  function quotaTone(value) {
    if (value == null) return "";
    const percent = safeNumber(value);
    if (percent <= 0) return "danger";
    if (percent <= 20) return "warning";
    return "good";
  }

  function orderedQuotaModels(quota) {
    const models = [];
    let sourceIndex = 0;
    for (const provider of quota.providers || []) {
      for (const model of provider.models || []) {
        const suppliedOrder = Number(model.displayOrder);
        models.push({
          provider,
          model,
          sourceIndex,
          displayOrder: Number.isInteger(suppliedOrder)
            ? suppliedOrder
            : model.isPrimary === true
              ? 0
              : 1_000 + sourceIndex,
        });
        sourceIndex += 1;
      }
    }
    return models.sort((left, right) =>
      left.displayOrder - right.displayOrder ||
      left.sourceIndex - right.sourceIndex,
    );
  }

  function orderedUtilizationCycles(model) {
    return (Array.isArray(model?.cycles) ? model.cycles : [])
      .filter((cycle) =>
        Number.isFinite(new Date(cycle.resetsAt).getTime()) &&
        Number.isFinite(Number(cycle.usedPercent)),
      )
      .sort(
        (left, right) =>
          new Date(left.resetsAt).getTime() -
          new Date(right.resetsAt).getTime(),
      );
  }

  function cycleLeftPercent(cycle, model) {
    const cycleReset = new Date(cycle?.resetsAt).getTime();
    const currentReset = new Date(model?.resetsAt).getTime();
    const isCurrent =
      Number.isFinite(cycleReset) &&
      Number.isFinite(currentReset) &&
      Math.abs(cycleReset - currentReset) <= 120_000;
    if (isCurrent) return clamp(model?.remainingPercent, 0, 100);
    return 100 - clamp(cycle?.usedPercent, 0, 100);
  }

  function renderQuotaCycles(model) {
    const cycles = orderedUtilizationCycles(model);
    if (cycles.length === 0) return null;
    const label = t(model.isShortWindow === true ? "shortCycles" : "weeklyCycles");
    const section = element("div", "quota-cycles");
    const heading = element("div", "quota-cycles-heading");
    heading.append(
      element("span", "", label),
      element("span", "", t("cycleLabel")),
    );
    const bars = element("div", "quota-cycle-bars");
    bars.setAttribute("role", "img");
    bars.setAttribute("aria-label", `${label} · ${t("cycleLabel")}`);
    for (const cycle of cycles) {
      const left = cycleLeftPercent(cycle, model);
      const used = 100 - left;
      const bar = element("span", "quota-cycle-bar");
      if (left >= 100) bar.classList.add("is-unused");
      if (model.usesReverseProgressTint === true) {
        bar.classList.add("is-reverse");
      }
      const fill = element("span", "quota-cycle-used");
      fill.style.height = `${used.toFixed(2)}%`;
      bar.title = `${formatDate(cycle.resetsAt, {
        year: undefined,
        second: undefined,
      })} · ${Math.round(left)}% ${t("cycleLabel")}`;
      bar.setAttribute("aria-hidden", "true");
      bar.append(fill);
      bars.append(bar);
    }
    section.append(heading, bars);
    return section;
  }

  function renderQuota(quota, force) {
    const providerMix = state.activeProviderMix || "none";
    if (!hasChanged("quota", { quota, providerMix }, force)) return;
    elements.quotaTime.textContent = quota.lastRefreshAt
      ? formatRelative(quota.lastRefreshAt)
      : "";
    elements.quotaErrors.replaceChildren(
      ...(quota.errors || []).slice(0, 1).map((error) =>
          element("p", "notice notice-error", error),
        ),
    );

    if (quota.state === "loading" && !(quota.providers || []).length) {
      elements.quotaContent.replaceChildren(emptyState(t("loadingQuota")));
      return;
    }
    if (!(quota.providers || []).length) {
      elements.quotaContent.replaceChildren(emptyState(t("emptyQuota")));
      return;
    }

    const models = orderedQuotaModels(quota);
    if (providerMix === "kimi") {
      // Kimi-only activity: promote Kimi cards, demote (not hide) Codex.
      // The sort is stable, so the selected display order is kept per group.
      models.sort((left, right) =>
        (left.provider?.id === "kimi" ? 0 : 1) -
        (right.provider?.id === "kimi" ? 0 : 1),
      );
    }
    if (models.length === 0) {
      elements.quotaContent.replaceChildren(emptyState(t("emptyQuota")));
      return;
    }
    const charts = [];
    const matrix = element("div", "quota-matrix");
    const chartIndex = models.findIndex(
      ({ model }) => model.rendersAreaChart === true,
    );
    if (chartIndex >= 0) {
      const { provider, model } = models[chartIndex];
      matrix.classList.add("quota-matrix-has-chart");
      matrix.append(
        renderQuotaModel(
          provider,
          model,
          "quota-primary",
          quota.warningThresholdPercent,
          charts,
        ),
      );
    }
    models.forEach(({ provider, model }, index) => {
      if (index !== chartIndex) matrix.append(renderQuotaQuote(provider, model));
    });
    elements.quotaContent.replaceChildren(matrix);

    requestAnimationFrame(() => {
      for (const chart of charts) {
        drawQuotaAreaChart(
          chart.id,
          chart.model,
          chart.warningThresholdPercent,
        );
      }
    });
  }

  function renderQuotaModel(
    provider,
    model,
    chartID,
    warningThresholdPercent,
    charts,
  ) {
    const percentage = clamp(model.remainingPercent, 0, 100);
    const row = element("article", "quota-model-card");
    const heading = element("div", "quota-card-heading");
    const identity = element("div", "quota-identity");
    const providerName = provider.name || provider.id;
    const accountName = typeof model.accountName === "string"
      ? model.accountName
      : "";
    const identityPath = [providerName, accountName].filter(Boolean).join(" / ");
    identity.append(
      element("span", "quota-model", model.modelName || t("unknown")),
      element("span", "quota-path", identityPath),
    );

    const value = element("span", "quota-value", formatPercent(percentage));
    const tone = quotaTone(percentage);
    if (tone) value.classList.add(tone);
    if (model.paceDeltaPercent != null) {
      const delta = safeNumber(model.paceDeltaPercent);
      const pace = element(
        "small",
        delta >= 0 ? "good" : "warning",
        `${delta >= 0 ? "+" : "−"}${Math.abs(delta).toFixed(0)}%`,
      );
      value.append(pace);
    }
    heading.append(identity, value);

    const balance = [];
    if (model.total > 0) {
      balance.push(`${model.remaining}/${model.total}`);
    } else if (model.remainingText && !model.remainingText.includes("%")) {
      balance.push(model.remainingText);
    }
    if (model.weeklyUnlimited) {
      balance.push(state.language === "zh" ? "周 ∞" : "W ∞");
    } else if (model.weeklyTotal > 0) {
      const weeklyPercent =
        model.weeklyRemainingPercent == null
          ? (safeNumber(model.weeklyRemaining) / safeNumber(model.weeklyTotal, 1)) * 100
          : model.weeklyRemainingPercent;
      balance.push(
        `${state.language === "zh" ? "周" : "W"} ${formatPercent(weeklyPercent)}`,
      );
    }

    const chartWrap = element("div", "quota-chart-wrap");
    const samples = Array.isArray(model.samples) ? model.samples : [];
    const canvas = element("canvas", "quota-chart");
    canvas.id = `${chartID}-samples`;
    canvas.setAttribute("role", "img");
    canvas.setAttribute("aria-label", t("recentSamplesLabel"));
    chartWrap.append(canvas);
    if (samples.length < 2) {
      chartWrap.append(element("p", "quota-chart-empty", t("noSamples")));
    }
    charts.push({ id: canvas.id, model, warningThresholdPercent });

    const meta = element("div", "quota-card-meta");
    meta.append(
      element("span", "quota-balance", balance.join(" · ")),
      element(
        "span",
        "quota-reset",
        model.resetText
          ? `${t("resets")} ${model.resetText}`
          : model.resetsAt
            ? `${t("resets")} ${formatDate(model.resetsAt, {
                month: undefined,
                day: undefined,
                hour: "2-digit",
                minute: "2-digit",
              })}`
            : "",
      ),
    );
    row.setAttribute(
      "aria-label",
      `${providerName}, ${model.modelName}, ${formatPercent(percentage)}`,
    );
    const cycles = renderQuotaCycles(model);
    if (cycles) row.classList.add("has-cycles");
    row.append(heading, chartWrap, meta);
    if (cycles) row.append(cycles);
    return row;
  }

  function quotaResetText(model) {
    if (model.resetText) return model.resetText;
    if (model.resetsAt) {
      return formatDate(model.resetsAt, {
        month: undefined,
        day: undefined,
        hour: "2-digit",
        minute: "2-digit",
      });
    }
    return t("unavailable");
  }

  function quotaUsedText(model) {
    if (safeNumber(model.total) > 0) {
      const total = safeNumber(model.total);
      const used = Math.max(0, total - safeNumber(model.remaining));
      return `${used}/${total}`;
    }
    if (model.remainingText && !String(model.remainingText).includes("%")) {
      return String(model.remainingText);
    }
    return t("unavailable");
  }

  function quotaWeeklyText(model) {
    if (model.weeklyUnlimited) return "∞";
    if (safeNumber(model.weeklyTotal) > 0) {
      const percent = model.weeklyRemainingPercent == null
        ? safeNumber(model.weeklyRemaining) / safeNumber(model.weeklyTotal, 1) * 100
        : model.weeklyRemainingPercent;
      return formatPercent(percent);
    }
    return t("unavailable");
  }

  function renderQuotaQuote(provider, model) {
    const percentage = clamp(model.remainingPercent, 0, 100);
    const providerName = provider.name || provider.id || t("unknown");
    const accountName = typeof model.accountName === "string"
      ? model.accountName
      : "";
    const identityPath = [providerName, accountName].filter(Boolean).join(" / ");
    const strip = element("article", "quota-quote-strip");
    const identity = element("div", "quota-quote-identity");
    identity.append(
      element("span", "quota-quote-model", model.modelName || t("unknown")),
      element("span", "quota-quote-path", identityPath),
    );

    const quote = element("div", "quota-quote-value");
    const remaining = element("strong", quotaTone(percentage), formatPercent(percentage));
    quote.append(remaining);
    if (model.paceDeltaPercent != null) {
      const delta = safeNumber(model.paceDeltaPercent);
      quote.append(
        element(
          "span",
          delta >= 0 ? "good" : "warning",
          `${delta >= 0 ? "+" : "−"}${Math.abs(delta).toFixed(0)}%`,
        ),
      );
    }

    const facts = element("p", "quota-quote-facts");
    facts.append(
      element("span", "", `${t("usedCompact")} ${quotaUsedText(model)}`),
      element("span", "", `${t("weeklyBalance")} ${quotaWeeklyText(model)}`),
      element("span", "", `${t("resets")} ${quotaResetText(model)}`),
    );
    strip.setAttribute(
      "aria-label",
      `${providerName}, ${model.modelName}, ${formatPercent(percentage)}`,
    );
    strip.append(identity, quote, facts);
    return strip;
  }

  function compactRows(rows) {
    const list = element("div", "compact-list");
    for (const [label, value, cssClass = "", isPrimary = false] of rows) {
      const row = element("div", "compact-row");
      const valueNode = element("span", "compact-value");
      if (value instanceof Node) valueNode.append(value);
      else valueNode.textContent = String(value);
      if (cssClass) valueNode.classList.add(cssClass);
      if (isPrimary) valueNode.classList.add("compact-primary");
      row.append(element("span", "compact-label", label), valueNode);
      list.append(row);
    }
    return list;
  }

  function settingStateText(isEnabled, isEffective = null) {
    if (!isEnabled) return t("offCompact");
    if (isEffective === true) return `${t("onCompact")} · ${t("effective")}`;
    if (isEffective === false) return `${t("onCompact")} · ${t("standby")}`;
    return t("onCompact");
  }

  function statusWithAction(status, detail, actionRequired) {
    const value = translatedStatus(status, detail);
    return actionRequired ? `${value} · ${t("actionRequired")}` : value;
  }

  function tickerPhase(track) {
    const animation = track.getAnimations?.()[0];
    if (!animation) return null;
    const timing = animation.effect?.getComputedTiming?.();
    const duration = Number(timing?.duration);
    const currentTime = Number(animation.currentTime);
    if (!(duration > 0) || !Number.isFinite(currentTime)) return null;
    return ((currentTime % duration) + duration) % duration / duration;
  }

  function restoreTickerPhase(track, phase) {
    if (phase == null) return;
    const animation = track.getAnimations?.()[0];
    const duration = Number(animation?.effect?.getComputedTiming?.().duration);
    if (!animation || !(duration > 0)) return;
    animation.currentTime = phase * duration;
  }

  function createProtectionTicker(tickerItems) {
    const track = element("div", "ticker-track");
    const groups = [false, true].map((isDuplicate) => {
      const group = element("div", "ticker-group");
      if (isDuplicate) group.setAttribute("aria-hidden", "true");
      const items = tickerItems.map(() => {
        const item = element("span", "ticker-item");
        const keyNode = element("span", "ticker-key");
        const valueNode = element("strong", "ticker-value");
        item.append(keyNode, valueNode);
        group.append(item);
        return { keyNode, valueNode };
      });
      track.append(group);
      return items;
    });
    elements.protectionContent.replaceChildren(track);
    state.protectionTicker = { track, groups };
    return state.protectionTicker;
  }

  function updateProtectionTicker(tickerItems) {
    const semantic = fingerprint(tickerItems);
    let ticker = state.protectionTicker;
    if (!ticker?.track?.isConnected) {
      ticker = createProtectionTicker(tickerItems);
      state.protectionTickerSemantic = "";
    }
    if (semantic === state.protectionTickerSemantic) return;

    const phase = tickerPhase(ticker.track);
    for (const items of ticker.groups) {
      tickerItems.forEach(([label, value, cssClass = ""], index) => {
        const item = items[index];
        item.keyNode.textContent = label;
        item.valueNode.textContent = value;
        item.valueNode.className = "ticker-value";
        if (cssClass) item.valueNode.classList.add(cssClass);
      });
    }
    state.protectionTickerSemantic = semantic;
    restoreTickerPhase(ticker.track, phase);
  }

  function triggerStatusBoost(signal) {
    if (state.lastTaskSignal == null) {
      state.lastTaskSignal = signal;
      return;
    }
    if (state.lastTaskSignal === signal) return;
    state.lastTaskSignal = signal;
    resetOLEDIdleTimer();
    window.clearTimeout(state.statusBoostTimer);
    document.body.classList.remove("is-state-boosted");
    requestAnimationFrame(() => {
      document.body.classList.add("is-state-boosted");
      state.statusBoostTimer = window.setTimeout(() => {
        document.body.classList.remove("is-state-boosted");
      }, STATUS_BOOST_MS);
    });
  }

  function firstFiniteNumber(...values) {
    for (const value of values) {
      const number = Number(value);
      if (Number.isFinite(number)) return number;
    }
    return null;
  }

  function updateMenuBarSignal(snapshot) {
    const menuBar = snapshot?.menuBar || snapshot?.menuBarSnapshot || {};
    const codexWeekly =
      menuBar.codexWeekly || menuBar.codex || menuBar.weekly || {};
    const remaining = clamp(
      firstFiniteNumber(
        menuBar.ringPercent,
        codexWeekly.ringPercent,
        codexWeekly.remainingPercent,
        menuBar.remainingPercent,
        snapshot?.quota?.primaryRemainingPercent,
        0,
      ),
      0,
      100,
    );
    const pace = firstFiniteNumber(
      menuBar.paceDeltaPercent,
      codexWeekly.paceDelta,
      codexWeekly.paceDeltaPercent,
      menuBar.paceDelta,
    );
    document.body.dataset.capacityTone =
      remaining <= 20 ? "danger" : pace != null && pace < 0 ? "warning" : "good";
  }

  function normalizedActivitySummary(rawSummary, protection) {
    const hasSummary = rawSummary && typeof rawSummary === "object";
    const fallbackCount = Math.max(
      0,
      Math.min(99, Math.floor(safeNumber(protection?.activeTaskCount))),
    );
    const suppliedCount = Number(rawSummary?.activeTaskCount);
    const activeTaskCount = hasSummary && Number.isFinite(suppliedCount)
      ? Math.max(0, Math.min(99, Math.floor(suppliedCount)))
      : fallbackCount;
    const suppliedState = String(rawSummary?.state || "");
    const activityState = ACTIVITY_STATES.has(suppliedState)
      ? suppliedState
      : activeTaskCount > 0
        ? "working"
        : "idle";
    const suppliedPhase = String(rawSummary?.phase || "");
    const phase = Object.prototype.hasOwnProperty.call(
      ACTIVITY_PHASE_COPY_KEYS,
      suppliedPhase,
    )
      ? suppliedPhase
      : "unknown";
    const suppliedToolCategory = String(rawSummary?.toolCategory || "");
    const toolCategory = Object.prototype.hasOwnProperty.call(
      ACTIVITY_TOOL_CATEGORY_COPY_KEYS,
      suppliedToolCategory,
    )
      ? suppliedToolCategory
      : null;
    const suppliedToolStatus = String(rawSummary?.toolStatus || "");
    const toolStatus = Object.prototype.hasOwnProperty.call(
      ACTIVITY_TOOL_STATUS_COPY_KEYS,
      suppliedToolStatus,
    )
      ? suppliedToolStatus
      : null;
    const timestamp = (value) => {
      const milliseconds = new Date(value).getTime();
      return Number.isFinite(milliseconds) ? new Date(milliseconds).toISOString() : null;
    };
    const text = (value, maximum = 120) => {
      if (typeof value !== "string") return null;
      const normalized = value.replace(/\s+/gu, " ").trim();
      return normalized
        ? Array.from(normalized).slice(0, maximum).join("")
        : null;
    };
    const events = (value) => Array.isArray(value)
      ? value
          .map((event) => ({
            kind: Object.prototype.hasOwnProperty.call(
              ACTIVITY_EVENT_COPY_KEYS,
              event?.kind,
            )
              ? event.kind
              : null,
            at: timestamp(event?.at),
          }))
          .filter((event) => event.kind && event.at)
          .sort((left, right) =>
            new Date(right.at).getTime() - new Date(left.at).getTime(),
          )
          .slice(0, 5)
      : [];
    const elapsed = Number(rawSummary?.elapsedSeconds);
    const hasReliableDuration =
      activeTaskCount > 0 &&
      activityState === "working";
    const recentEvents = events(rawSummary?.recentEvents);
    const progressLines = hasReliableDuration && Array.isArray(rawSummary?.progressLines)
      ? rawSummary.progressLines
          .filter((line) => typeof line === "string")
          .map((line) => Array.from(line.trim()).slice(0, 160).join(""))
          .filter(Boolean)
          .slice(0, 2)
      : [];
    const tasks = Array.isArray(rawSummary?.tasks)
      ? rawSummary.tasks.slice(0, 99).map((task) => {
          const suppliedTaskState = String(task?.state || "");
          const taskState = ACTIVITY_STATES.has(suppliedTaskState)
            ? suppliedTaskState
            : activityState;
          const suppliedTaskPhase = String(task?.phase || "");
          const taskPhase = Object.prototype.hasOwnProperty.call(
            ACTIVITY_PHASE_COPY_KEYS,
            suppliedTaskPhase,
          )
            ? suppliedTaskPhase
            : "unknown";
          const suppliedTaskToolCategory = String(task?.toolCategory || "");
          const taskToolCategory = Object.prototype.hasOwnProperty.call(
            ACTIVITY_TOOL_CATEGORY_COPY_KEYS,
            suppliedTaskToolCategory,
          )
            ? suppliedTaskToolCategory
            : null;
          const suppliedTaskToolStatus = String(task?.toolStatus || "");
          const taskToolStatus = Object.prototype.hasOwnProperty.call(
            ACTIVITY_TOOL_STATUS_COPY_KEYS,
            suppliedTaskToolStatus,
          )
            ? suppliedTaskToolStatus
            : null;
          const taskElapsed = Number(task?.elapsedSeconds);
          const taskTokensUsed = Number(task?.tokensUsed);
          return {
            state: taskState,
            title: text(task?.title),
            projectName: text(task?.projectName, 64),
            gitBranch: text(task?.gitBranch, 64),
            source: text(task?.source, 64),
            model: text(task?.model, 64),
            modelProvider: text(task?.modelProvider, 64),
            reasoningEffort: text(task?.reasoningEffort, 64),
            sandboxPolicy: text(task?.sandboxPolicy, 64),
            approvalMode: text(task?.approvalMode, 64),
            tokensUsed:
              Number.isSafeInteger(taskTokensUsed) && taskTokensUsed >= 0
                ? taskTokensUsed
                : null,
            activeSubtaskCount: Math.max(
              0,
              Math.min(99, Math.floor(safeNumber(task?.activeSubtaskCount))),
            ),
            subtaskNames: Array.isArray(task?.subtaskNames)
              ? task.subtaskNames
                  .map((name) => text(name, 64))
                  .filter(Boolean)
                  .slice(0, 5)
              : [],
            createdAt: timestamp(task?.createdAt),
            startedAt: timestamp(task?.startedAt),
            elapsedSeconds:
              Number.isFinite(taskElapsed) && taskElapsed >= 0
                ? taskElapsed
                : null,
            lastActivityAt: timestamp(task?.lastActivityAt),
            cliVersion: text(task?.cliVersion, 64),
            phase: taskPhase,
            toolCategory: taskToolCategory,
            toolStatus: taskToolStatus,
            progressLines: Array.isArray(task?.progressLines)
              ? task.progressLines
                  .map((line) => text(line, 160))
                  .filter(Boolean)
                  .slice(0, 2)
              : [],
            recentEvents: events(task?.recentEvents),
          };
        })
      : [];
    return {
      state: activityState,
      activeTaskCount,
      phase,
      toolCategory,
      toolStatus,
      oldestStartedAt: hasReliableDuration
        ? timestamp(rawSummary?.oldestStartedAt)
        : null,
      elapsedSeconds:
        hasReliableDuration && Number.isFinite(elapsed) && elapsed >= 0
          ? elapsed
          : null,
      lastActivityAt:
        timestamp(rawSummary?.lastActivityAt) ||
        timestamp(protection?.lastActivityAt),
      recentEvents,
      progressLines,
      tasks,
    };
  }

  function activityDetailLines(summary) {
    if (summary.state !== "working" || summary.activeTaskCount === 0) return [];
    if (summary.progressLines.length > 0) return summary.progressLines.slice(0, 2);
    const lines = [t(ACTIVITY_PHASE_COPY_KEYS[summary.phase] || "phaseUnknown")];
    const toolParts = [
      summary.toolCategory
        ? t(ACTIVITY_TOOL_CATEGORY_COPY_KEYS[summary.toolCategory])
        : "",
      summary.toolStatus
        ? t(ACTIVITY_TOOL_STATUS_COPY_KEYS[summary.toolStatus])
        : "",
    ].filter(Boolean);
    if (toolParts.length > 0) {
      lines.push(`${t("activityTool")} · ${toolParts.join(" · ")}`);
    }
    return lines.slice(0, 2);
  }

  function taskTelemetryFieldSeed(
    task,
    index,
    salt = state.taskTelemetryOrderSalt,
  ) {
    let seed = (
      (Number(salt) >>> 0) ^ Math.imul(index + 1, 0x9e37_79b9)
    ) >>> 0;
    const stableIdentity = fingerprint([
      index,
      task.startedAt,
      task.title,
      task.projectName,
      task.createdAt,
      task.model,
    ]);
    for (const character of stableIdentity) {
      seed ^= character.codePointAt(0);
      seed = Math.imul(seed, 16_777_619) >>> 0;
    }
    return seed || 1;
  }

  function shuffledTaskTelemetryFragments(
    task,
    index,
    fragments,
    salt = state.taskTelemetryOrderSalt,
  ) {
    return shuffledCopy(
      fragments,
      seededRandom(taskTelemetryFieldSeed(task, index, salt)),
    );
  }

  function taskTelemetryFragments(
    summary,
    selectedFields = state.taskTelemetryFields,
  ) {
    if (!summary || summary.activeTaskCount === 0) return [];
    const detailedTasks = Array.isArray(summary.tasks) ? summary.tasks : [];
    const sourceTasks = detailedTasks.length > 0
      ? detailedTasks
      : Array.from({ length: summary.activeTaskCount }, () => ({
          state: summary.state,
          title: null,
          projectName: null,
          gitBranch: null,
          source: null,
          model: null,
          modelProvider: null,
          reasoningEffort: null,
          sandboxPolicy: null,
          approvalMode: null,
          tokensUsed: null,
          activeSubtaskCount: 0,
          subtaskNames: [],
          createdAt: null,
          startedAt: summary.oldestStartedAt,
          elapsedSeconds: summary.elapsedSeconds,
          lastActivityAt: summary.lastActivityAt,
          cliVersion: null,
          phase: summary.phase,
          toolCategory: summary.toolCategory,
          toolStatus: summary.toolStatus,
          progressLines: summary.progressLines,
          recentEvents: summary.recentEvents,
        }));
    const rows = sourceTasks
      .slice(0, TASK_TELEMETRY_MAX_LANES)
      .map((task, index) => {
        const taskLabel = t("taskTelemetryLabel", { n: index + 1 });
        const identity = [
          selectedFields.has("title")
            ? task.title || t("taskTelemetryUntitled")
            : "",
          selectedFields.has("state")
            ? task.state === "working"
              ? t("taskWorking")
              : task.state === "stale"
                ? t("activityStale")
                : t("unavailableState")
            : "",
          selectedFields.has("phase")
            ? t(ACTIVITY_PHASE_COPY_KEYS[task.phase] || "phaseUnknown")
            : "",
        ].filter(Boolean);
        const context = [
          selectedFields.has("project") && task.projectName
            ? `${t("taskTelemetryProject")} ${task.projectName}`
            : "",
          selectedFields.has("gitBranch") && task.gitBranch
            ? `${t("taskTelemetryBranch")} ${task.gitBranch}`
            : "",
          selectedFields.has("source") && task.source
            ? `${t("taskTelemetrySource")} ${task.source}`
            : "",
          selectedFields.has("model") && task.model
            ? `${t("taskTelemetryModel")} ${task.model}`
            : "",
          selectedFields.has("modelProvider") && task.modelProvider
            ? `${t("taskTelemetryProvider")} ${task.modelProvider}`
            : "",
          selectedFields.has("reasoningEffort") && task.reasoningEffort
            ? `${t("taskTelemetryReasoning")} ${task.reasoningEffort}`
            : "",
          selectedFields.has("sandboxPolicy") && task.sandboxPolicy
            ? `${t("taskTelemetrySandbox")} ${task.sandboxPolicy}`
            : "",
          selectedFields.has("approvalMode") && task.approvalMode
            ? `${t("taskTelemetryApproval")} ${task.approvalMode}`
            : "",
          selectedFields.has("tokensUsed") && task.tokensUsed != null
            ? `${t("taskTelemetryTokens")} ${formatInteger(task.tokensUsed)}`
            : "",
          selectedFields.has("activeSubtasks")
            ? t("taskTelemetrySubtasks", { n: task.activeSubtaskCount })
            : "",
          selectedFields.has("subtaskNames") && task.subtaskNames?.length > 0
            ? `${t("taskTelemetrySubtaskNames")} ${task.subtaskNames.join(" / ")}`
            : "",
        ].filter(Boolean);
        const tool = selectedFields.has("tool") ? [
          task.toolCategory
            ? t(ACTIVITY_TOOL_CATEGORY_COPY_KEYS[task.toolCategory])
            : "",
          task.toolStatus
            ? t(ACTIVITY_TOOL_STATUS_COPY_KEYS[task.toolStatus])
            : "",
        ].filter(Boolean) : [];
        const latestEvent = task.recentEvents[0] || null;
        const timing = [
          selectedFields.has("createdAt") && task.createdAt
            ? `${t("taskTelemetryCreated")} ${formatDate(task.createdAt)}`
            : "",
          selectedFields.has("startedAt") && task.startedAt
            ? `${t("taskTelemetryStarted")} ${formatDate(task.startedAt)}`
            : "",
          selectedFields.has("elapsed") && task.elapsedSeconds != null
            ? `${t("elapsed")} ${formatDuration(task.elapsedSeconds)}`
            : "",
          selectedFields.has("lastUpdated") && task.lastActivityAt
            ? `${t("taskTelemetryUpdated")} ${formatRelative(task.lastActivityAt)}`
            : "",
          selectedFields.has("cliVersion") && task.cliVersion
            ? `${t("taskTelemetryCLI")} ${task.cliVersion}`
            : "",
          tool.length > 0 ? `${t("activityTool")} ${tool.join(" · ")}` : "",
          selectedFields.has("recentEvent") && latestEvent
            ? `${t(ACTIVITY_EVENT_COPY_KEYS[latestEvent.kind])} ${formatRelative(
                latestEvent.at,
              )}`
            : "",
          ...(selectedFields.has("progress")
            ? task.progressLines || []
            : []),
        ].filter(Boolean);
        const randomizedFields = shuffledTaskTelemetryFragments(
          task,
          index,
          [...identity, ...context, ...timing],
        );
        return {
          key: fingerprint([
            index,
            task.startedAt,
            task.title,
            task.projectName,
            task.createdAt,
            task.model,
            TASK_TELEMETRY_FIELD_ORDER.filter((field) =>
              selectedFields.has(field),
            ),
          ]),
          text: [taskLabel, ...randomizedFields].join(" · "),
          ageSeconds:
            Number.isFinite(task.elapsedSeconds) && task.elapsedSeconds >= 0
              ? task.elapsedSeconds
              : null,
        };
      });
    return applyTaskTelemetrySpeedTiers(rows);
  }

  function taskTelemetryAgeTier(ageSeconds) {
    if (!Number.isFinite(ageSeconds) || ageSeconds < 0) return 0;
    return TASK_TELEMETRY_AGE_THRESHOLDS_SECONDS.reduce(
      (tier, threshold) => tier + (ageSeconds >= threshold ? 1 : 0),
      0,
    );
  }

  function applyTaskTelemetrySpeedTiers(rows) {
    const ranked = rows
      .filter((row) => Number.isFinite(row.ageSeconds) && row.ageSeconds >= 0)
      .sort((left, right) =>
        left.ageSeconds - right.ageSeconds || left.key.localeCompare(right.key),
      );
    ranked.forEach((row, relativeAgeRank) => {
      row.speedTier = Math.min(
        TASK_TELEMETRY_SPEEDS_PX_PER_SECOND.length - 1,
        Math.max(taskTelemetryAgeTier(row.ageSeconds), relativeAgeRank),
      );
    });
    rows.forEach((row) => {
      if (!Number.isInteger(row.speedTier)) row.speedTier = 0;
    });
    return rows;
  }

  function refreshTaskTelemetryViewportScale() {
    const rootSize = Number.parseFloat(
      window.getComputedStyle(document.documentElement).fontSize,
    );
    state.taskTelemetryViewportScale = Number.isFinite(rootSize) && rootSize > 0
      ? rootSize / TASK_TELEMETRY_REFERENCE_ROOT_FONT_SIZE_PX
      : 1;
    return state.taskTelemetryViewportScale;
  }

  function taskTelemetryViewportScale() {
    return state.taskTelemetryViewportScale;
  }

  function taskTelemetryGapPx() {
    return TASK_TELEMETRY_REFERENCE_GAP_PX * taskTelemetryViewportScale();
  }

  function taskTelemetrySpeedPxPerSecond(speedTier) {
    const tier = Math.min(
      TASK_TELEMETRY_SPEEDS_PX_PER_SECOND.length - 1,
      Math.max(0, Math.floor(Number(speedTier) || 0)),
    );
    return TASK_TELEMETRY_SPEEDS_PX_PER_SECOND[tier]
      * taskTelemetryViewportScale();
  }

  function taskTelemetryLaneState(lane) {
    let laneState = taskTelemetryLaneStates.get(lane);
    if (!laneState) {
      laneState = {
        taskKey: "",
        latestText: "",
        baseOffset: 0,
        animation: null,
        speedTier: 0,
        speedPxPerSecond: taskTelemetrySpeedPxPerSecond(0),
      };
      taskTelemetryLaneStates.set(lane, laneState);
    }
    return laneState;
  }

  function appendTaskTelemetryMessage(track, text) {
    track.append(element("span", "task-telemetry-item", text));
  }

  function resetTaskTelemetryLane(lane, taskRow) {
    const track = lane.firstElementChild;
    const laneState = taskTelemetryLaneState(lane);
    cancelTaskTelemetryLaneAnimation(lane);
    laneState.taskKey = taskRow.key;
    laneState.latestText = taskRow.text;
    laneState.baseOffset = Math.max(0, lane.clientWidth);
    track.style.transform =
      `translate3d(${-laneState.baseOffset}px, 0, 0)`;
    track.replaceChildren(
      element("span", "task-telemetry-item", taskRow.text),
    );
  }

  function setTaskTelemetryLaneSpeed(lane, speedTier) {
    const laneState = taskTelemetryLaneState(lane);
    const nextTier = Math.min(
      TASK_TELEMETRY_SPEEDS_PX_PER_SECOND.length - 1,
      Math.max(0, Math.floor(Number(speedTier) || 0)),
    );
    const nextSpeed = taskTelemetrySpeedPxPerSecond(nextTier);
    lane.dataset.telemetrySpeedTier = String(nextTier + 1);
    if (
      laneState.speedTier === nextTier &&
      laneState.speedPxPerSecond === nextSpeed
    ) return;
    laneState.speedTier = nextTier;
    laneState.speedPxPerSecond = nextSpeed;
    const playbackRate =
      nextSpeed / TASK_TELEMETRY_REFERENCE_SPEED_PX_PER_SECOND;
    if (typeof laneState.animation?.updatePlaybackRate === "function") {
      laneState.animation.updatePlaybackRate(playbackRate);
    } else if (laneState.animation) {
      laneState.animation.playbackRate = playbackRate;
    }
  }

  function taskTelemetryCurrentOffset(lane) {
    const laneState = taskTelemetryLaneState(lane);
    const currentTime = Number(laneState.animation?.currentTime);
    return laneState.baseOffset + (
      Number.isFinite(currentTime) && currentTime > 0
        ? TASK_TELEMETRY_REFERENCE_SPEED_PX_PER_SECOND * currentTime / 1_000
        : 0
    );
  }

  function cancelTaskTelemetryAnimation(animation) {
    if (!animation) return;
    animation.onfinish = null;
    animation.cancel();
  }

  function cancelTaskTelemetryLaneAnimation(lane, preserveOffset = false) {
    const laneState = taskTelemetryLaneStates.get(lane);
    const animation = laneState?.animation;
    if (!laneState || !animation) return;
    if (preserveOffset) {
      laneState.baseOffset = taskTelemetryCurrentOffset(lane);
    }
    laneState.animation = null;
    cancelTaskTelemetryAnimation(animation);
  }

  function disposeTaskTelemetryLane(lane) {
    if (!lane) return;
    const track = lane.firstElementChild;
    const laneState = taskTelemetryLaneStates.get(lane);
    const ownedAnimation = laneState?.animation || null;
    cancelTaskTelemetryLaneAnimation(lane);
    for (const animation of track?.getAnimations?.() || []) {
      if (animation !== ownedAnimation) cancelTaskTelemetryAnimation(animation);
    }
    taskTelemetryLaneStates.delete(lane);
    lane.replaceChildren();
    lane.remove();
  }

  function startTaskTelemetryLaneAnimation(lane, offset = null) {
    const track = lane.firstElementChild;
    const laneState = taskTelemetryLaneState(lane);
    if (!track || laneState.animation || !taskTelemetryMotionAllowed()) return;
    laneState.baseOffset = offset == null
      ? laneState.baseOffset
      : Math.max(0, offset);
    const startOffset = laneState.baseOffset;
    const endOffset = startOffset + TASK_TELEMETRY_ANIMATION_DISTANCE_PX;
    const animation = track.animate(
      [
        { transform: `translate3d(${-startOffset}px, 0, 0)` },
        { transform: `translate3d(${-endOffset}px, 0, 0)` },
      ],
      {
        duration:
          TASK_TELEMETRY_ANIMATION_DISTANCE_PX
          / TASK_TELEMETRY_REFERENCE_SPEED_PX_PER_SECOND * 1_000,
        easing: "linear",
        fill: "both",
      },
    );
    laneState.animation = animation;
    const playbackRate =
      laneState.speedPxPerSecond
      / TASK_TELEMETRY_REFERENCE_SPEED_PX_PER_SECOND;
    if (typeof animation.updatePlaybackRate === "function") {
      animation.updatePlaybackRate(playbackRate);
    } else {
      animation.playbackRate = playbackRate;
    }
    animation.onfinish = () => {
      if (laneState.animation !== animation) return;
      animation.onfinish = null;
      laneState.animation = null;
      animation.cancel();
      laneState.baseOffset = endOffset;
      maintainTaskTelemetryLane(lane);
      startTaskTelemetryLaneAnimation(lane);
    };
  }

  function restartTaskTelemetryLaneAnimation(lane, offset) {
    const track = lane.firstElementChild;
    const laneState = taskTelemetryLaneState(lane);
    cancelTaskTelemetryLaneAnimation(lane);
    laneState.baseOffset = Math.max(0, offset);
    if (track) {
      track.style.transform =
        `translate3d(${-laneState.baseOffset}px, 0, 0)`;
    }
    startTaskTelemetryLaneAnimation(lane);
  }

  function ensureTaskTelemetryTail(lane, offset) {
    const track = lane.firstElementChild;
    const laneState = taskTelemetryLaneState(lane);
    const tail = track?.lastElementChild;
    if (!track || !laneState.latestText) return;
    if (!tail || tail.offsetLeft <= offset + taskTelemetryGapPx()) {
      appendTaskTelemetryMessage(track, laneState.latestText);
    }
  }

  function updateTaskTelemetryLane(lane, taskRow) {
    const track = lane.firstElementChild;
    const laneState = taskTelemetryLaneState(lane);
    if (laneState.taskKey !== taskRow.key) {
      resetTaskTelemetryLane(lane, taskRow);
      return;
    }
    if (laneState.latestText === taskRow.text) return;
    laneState.latestText = taskRow.text;
    const tail = track.lastElementChild;
    const offset = taskTelemetryCurrentOffset(lane);
    if (
      tail &&
      tail.offsetLeft > offset + taskTelemetryGapPx()
    ) {
      // The tail message has not entered the lane yet, so coalescing the latest
      // snapshot here cannot change any visible glyph or preceding position.
      tail.textContent = taskRow.text;
      return;
    }
    appendTaskTelemetryMessage(track, taskRow.text);
  }

  function maintainTaskTelemetryLane(lane) {
    const track = lane.firstElementChild;
    const laneState = taskTelemetryLaneState(lane);
    if (!track) return;
    let offset = taskTelemetryCurrentOffset(lane);
    let removedWidth = 0;

    let first = track.firstElementChild;
    while (
      track.childElementCount > 1 &&
      first &&
      offset > lane.clientWidth + first.offsetWidth
    ) {
      const consumedWidth = first.offsetWidth + taskTelemetryGapPx();
      first.remove();
      offset = Math.max(0, offset - consumedWidth);
      removedWidth += consumedWidth;
      first = track.firstElementChild;
    }
    if (removedWidth > 0) restartTaskTelemetryLaneAnimation(lane, offset);
    ensureTaskTelemetryTail(lane, offset);
  }

  function stopTaskTelemetryMotion() {
    window.clearInterval(state.taskTelemetryMaintenanceTimer);
    state.taskTelemetryMaintenanceTimer = null;
    for (const lane of elements.taskTelemetryMarquee.children) {
      const track = lane.firstElementChild;
      const laneState = taskTelemetryLaneState(lane);
      if (!laneState.animation) continue;
      cancelTaskTelemetryLaneAnimation(lane, true);
      if (track) {
        track.style.transform =
          `translate3d(${-laneState.baseOffset}px, 0, 0)`;
      }
    }
  }

  function taskTelemetryMotionAllowed() {
    return (
      state.activityBackgroundEffect === "taskTelemetryMarquee" &&
      state.activitySummary?.state === "working" &&
      state.activitySummary.activeTaskCount > 0 &&
      state.connected &&
      !document.hidden &&
      !window.matchMedia("(prefers-reduced-motion: reduce)").matches
    );
  }

  function configureTaskTelemetryMotion() {
    if (!taskTelemetryMotionAllowed()) {
      stopTaskTelemetryMotion();
      return;
    }
    for (const lane of elements.taskTelemetryMarquee.children) {
      maintainTaskTelemetryLane(lane);
      startTaskTelemetryLaneAnimation(lane);
    }
    if (state.taskTelemetryMaintenanceTimer != null) return;
    state.taskTelemetryMaintenanceTimer = window.setInterval(() => {
      if (!taskTelemetryMotionAllowed()) {
        stopTaskTelemetryMotion();
        return;
      }
      for (const lane of elements.taskTelemetryMarquee.children) {
        maintainTaskTelemetryLane(lane);
      }
    }, TASK_TELEMETRY_MAINTENANCE_MS);
  }

  function renderTaskTelemetryMarquee(summary, force = false) {
    refreshTaskTelemetryViewportScale();
    const taskRows = taskTelemetryFragments(summary);
    const container = elements.taskTelemetryMarquee;
    if (!container) return;
    if (!hasChanged("taskTelemetryMarquee", taskRows, force)) {
      configureTaskTelemetryMotion();
      return;
    }
    if (taskRows.length === 0) {
      stopTaskTelemetryMotion();
      for (const lane of Array.from(container.children)) {
        disposeTaskTelemetryLane(lane);
      }
      container.replaceChildren();
      return;
    }
    const laneCount = taskRows.length;
    const fontSizeByLaneCount = ["", "68cqh", "28cqh", "20cqh", "16cqh", "13cqh"];

    // Keep every surviving track node mounted. Activity snapshots update once
    // per second; each lane owns one task and an append-only moving stream.
    while (container.childElementCount < laneCount) {
      const lane = element("div", "task-telemetry-lane");
      lane.append(element("div", "task-telemetry-track"));
      container.append(lane);
    }
    while (container.childElementCount > laneCount) {
      disposeTaskTelemetryLane(container.lastElementChild);
    }

    Array.from(container.children).forEach((lane, index) => {
      const geometry = `${index}:${laneCount}`;
      if (lane.dataset.telemetryGeometry !== geometry) {
        lane.style.setProperty(
          "--telemetry-lane-start",
          `${(index * 100) / laneCount}%`,
        );
        lane.style.setProperty(
          "--telemetry-lane-height",
          `${100 / laneCount}%`,
        );
        lane.style.setProperty(
          "--telemetry-font-size",
          fontSizeByLaneCount[laneCount],
        );
        lane.dataset.telemetryGeometry = geometry;
      }
      updateTaskTelemetryLane(lane, taskRows[index]);
      setTaskTelemetryLaneSpeed(lane, taskRows[index].speedTier);
      ensureTaskTelemetryTail(lane, taskTelemetryCurrentOffset(lane));
    });
    configureTaskTelemetryMotion();
  }

  function renderActivityTelemetry(summary, warning = "", detailLines = []) {
    const count = summary.activeTaskCount;
    const signalQualifier = summary.state === "stale"
      ? t("activityStale")
      : summary.state === "unavailable"
        ? t("unavailableState")
        : "";
    const detail = count > 0
      ? `${t("workingDetail", { n: count })}${
          signalQualifier ? ` · ${signalQualifier}` : ""
        }`
      : t("idleDetail");
    elements.taskStateDetail.textContent = detail;
    elements.taskStateWarning.hidden = !warning;
    elements.taskStateWarning.textContent = warning;

    const approvedDetails = Array.isArray(detailLines)
      ? detailLines.filter((line) => typeof line === "string" && line).slice(0, 2)
      : [];
    let durationText = approvedDetails[0] || "";
    if (!durationText && summary.activeTaskCount > 0) {
      if (summary.elapsedSeconds != null) {
        durationText = `${t("elapsed")} · ${formatDuration(summary.elapsedSeconds)}`;
      } else if (summary.oldestStartedAt) {
        durationText = `${t("oldestActive")} · ${formatRelative(
          summary.oldestStartedAt,
        )}`;
      }
    }

    const latestEvent = summary.recentEvents[0] || null;
    const latestEventAt = latestEvent
      ? new Date(latestEvent.at).getTime()
      : Number.NEGATIVE_INFINITY;
    const lastActivityAt = summary.lastActivityAt
      ? new Date(summary.lastActivityAt).getTime()
      : Number.NEGATIVE_INFINITY;
    let recentText = approvedDetails[1] || "";
    if (!recentText && latestEvent && latestEventAt >= lastActivityAt) {
      recentText = `${t(ACTIVITY_EVENT_COPY_KEYS[latestEvent.kind])} · ${formatRelative(
        latestEvent.at,
      )}`;
    } else if (!recentText && Number.isFinite(lastActivityAt)) {
      recentText = `${t("lastActivity")} · ${formatRelative(
        summary.lastActivityAt,
      )}`;
    }

    const optionalLines = count === 0
      ? []
      : warning
        ? [durationText || recentText]
        : [durationText, recentText];
    [elements.taskDuration, elements.taskRecentActivity].forEach(
      (node, index) => {
        const text = optionalLines[index] || "";
        node.hidden = !text;
        node.textContent = text;
      },
    );
    return [detail, warning, ...optionalLines].filter(Boolean).slice(0, 3);
  }

  function taskRainProfile(taskCount) {
    const count = Math.max(0, Math.floor(safeNumber(taskCount)));
    if (count <= 1) return { columns: 18, framesPerSecond: 5 };
    if (count === 2) return { columns: 24, framesPerSecond: 6 };
    return { columns: 30, framesPerSecond: 7 };
  }

  function taskRainSeed(summary) {
    const stateCodes = { idle: 1, working: 2, stale: 3, unavailable: 4 };
    const eventKinds = Object.keys(ACTIVITY_EVENT_COPY_KEYS);
    let seed = 2_166_136_261 ^ (stateCodes[summary.state] || 0);
    const mix = (number) => {
      seed ^= Math.floor(safeNumber(number)) >>> 0;
      seed = Math.imul(seed, 16_777_619) >>> 0;
    };
    const mixString = (value) => {
      for (const character of String(value || "")) {
        mix(character.codePointAt(0));
      }
    };
    mix(summary.activeTaskCount);
    mixString(summary.phase);
    mixString(summary.toolCategory);
    mixString(summary.toolStatus);
    for (const value of [summary.oldestStartedAt, summary.lastActivityAt]) {
      const milliseconds = new Date(value).getTime();
      if (Number.isFinite(milliseconds)) mix(Math.floor(milliseconds / 1_000));
    }
    for (const event of summary.recentEvents) {
      mix(eventKinds.indexOf(event.kind) + 1);
      const milliseconds = new Date(event.at).getTime();
      if (Number.isFinite(milliseconds)) mix(Math.floor(milliseconds / 1_000));
    }
    for (const line of summary.progressLines || []) mixString(line);
    return seed || 1;
  }

  function seededRandom(seed) {
    let value = seed >>> 0;
    return () => {
      value = (Math.imul(value, 1_664_525) + 1_013_904_223) >>> 0;
      return value / 4_294_967_296;
    };
  }

  function stopTaskRain({ clear = false } = {}) {
    state.rainGeneration += 1;
    window.clearTimeout(state.rainTimer);
    state.rainTimer = null;
    if (!clear) return;
    const canvas = elements.matrixRainCanvas;
    const context = canvas.getContext("2d");
    context?.clearRect(0, 0, canvas.width, canvas.height);
  }

  function taskRainDPR() {
    const memory = Number(navigator.deviceMemory);
    const cap = Number.isFinite(memory) && memory <= 4 ? 1 : 1.25;
    return Math.max(1, Math.min(cap, window.devicePixelRatio || 1));
  }

  function drawTaskRainFrame(context, width, height, dpr, seed) {
    context.setTransform(dpr, 0, 0, dpr, 0, 0);
    context.clearRect(0, 0, width, height);
    const grainRandom = seededRandom(
      seed ^ Math.imul(state.rainFrame + 1, 0x9e3779b9),
    );
    const grainCount = Math.min(72, Math.max(24, Math.floor(width * height / 1_100)));
    const rainRGB = cssToken("--rain-rgb", "112, 201, 130");
    const rainHeadRGB = cssToken("--rain-head-rgb", "184, 246, 194");
    context.fillStyle = `rgba(${rainRGB}, 0.065)`;
    for (let index = 0; index < grainCount; index += 1) {
      context.fillRect(
        Math.floor(grainRandom() * width),
        Math.floor(grainRandom() * height),
        1,
        1,
      );
    }

    const fontSize = 10;
    const rowCount = Math.max(1, Math.ceil(height / fontSize));
    for (const [columnIndex, column] of state.rainColumns.entries()) {
      column.head += column.speed;
      if (column.head > rowCount) column.head -= rowCount;
      const headRow = Math.floor(column.head) % rowCount;
      for (let tail = column.tailLength; tail >= 1; tail -= 1) {
        const row = (headRow - tail + rowCount) % rowCount;
        const y = row * fontSize;
        const strength = 1 - tail / (column.tailLength + 1);
        const alpha = 0.045 + 0.255 * Math.pow(strength, 1.4);
        context.fillStyle = `rgba(${rainRGB}, ${alpha.toFixed(3)})`;
        const glyphIndex = (
          column.glyphOffset + state.rainFrame + columnIndex * 3 - tail
        ) % MATRIX_GLYPHS.length;
        context.fillText(
          MATRIX_GLYPHS[(glyphIndex + MATRIX_GLYPHS.length) % MATRIX_GLYPHS.length],
          column.x,
          y,
        );
      }
    }
    context.fillStyle = `rgba(${rainHeadRGB}, 0.72)`;
    for (const [columnIndex, column] of state.rainColumns.entries()) {
      const y = (Math.floor(column.head) % rowCount) * fontSize;
      const glyphIndex = (
        column.glyphOffset + state.rainFrame + columnIndex * 3
      ) % MATRIX_GLYPHS.length;
      context.fillText(MATRIX_GLYPHS[glyphIndex], column.x, y);
    }
    state.rainFrame += 1;
  }

  function configureTaskRain(force = false) {
    const summary = state.activitySummary;
    const canvas = elements.matrixRainCanvas;
    const isWorking =
      summary?.activeTaskCount > 0 &&
      summary?.state === "working";
    const effectCanDraw =
      state.activityBackgroundEffect === "grainyDigitalRain" &&
      isWorking &&
      state.connected &&
      !document.hidden;
    if (!effectCanDraw) {
      if (state.rainKey !== "inactive") {
        state.rainKey = "inactive";
        stopTaskRain({ clear: true });
      }
      return;
    }
    const bounds = canvas.getBoundingClientRect();
    const reducedMotion = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
    const shouldDraw =
      bounds.width > 0 &&
      bounds.height > 0;
    const seed = summary ? taskRainSeed(summary) : 1;
    const profile = taskRainProfile(summary?.activeTaskCount || 0);
    const key = [
      shouldDraw,
      reducedMotion,
      profile.columns,
      seed,
      Math.round(bounds.width),
      Math.round(bounds.height),
    ].join(":");
    if (!force && state.rainKey === key && (state.rainTimer || reducedMotion)) {
      return;
    }
    state.rainKey = key;
    stopTaskRain({ clear: !shouldDraw });
    if (!shouldDraw) return;

    const dpr = taskRainDPR();
    canvas.width = Math.max(1, Math.round(bounds.width * dpr));
    canvas.height = Math.max(1, Math.round(bounds.height * dpr));
    const context = canvas.getContext("2d", {
      alpha: true,
      desynchronized: true,
    });
    if (!context) return;
    context.font = '700 10px "DIN Alternate", "Avenir Next Condensed", sans-serif';
    context.textAlign = "center";
    context.textBaseline = "top";
    const random = seededRandom(seed);
    state.rainColumns = Array.from({ length: profile.columns }, (_, index) => ({
      x: ((index + 0.5) / profile.columns) * bounds.width,
      head: random() * Math.max(1, Math.ceil(bounds.height / 10)),
      speed: 0.65 + random() * 0.5,
      tailLength: 4 + Math.floor(random() * 5),
      glyphOffset: Math.floor(random() * MATRIX_GLYPHS.length),
    }));
    state.rainFrame = 0;
    const generation = state.rainGeneration;
    const draw = () => {
      if (generation !== state.rainGeneration) return;
      drawTaskRainFrame(context, bounds.width, bounds.height, dpr, seed);
      if (reducedMotion) return;
      state.rainTimer = window.setTimeout(
        draw,
        1_000 / profile.framesPerSecond,
      );
    };
    draw();
  }

  function updateEnergyWave(tasks, isActive) {
    const poweredWaves = isActive
      ? Math.min(5, Math.max(0, Math.floor(safeNumber(tasks))))
      : 0;
    document.querySelectorAll(".task-wave").forEach((wave, index) => {
      wave.classList.toggle("is-powered", index < poweredWaves);
    });
    document.body.dataset.taskWaves = String(poweredWaves);
  }

  // Resolves which providers have working tasks: "none", "kimi", "codex",
  // or "mixed". Prefers the snapshot's `activeProviders` field and derives
  // from working tasks when the field is absent (older snapshots).
  function activityProviderMix(rawSummary) {
    if (
      !rawSummary ||
      rawSummary.state !== "working" ||
      safeNumber(rawSummary.activeTaskCount) <= 0
    ) {
      return "none";
    }
    const providers = [];
    const addProvider = (provider) => {
      if (
        (provider === "kimi" || provider === "codex") &&
        !providers.includes(provider)
      ) {
        providers.push(provider);
      }
    };
    if (Array.isArray(rawSummary.activeProviders)) {
      rawSummary.activeProviders.forEach(addProvider);
    } else {
      (Array.isArray(rawSummary.tasks) ? rawSummary.tasks : [])
        .filter((task) => task?.state === "working")
        .forEach((task) => {
          addProvider(
            task.source === "Kimi Code" ||
              /kimi/i.test(String(task.modelProvider || ""))
              ? "kimi"
              : "codex",
          );
        });
    }
    if (providers.length === 0) return "none";
    return providers.length === 1 ? providers[0] : "mixed";
  }

  function commitTaskState(tasks) {
    const active = typeof state.explicitHasActiveTasks === "boolean"
      ? state.explicitHasActiveTasks
      : tasks > 0;
    const protection = state.latestProtection;
    const protectionIssue = protection?.isEnabled === false
      ? "off"
      : protection?.status === "failed"
        ? "failed"
        : null;
    const dashboardState = active
      ? "active"
      : protectionIssue || "idle";
    const stateCopy = {
      active: {
        title: t("taskWorking"),
      },
      idle: {
        title: t("taskIdle"),
      },
      off: {
        title: t("dashboardProtectionOff"),
      },
      failed: {
        title: t("dashboardProtectionFailed"),
      },
    }[dashboardState];
    triggerStatusBoost(`${dashboardState}:${tasks}`);
    state.displayedActiveTaskCount = tasks;
    document.body.dataset.taskState = active ? "active" : "idle";
    document.body.dataset.dashboardState = dashboardState;
    document.body.dataset.protectionIssue = protectionIssue || "none";
    const providerMix = active
      ? state.activeProviderMix || "none"
      : "none";
    document.body.dataset.activeProviders = providerMix;
    elements.taskStateKicker.textContent = t(
      providerMix === "kimi"
        ? "taskStateKickerKimi"
        : providerMix === "mixed"
          ? "taskStateKickerGeneric"
          : "taskStateKicker",
    );
    elements.taskStateTitle.textContent = stateCopy.title;
    elements.taskWatermark.textContent = stateCopy.title;
    elements.taskHero.setAttribute(
      "aria-label",
      [
        stateCopy.title,
        elements.taskStateDetail.textContent,
        elements.taskStateWarning.hidden
          ? ""
          : elements.taskStateWarning.textContent,
        elements.taskDuration.hidden ? "" : elements.taskDuration.textContent,
        elements.taskRecentActivity.hidden
          ? ""
          : elements.taskRecentActivity.textContent,
      ].filter(Boolean).join(". "),
    );
    updateEnergyWave(tasks, active);
  }

  function updateTaskState(tasks, immediateIdle = false) {
    window.clearTimeout(state.idleConfirmTimer);
    state.idleConfirmTimer = null;
    if (tasks > 0 || immediateIdle || state.displayedActiveTaskCount == null) {
      commitTaskState(tasks);
      return;
    }
    if (state.displayedActiveTaskCount === 0) {
      commitTaskState(0);
      return;
    }
    state.idleConfirmTimer = window.setTimeout(() => {
      state.idleConfirmTimer = null;
      commitTaskState(0);
    }, IDLE_CONFIRM_MS);
  }

  function renderProtection(protection, force, rawActivitySummary = null) {
    if (!hasChanged(
      "protection",
      { protection, activitySummary: rawActivitySummary },
      force,
    )) return;
    const activitySummary = normalizedActivitySummary(
      rawActivitySummary,
      protection,
    );
    const reportedTasks = activitySummary.activeTaskCount;
    const tasks = activitySummary.state === "working" ? reportedTasks : 0;
    state.latestProtection = protection;
    state.activitySummary = activitySummary;
    renderTaskTelemetryMarquee(activitySummary, force);
    state.explicitHasActiveTasks = tasks > 0;
    const protectionIssue = protection?.isEnabled === false
      ? "off"
      : protection?.status === "failed"
        ? "failed"
        : null;
    const warning = reportedTasks > 0 && protectionIssue
      ? t(
          protectionIssue === "off"
            ? "activeProtectionOffWarning"
            : "activeProtectionFailedWarning",
        )
      : "";
    renderActivityTelemetry(
      activitySummary,
      warning,
      activityDetailLines(activitySummary),
    );
    updateTaskState(tasks, activitySummary.state !== "idle");
    configureTaskRain();
    const closedLidDetail =
      protection.closedLidStatus === "lowBattery" && protection.closedLidDetail
        ? `${protection.closedLidDetail}%`
        : protection.closedLidDetail;
    const keepDisplayEffective =
      typeof protection.keepDisplayAwakeEffective === "boolean"
        ? protection.keepDisplayAwakeEffective
        : protection.isEnabled &&
          protection.status === "active" &&
          protection.keepDisplayAwake;
    const preventSaverEffective =
      typeof protection.preventScreenSaverEffective === "boolean"
        ? protection.preventScreenSaverEffective
        : keepDisplayEffective && protection.preventScreenSaver;
    const hookActionRequired = protection.hookActionRequired === true;
    const closedLidActionRequired =
      protection.closedLidActionRequired === true;
    const tickerItems = [
      [
        t("protectionMaster"),
        protection.isEnabled
          ? `${t("onCompact")} · ${tasks} ${t("taskUnit")[tasks === 1 ? 0 : 1]}`
          : t("offCompact"),
        statusClass(protection.status),
        true,
      ],
      [
        t("displayAwake"),
        settingStateText(
          protection.keepDisplayAwake,
          keepDisplayEffective,
        ),
        keepDisplayEffective ? "good" : "",
      ],
      [
        t("screenSaver"),
        settingStateText(
          protection.preventScreenSaver,
          preventSaverEffective,
        ),
        preventSaverEffective ? "good" : "",
      ],
      [
        t("closedLid"),
        protection.closedLidEnabled
          ? `${t("onCompact")} · ${translatedStatus(
              protection.closedLidStatus,
              closedLidDetail,
            )}`
          : t("offCompact"),
        statusClass(protection.closedLidStatus),
      ],
      [
        t("activityHook"),
        statusWithAction(
          protection.hookStatus,
          null,
          hookActionRequired,
        ),
        hookActionRequired ? "warning" : statusClass(protection.hookStatus),
      ],
      [
        t("sleepHelper"),
        statusWithAction(
          protection.closedLidStatus,
          closedLidDetail,
          closedLidActionRequired,
        ),
        closedLidActionRequired
          ? "warning"
          : statusClass(protection.closedLidStatus),
      ],
    ];
    updateProtectionTicker(tickerItems);
  }

  function compressedRouteTarget(fromRoute, toRoute) {
    const from = String(fromRoute || "");
    const to = String(toRoute || "");
    if (!from || !to || from === to) return to || from;

    const graphemes = (value) => {
      if (typeof Intl.Segmenter === "function") {
        return [...new Intl.Segmenter(undefined, { granularity: "grapheme" })
          .segment(value)]
          .map((segment) => segment.segment);
      }
      return Array.from(value);
    };
    const left = graphemes(from);
    const right = graphemes(to);
    const maximum = Math.min(left.length, right.length);
    let commonCount = 0;
    while (
      commonCount < maximum &&
      left[commonCount] === right[commonCount]
    ) {
      commonCount += 1;
    }
    if (commonCount === 0 || commonCount === right.length) return to;

    const isSeparator = (value) => /^[\s\-_/.:#]$/u.test(value);
    const isDigit = (value) => /^\p{Number}$/u.test(value);
    const isMeaningful = (value) =>
      /[\p{Letter}\p{Number}\p{Extended_Pictographic}\p{Regional_Indicator}]/u
        .test(value);
    let tokenStart = -1;
    for (let index = 1; index <= commonCount; index += 1) {
      if (isSeparator(right[index - 1])) tokenStart = index;
      if (
        index < right.length &&
        isDigit(right[index]) &&
        !isDigit(right[index - 1])
      ) {
        tokenStart = index;
      }
    }
    if (tokenStart < 0 || tokenStart > commonCount) return to;
    const meaningfulPrefixLength = right
      .slice(0, tokenStart)
      .filter(isMeaningful).length;
    if (meaningfulPrefixLength < 3) return to;
    const tail = right.slice(tokenStart).join("");
    return tail ? tail : to;
  }

  function routeTransitionText(fromRoute, toRoute) {
    const from = String(fromRoute || "");
    const to = String(toRoute || "");
    if (!from || !to || from === to) return from || to;
    return `${from} → ${compressedRouteTarget(from, to)}`;
  }

  function splitTailPreservedText(value, leadCount = 12, tailCount = 10) {
    const text = String(value || "");
    const graphemes = typeof Intl.Segmenter === "function"
      ? [...new Intl.Segmenter(undefined, { granularity: "grapheme" })
          .segment(text)]
          .map((segment) => segment.segment)
      : Array.from(text);
    if (graphemes.length <= leadCount + tailCount + 2) {
      return { lead: text, tail: "" };
    }
    return {
      lead: graphemes.slice(0, leadCount).join(""),
      tail: `…${graphemes.slice(-tailCount).join("")}`,
    };
  }

  function appendTailPreservedText(node, value) {
    const parts = splitTailPreservedText(value);
    node.append(element("span", "tail-preserved-lead", parts.lead));
    if (parts.tail) {
      node.append(element("span", "tail-preserved-tail", parts.tail));
    }
  }

  function renderRoute(route, force) {
    if (!hasChanged("route", route, force)) return;
    const status = route.isSpeedTesting
      ? t("speedTesting")
      : translatedStatus(route.state);
    const delay =
      route.selectedRouteDelay == null
        ? t("unavailable")
        : `${route.selectedRouteDelay} ms`;
    const switches = route.recentSwitches || [];
    const routeValue = element("span", "route-live-value");
    const routeName = element("span", "route-live-name");
    appendTailPreservedText(
      routeName,
      route.selectedRouteName || t("unavailable"),
    );
    if (route.selectedRouteName) routeName.title = route.selectedRouteName;
    routeValue.append(routeName);
    if (route.selectedRouteName) {
      routeValue.append(element("span", "route-live-delay", delay));
    }
    const rows = compactRows([
      [
        t("route"),
        routeValue,
        route.selectedRouteName ? "good" : "",
        true,
      ],
      [
        t("status"),
        `${status} · ${route.autoRecoveryEnabled ? t("autoRecovery") : t("client")}`,
        statusClass(route.state),
      ],
    ]);
    const latestSwitch = switches[0];
    if (!latestSwitch) {
      elements.routeContent.replaceChildren(rows);
      return;
    }
    const switchSummary = element("div", "route-switch");
    const switchValue = element("span", "route-switch-value");
    const fromRoute = String(latestSwitch.fromRoute || "");
    const toRoute = String(latestSwitch.toRoute || "");
    if (!fromRoute || !toRoute || fromRoute === toRoute) {
      const path = element(
        "span",
        "route-switch-target",
        fromRoute || toRoute,
      );
      path.title = fromRoute || toRoute;
      switchValue.append(path);
    } else {
      const from = element("span", "route-switch-from", fromRoute);
      from.title = fromRoute;
      const targetText = compressedRouteTarget(fromRoute, toRoute);
      const target = element("span", "route-switch-target");
      appendTailPreservedText(target, targetText);
      target.title = toRoute;
      switchValue.append(
        from,
        element("span", "route-switch-arrow", "→"),
        target,
      );
    }
    switchValue.append(
      element(
        "time",
        "route-switch-time",
        `· ${formatRelative(latestSwitch.switchedAt)}`,
      ),
    );
    switchSummary.append(
      element("span", "compact-label", t("recentSwitches")),
      switchValue,
    );
    elements.routeContent.replaceChildren(rows, switchSummary);
  }

  function formatCompactRate(value) {
    let bytes = Math.max(0, safeNumber(value));
    const units = ["B/s", "K/s", "M/s", "G/s"];
    let unit = 0;
    while (bytes >= 1000 && unit < units.length - 1) {
      bytes /= 1000;
      unit += 1;
    }
    const digits = bytes >= 100 || unit === 0 ? 0 : bytes >= 10 ? 1 : 2;
    return `${bytes.toFixed(digits)}${units[unit]}`;
  }

  function longestActiveDurationText(connections) {
    const activeCount = Math.max(0, safeNumber(connections?.activeCount));
    if (activeCount === 0) return t("noConnections");
    const longestDuration = Number(connections?.longestActiveDuration);
    if (
      connections?.longestActiveDuration == null ||
      !Number.isFinite(longestDuration) ||
      longestDuration < 0
    ) {
      return t("unavailable");
    }
    return formatDuration(longestDuration);
  }

  function connectionMapData(history) {
    const recentBuckets = (Array.isArray(history) ? history : [])
      .filter((bucket) => Number.isFinite(new Date(bucket.timestamp).getTime()))
      .sort(
        (left, right) =>
          new Date(left.timestamp).getTime() - new Date(right.timestamp).getTime(),
      )
      .slice(-60);
    const exactBucketCount = recentBuckets.filter((bucket) =>
      Array.isArray(bucket.connectionAges),
    ).length;
    const buckets = [
      ...Array.from(
        { length: Math.max(0, 60 - recentBuckets.length) },
        () => null,
      ),
      ...recentBuckets,
    ];
    let signature = 2_166_136_261;
    const mix = (value) => {
      signature ^= Math.max(0, Math.round(safeNumber(value))) >>> 0;
      signature = Math.imul(signature, 16_777_619) >>> 0;
    };
    const ageValues = buckets.map((bucket) => {
      if (!bucket) {
        mix(0);
        return [];
      }
      const exact = Array.isArray(bucket.connectionAges);
      const ages = exact
        ? bucket.connectionAges
            .map(Number)
            .filter((age) => Number.isFinite(age) && age >= 0)
            .slice(0, 100)
            .sort((left, right) => right - left)
        : Array.from(
            {
              length: Math.max(
                0,
                Math.min(100, Math.floor(safeNumber(bucket.connectionCount))),
              ),
            },
            () => Math.max(0, safeNumber(bucket.oldestConnectionAge)),
          );
      mix(new Date(bucket.timestamp).getTime());
      mix(exact ? 1 : 2);
      mix(ages.length);
      for (const age of ages) mix(age * 10);
      return ages;
    });
    return {
      ageValues,
      bucketCount: recentBuckets.length,
      maximumConnections: Math.max(
        1,
        ...ageValues.map((ages) => ages.length),
      ),
      precision:
        recentBuckets.length > 0 && exactBucketCount === recentBuckets.length
          ? "exact"
          : "fallback",
      signature: `${recentBuckets.length}:${signature}`,
    };
  }

  function ensureConnectionsView() {
    if (state.connectionsView?.root?.isConnected) return state.connectionsView;
    const root = element("div", "connections-live-view");
    const metrics = element("div", "connection-metrics");
    const metric = () => {
      const item = element("div", "connection-metric");
      const label = element("span", "metric-label");
      const value = element("span", "metric-value");
      item.append(label, value);
      return { item, label, value };
    };
    const download = metric();
    const upload = metric();
    const count = metric();
    metrics.append(download.item, upload.item, count.item);

    const map = element("div", "active-link-map");
    const mapLabel = element("span", "metric-label");
    const canvas = element("canvas", "link-dot-matrix");
    canvas.setAttribute("role", "img");
    map.append(mapLabel, canvas);

    const activeSummary = element("div", "active-summary");
    const activeLabel = element("span", "compact-label");
    const activeValue = element("span", "active-summary-value");
    const activeText = element("span", "active-summary-duration");
    activeValue.append(activeText);
    activeSummary.append(activeLabel, activeValue);
    root.append(metrics, map, activeSummary);
    elements.connectionsContent.replaceChildren(root);
    state.connectionMapSignature = "";
    state.connectionsView = {
      root,
      download,
      upload,
      count,
      mapLabel,
      canvas,
      activeLabel,
      activeText,
    };
    return state.connectionsView;
  }

  function drawActiveLinkMap(canvas, mapData) {
    if (!canvas?.isConnected || document.hidden) return;
    const width = Math.max(1, Math.floor(canvas.clientWidth));
    const height = Math.max(24, Math.floor(canvas.clientHeight));
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    const pixelWidth = Math.max(1, Math.floor(width * ratio));
    const pixelHeight = Math.max(1, Math.floor(height * ratio));
    if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
      canvas.width = pixelWidth;
      canvas.height = pixelHeight;
    }
    const context = canvas.getContext("2d", { alpha: true });
    if (!context) return;
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, height);

    const columnGap = 1;
    const columnWidth = Math.max(
      0.5,
      (Math.max(60, width) - 59 * columnGap) / 60,
    );
    const dotWidth = Math.max(0.5, Math.min(6, columnWidth));
    const rowStep = height / Math.max(1, mapData.maximumConnections);
    const rowGap = Math.min(0.6, rowStep * 0.16);
    const dotHeight = Math.max(0.5, rowStep - rowGap);
    const tones = [
      cssToken("--link-fresh", "#70c982"),
      cssToken("--link-settled", "#85c178"),
      cssToken("--link-warm", "#9cb76d"),
      cssToken("--link-aging", "#b5ab64"),
      cssToken("--orange", "#c9955d"),
    ];
    mapData.ageValues.forEach((ages, columnIndex) => {
      const x = columnIndex * (columnWidth + columnGap)
        + Math.max(0, (columnWidth - dotWidth) / 2);
      for (const [rowIndex, age] of ages.entries()) {
        const ageRatio = clamp(age / 3_600, 0, 1);
        const toneIndex = ageRatio >= 0.8
          ? 4
          : ageRatio >= 0.6
            ? 3
            : ageRatio >= 0.35
              ? 2
              : ageRatio >= 0.15
                ? 1
                : 0;
        context.fillStyle = tones[toneIndex];
        context.globalAlpha = mapData.precision === "exact" ? 0.92 : 0.68;
        context.fillRect(
          x,
          height - (rowIndex + 1) * rowStep + rowGap / 2,
          dotWidth,
          dotHeight,
        );
      }
    });
    context.globalAlpha = 1;
  }

  function scheduleActiveLinkMap(canvas, mapData) {
    state.pendingConnectionMap = { canvas, mapData };
    if (state.connectionMapFrame != null) return;
    state.connectionMapFrame = window.requestAnimationFrame(() => {
      state.connectionMapFrame = null;
      const pending = state.pendingConnectionMap;
      state.pendingConnectionMap = null;
      if (pending) drawActiveLinkMap(pending.canvas, pending.mapData);
    });
  }

  function renderConnections(connections, force) {
    const view = ensureConnectionsView();
    elements.connectionsTime.textContent = connections.observedAt
      ? formatRelative(connections.observedAt)
      : "";
    view.download.label.textContent = t("downloadCompact");
    view.upload.label.textContent = t("uploadCompact");
    view.count.label.textContent = t("connectionsCompact");
    view.download.value.textContent = formatCompactRate(
      connections.downloadBytesPerSecond,
    );
    view.upload.value.textContent = formatCompactRate(
      connections.uploadBytesPerSecond,
    );
    view.count.value.textContent = String(safeNumber(connections.activeCount));
    view.download.value.classList.toggle(
      "good",
      safeNumber(connections.downloadBytesPerSecond) > 0,
    );
    view.count.value.classList.toggle(
      "good",
      safeNumber(connections.activeCount) > 0,
    );

    const mapData = connectionMapData(connections.history);
    view.mapLabel.textContent = t("activeLinkMap");
    view.canvas.dataset.precision = mapData.precision;
    view.canvas.setAttribute(
      "aria-label",
      `${t("activeLinkMap")}: ${mapData.bucketCount} × 60m`,
    );
    if (force || state.connectionMapSignature !== mapData.signature) {
      state.connectionMapSignature = mapData.signature;
      scheduleActiveLinkMap(view.canvas, mapData);
    }

    const activeCount = Math.max(0, safeNumber(connections.activeCount));
    view.activeLabel.textContent = t("longestActive");
    view.activeText.className = activeCount > 0
      ? "active-summary-duration"
      : "active-summary-empty";
    view.activeText.textContent = longestActiveDurationText(connections);
  }

  function prepareCanvas(id) {
    if (document.hidden) return null;
    const canvas = document.getElementById(id);
    if (!canvas) return null;
    const width = Math.max(1, Math.floor(canvas.clientWidth));
    const height = Math.max(1, Math.floor(canvas.clientHeight));
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.floor(width * ratio);
    canvas.height = Math.floor(height * ratio);
    const context = canvas.getContext("2d", { alpha: true });
    if (!context) return null;
    context.scale(ratio, ratio);
    return { canvas, context, width, height };
  }

  function drawConnectionChart(id, points) {
    if (document.hidden || !points || points.length < 2) return;
    const prepared = prepareCanvas(id);
    if (!prepared) return;
    const { context, width, height } = prepared;
    const inset = 2;
    const values = points.map((point) =>
      Math.max(0, safeNumber(point.connectionCount)),
    );
    const maximum = Math.max(1, ...values);

    context.lineWidth = 1;
    context.strokeStyle = cssToken("--chart-grid", "#171a17");
    for (let index = 1; index < 4; index += 1) {
      const y = Math.round((height * index) / 4) + 0.5;
      context.beginPath();
      context.moveTo(0, y);
      context.lineTo(width, y);
      context.stroke();
    }

    context.strokeStyle = cssToken("--chart-series", "#79aabd");
    context.lineWidth = 1.5;
    context.lineJoin = "round";
    context.lineCap = "round";
    context.beginPath();
    values.forEach((value, index) => {
      const x =
        inset + (index / Math.max(1, values.length - 1)) * (width - inset * 2);
      const y =
        inset +
        (1 - value / maximum) * (height - inset * 2);
      if (index === 0) context.moveTo(x, y);
      else context.lineTo(x, y);
    });
    context.stroke();
  }

  function quotaChartTint(model, warningThresholdPercent) {
    const neutral = cssRGBToken("--chart-neutral-rgb", "164, 172, 164");
    const red = cssRGBToken("--red-rgb", "220, 121, 106");
    const orange = cssRGBToken("--orange-rgb", "208, 160, 94");
    const green = cssRGBToken("--green-rgb", "112, 201, 130");
    if (
      model.usesReverseProgressTint === true ||
      model.progressBarPercentOverride != null
    ) {
      return neutral;
    }
    const remaining = clamp(model.remainingPercent, 0, 100);
    const used = 100 - remaining;
    const warningThreshold = clamp(warningThresholdPercent, 0, 100);
    if (used >= 100) return red;
    if (used >= 80) return orange;
    if (used > 0 && remaining <= warningThreshold) return orange;
    if (used > 0) return green;
    return neutral;
  }

  function rgba(color, alpha) {
    return `rgba(${color[0]}, ${color[1]}, ${color[2]}, ${alpha})`;
  }

  function sameLocalDay(left, right) {
    return (
      left.getFullYear() === right.getFullYear() &&
      left.getMonth() === right.getMonth() &&
      left.getDate() === right.getDate()
    );
  }

  function quotaAxisTimeText(value, start) {
    const date = new Date(value);
    const pad = (number) => String(number).padStart(2, "0");
    const time = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
    return sameLocalDay(date, start)
      ? time
      : `${pad(date.getMonth() + 1)}/${pad(date.getDate())} ${time}`;
  }

  function quotaTimeTicks(start, end) {
    const duration = end - start;
    if (!(duration > 0)) return [];
    const hour = 3_600_000;
    const day = 86_400_000;
    const unitDuration = duration <= 24 * hour
      ? hour
      : duration <= 8 * day
        ? day
        : null;
    if (!unitDuration || duration / unitDuration < 2) return [];
    const interiorCount = Math.max(
      0,
      Math.ceil(duration / unitDuration - 0.000_000_1) - 1,
    );
    return Array.from({ length: interiorCount }, (_, index) =>
      ((index + 1) * unitDuration) / duration,
    );
  }

  function drawQuotaAreaChart(id, model, warningThresholdPercent) {
    const prepared = prepareCanvas(id);
    if (!prepared) return;
    const { context, width, height } = prepared;
    const isPercentMode = model.isCurrentIntervalPercentMode !== false;
    const yAxisMax = isPercentMode
      ? 100
      : safeNumber(model.total) > 0
        ? safeNumber(model.total)
        : 100;
    const samples = Array.isArray(model.samples)
      ? model.samples
          .filter((sample) => {
            const timestamp = new Date(sample.timestamp).getTime();
            const value = isPercentMode
              ? sample.remainingPercent
              : sample.remaining;
            return (
              Number.isFinite(timestamp) &&
              Number.isFinite(Number(value))
            );
          })
          .sort(
            (leftSample, rightSample) =>
              new Date(leftSample.timestamp).getTime() -
              new Date(rightSample.timestamp).getTime(),
          )
      : [];

    // Mirrors QuotaChartLayout in MenuView.swift. Axis text is raised from the
    // native 9pt to 12px for the phone readability contract.
    const left = 30;
    const right = 8;
    const top = 8;
    const bottom = 18;
    const plotRight = width - right;
    const plotBottom = height - bottom;
    const plotWidth = Math.max(1, plotRight - left);
    const plotHeight = Math.max(1, plotBottom - top);
    const start = new Date(model.startsAt);
    const end = new Date(model.resetsAt);
    const startTimestamp = start.getTime();
    const endTimestamp = end.getTime();
    const hasWindow =
      Number.isFinite(startTimestamp) &&
      Number.isFinite(endTimestamp) &&
      endTimestamp > startTimestamp;
    const x = (timestamp) => {
      if (!hasWindow) return left;
      const elapsed = clamp(timestamp - startTimestamp, 0, endTimestamp - startTimestamp);
      return left + (elapsed / Math.max(endTimestamp - startTimestamp, 1)) * plotWidth;
    };
    const y = (remaining) =>
      plotBottom - plotHeight * (clamp(remaining, 0, yAxisMax) / yAxisMax);
    const tint = quotaChartTint(model, warningThresholdPercent);

    context.save();
    const neutralRGB = cssToken(
      "--canvas-neutral-rgb",
      "237, 241, 237",
    );
    context.fillStyle = `rgba(${neutralRGB}, 0.035)`;
    context.beginPath();
    if (typeof context.roundRect === "function") {
      context.roundRect(left, top, plotWidth, plotHeight, 7);
    } else {
      context.rect(left, top, plotWidth, plotHeight);
    }
    context.fill();
    context.restore();

    context.save();
    context.strokeStyle = `rgba(${neutralRGB}, 0.14)`;
    context.lineWidth = 1;
    context.beginPath();
    context.moveTo(left, top);
    context.lineTo(left, plotBottom);
    context.lineTo(plotRight, plotBottom);
    context.stroke();
    context.restore();

    const threshold = clamp(warningThresholdPercent, 0, 100);
    if (threshold > 0 && threshold < 100) {
      context.save();
      context.setLineDash([3, 3]);
      const orangeRGB = cssToken("--orange-rgb", "208, 160, 94");
      context.strokeStyle = `rgba(${orangeRGB}, 0.45)`;
      context.lineWidth = 1;
      context.beginPath();
      const thresholdY = y(yAxisMax * threshold / 100);
      context.moveTo(left, thresholdY);
      context.lineTo(plotRight, thresholdY);
      context.stroke();
      context.restore();
    }

    if (hasWindow) {
      for (const ratio of quotaTimeTicks(startTimestamp, endTimestamp)) {
        const tickX = left + plotWidth * ratio;
        context.save();
        context.setLineDash([2, 3]);
        context.strokeStyle = `rgba(${neutralRGB}, 0.10)`;
        context.lineWidth = 1;
        context.beginPath();
        context.moveTo(tickX, top);
        context.lineTo(tickX, plotBottom);
        context.stroke();
        context.restore();
      }
    }

    const hasPace = model.hasCurrentIntervalPace === true || (
      model.hasCurrentIntervalPace == null &&
      model.paceDeltaPercent != null
    );
    if (hasPace) {
      const reserveTone = model.paceGuideTone != null
        ? model.paceGuideTone === "reserve"
        : safeNumber(model.paceDeltaPercent) >= 0;
      context.save();
      context.setLineDash([3, 3]);
      context.strokeStyle = reserveTone
        ? `rgba(${cssToken("--green-rgb", "112, 201, 130")}, 0.55)`
        : `rgba(${cssToken("--red-rgb", "220, 121, 106")}, 0.55)`;
      context.lineWidth = 1;
      context.beginPath();
      context.moveTo(left, top);
      context.lineTo(plotRight, plotBottom);
      context.stroke();
      context.restore();
    }

    const forecasts = Array.isArray(model.consumptionForecasts)
      ? model.consumptionForecasts
      : [];
    const forecastOpacities = [0.62, 0.44, 0.31, 0.22, 0.15];
    for (const [index, forecast] of forecasts.entries()) {
      const forecastStart = new Date(forecast.startsAt).getTime();
      const forecastExhaustion = new Date(forecast.exhaustsAt).getTime();
      const startingRemaining = safeNumber(forecast.startingRemaining, -1);
      const rate = safeNumber(forecast.consumptionPerSecond, 0);
      if (
        !hasWindow ||
        !Number.isFinite(forecastStart) ||
        !Number.isFinite(forecastExhaustion) ||
        startingRemaining <= 0 ||
        rate <= 0
      ) continue;

      const forecastEnd = Math.min(forecastExhaustion, endTimestamp);
      if (forecastEnd <= forecastStart) continue;
      const remainingAtEnd = Math.max(
        0,
        startingRemaining - rate * ((forecastEnd - forecastStart) / 1000),
      );
      const opacity = forecastOpacities[
        Math.min(index, forecastOpacities.length - 1)
      ];

      context.save();
      context.setLineDash([5, 4]);
      context.strokeStyle = rgba(tint, opacity);
      context.lineWidth = 1;
      context.lineCap = "round";
      context.beginPath();
      context.moveTo(x(forecastStart), y(startingRemaining));
      context.lineTo(x(forecastEnd), y(remainingAtEnd));
      context.stroke();
      context.restore();
    }

    const points = samples.map((sample) => ({
      x: x(new Date(sample.timestamp).getTime()),
      y: y(isPercentMode ? sample.remainingPercent : sample.remaining),
    }));
    if (points.length === 1) {
      const point = points[0];
      const gradient = context.createLinearGradient(0, top, 0, plotBottom);
      gradient.addColorStop(0, rgba(tint, 0.22));
      gradient.addColorStop(1, rgba(tint, 0.03));
      context.beginPath();
      context.moveTo(left, plotBottom);
      context.lineTo(left, point.y);
      context.lineTo(point.x, point.y);
      context.lineTo(point.x, plotBottom);
      context.closePath();
      context.fillStyle = gradient;
      context.fill();

      context.beginPath();
      context.moveTo(point.x, plotBottom);
      context.lineTo(point.x, point.y);
      context.strokeStyle = rgba(tint, 0.45);
      context.lineWidth = 2;
      context.stroke();
      context.beginPath();
      context.arc(point.x, point.y, 3, 0, Math.PI * 2);
      context.fillStyle = rgba(tint, 1);
      context.fill();
    } else if (points.length > 1) {
      const first = points[0];
      const last = points[points.length - 1];
      const gradient = context.createLinearGradient(0, top, 0, plotBottom);
      gradient.addColorStop(0, rgba(tint, 0.22));
      gradient.addColorStop(1, rgba(tint, 0.03));
      context.beginPath();
      context.moveTo(first.x, plotBottom);
      context.lineTo(first.x, first.y);
      for (const point of points) context.lineTo(point.x, point.y);
      context.lineTo(last.x, plotBottom);
      context.lineTo(first.x, plotBottom);
      context.closePath();
      context.fillStyle = gradient;
      context.fill();

      context.beginPath();
      points.forEach((point, index) => {
        if (index === 0) context.moveTo(point.x, point.y);
        else context.lineTo(point.x, point.y);
      });
      context.strokeStyle = rgba(tint, 1);
      context.lineWidth = 2;
      context.lineJoin = "round";
      context.lineCap = "round";
      context.stroke();
      context.fillStyle = rgba(tint, 1);
      for (const point of points) {
        context.beginPath();
        context.arc(point.x, point.y, 2, 0, Math.PI * 2);
        context.fill();
      }
    }

    context.font = '12px "Avenir Next", "Helvetica Neue", sans-serif';
    context.fillStyle = cssToken("--chart-axis", "#a4aca4");
    context.textBaseline = "middle";
    context.textAlign = "left";
    context.fillText(
      isPercentMode ? "100%" : String(safeNumber(model.total)),
      3,
      top,
    );
    context.fillText("0", 3, plotBottom);
    if (hasWindow) {
      context.textBaseline = "top";
      context.textAlign = "left";
      context.fillText(quotaAxisTimeText(start, start), left, plotBottom + 4);
      context.textAlign = "right";
      context.fillText(quotaAxisTimeText(end, start), plotRight, plotBottom + 4);
    }
  }

  function renderEnvelope(envelope) {
    if (!envelope || typeof envelope !== "object" || !envelope.snapshot) return;
    const snapshot = envelope.snapshot;
    const isFirstSnapshot = state.snapshot == null;
    const previousOLEDSetting = state.oledProtectionEnabled;
    const nextActivityEffect = ACTIVITY_EFFECTS.has(
      envelope.activityBackgroundEffect,
    )
      ? envelope.activityBackgroundEffect
      : "grainyDigitalRain";
    const activityEffectChanged =
      nextActivityEffect !== state.activityBackgroundEffect;
    const suppliedTaskTelemetryFields = Array.isArray(
      envelope.taskTelemetryFields,
    )
      ? envelope.taskTelemetryFields
      : TASK_TELEMETRY_FIELD_ORDER;
    const nextTaskTelemetryFields = new Set(
      suppliedTaskTelemetryFields.filter((field) =>
        TASK_TELEMETRY_FIELDS.has(field),
      ),
    );
    const taskTelemetryFieldsChanged = fingerprint(
      TASK_TELEMETRY_FIELD_ORDER.filter((field) =>
        nextTaskTelemetryFields.has(field),
      ),
    ) !== fingerprint(
      TASK_TELEMETRY_FIELD_ORDER.filter((field) =>
        state.taskTelemetryFields.has(field),
      ),
    );
    const nextExperimentalWakeSetting =
      envelope.experimentalWakeMediaEnabled === true;
    const nextIdleBlackoutSetting =
      envelope.idleBlackoutMarqueeEnabled === true;
    const nextColorScheme = COLOR_SCHEMES.has(envelope.colorScheme)
      ? envelope.colorScheme
      : "auto";
    const colorSchemeChanged = applyColorScheme(nextColorScheme);
    const nextLanguage = String(snapshot.language || "")
      .toLowerCase()
      .startsWith("zh")
      ? "zh"
      : "en";
    const languageChanged = nextLanguage !== state.language;
    state.language = nextLanguage;
    state.oledProtectionEnabled = envelope.oledProtectionEnabled !== false;
    state.activityBackgroundEffect = nextActivityEffect;
    state.taskTelemetryFields = nextTaskTelemetryFields;
    document.body.dataset.activityEffect = nextActivityEffect;
    state.snapshot = snapshot;
    state.activeProviderMix = activityProviderMix(snapshot.activitySummary);
    document.body.dataset.activeProviders = state.activeProviderMix;
    state.explicitHasActiveTasks =
      typeof snapshot.protection?.hasActiveTasks === "boolean"
        ? snapshot.protection.hasActiveTasks
        : null;
    state.connected = true;
    delete document.body.dataset.connectionRecovery;
    markActiveBaseSuccessful();
    if (languageChanged) {
      state.fingerprints = Object.create(null);
      applyStaticCopy();
    }

    elements.gate.hidden = true;
    delete document.body.dataset.pairingRequired;
    elements.dashboard.hidden = false;
    elements.machineName.textContent = snapshot.macName || t("mac");
    setConnectionStatus("live", t("live"));
    updateMenuBarSignal(snapshot);
    const forceVisualRefresh =
      languageChanged || colorSchemeChanged || taskTelemetryFieldsChanged;
    renderQuota(snapshot.quota, forceVisualRefresh);
    renderProtection(
      snapshot.protection,
      forceVisualRefresh,
      snapshot.activitySummary,
    );
    if (activityEffectChanged || colorSchemeChanged) configureTaskRain(true);
    if (activityEffectChanged) configureTaskTelemetryMotion();
    renderRoute(snapshot.route, forceVisualRefresh);
    renderConnections(snapshot.connections, forceVisualRefresh);
    configureExperimentalWakeMedia(
      nextExperimentalWakeSetting,
      snapshot.protection,
    );
    configureIdleBlackout(
      nextIdleBlackoutSetting,
      snapshot.activitySummary,
    );
    elements.footerMeta.textContent = [
      `v${snapshot.appVersion}`,
      formatRelative(snapshot.generatedAt),
    ]
      .filter(Boolean)
      .join(" · ");
    if (
      isFirstSnapshot ||
      previousOLEDSetting !== state.oledProtectionEnabled
    ) {
      resetOLEDIdleTimer();
      configurePixelShift();
      configureContentRotation();
    }
  }

  async function consumeEventStream(response, signal, isCurrent = () => true) {
    if (!response.body) throw new Error(t("websocketError"));
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let dataLines = [];

    const flushEvent = () => {
      if (!dataLines.length) return;
      const payload = dataLines.join("\n");
      dataLines = [];
      if (!isCurrent()) return;
      try {
        renderEnvelope(JSON.parse(payload));
      } catch {
        // Ignore an incomplete or unknown event and keep the stream alive.
      }
    };

    while (!signal.aborted) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let lineEnd;
      while ((lineEnd = buffer.indexOf("\n")) >= 0) {
        let line = buffer.slice(0, lineEnd);
        buffer = buffer.slice(lineEnd + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (line === "") {
          flushEvent();
        } else if (line.startsWith("data:")) {
          dataLines.push(line.slice(5).replace(/^ /, ""));
        }
      }
    }
    flushEvent();
    if (!signal.aborted) throw new Error("stream_closed");
  }

  async function connect() {
    if (
      !state.token ||
      document.hidden ||
      state.controller ||
      !navigator.onLine
    ) {
      return;
    }
    window.clearTimeout(state.retryTimer);
    state.retryTimer = null;
    const controller = new AbortController();
    state.controller = controller;
    const requestEpoch = state.connectionEpoch;
    const requestBase = state.activeBaseURL || window.location.origin;
    const requestToken = state.token;
    const isCurrent = () => (
      requestEpoch === state.connectionEpoch &&
      requestBase === (state.activeBaseURL || window.location.origin) &&
      requestToken === state.token &&
      state.controller === controller &&
      !controller.signal.aborted
    );
    if (!state.snapshot) setConnectionStatus("waiting", t("connecting"));
    else setConnectionStatus("waiting", t("reconnecting"));

    try {
      const response = await fetch(baseAwareURL(EVENTS_PATH, requestBase), {
        method: "GET",
        mode: "cors",
        headers: {
          Accept: "text/event-stream",
          Authorization: `Bearer ${requestToken}`,
          "Cache-Control": "no-store",
        },
        cache: "no-store",
        credentials: "omit",
        redirect: "error",
        signal: controller.signal,
      });
      if (response.status === 401) {
        if (isCurrent()) {
          clearToken();
          state.controller = null;
          void prepareAndConnect(true);
        }
        return;
      }
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const expectedInstance = state.pairedServerInstances.get(requestBase);
      const observedInstance = response.headers.get(
        "X-AI-Quota-Server-Instance",
      );
      if (
        expectedInstance &&
        observedInstance &&
        expectedInstance !== observedInstance
      ) {
        throw new Error("server_instance_changed");
      }
      if (!isCurrent()) return;
      state.retryCount = 0;
      await consumeEventStream(response, controller.signal, isCurrent);
    } catch (error) {
      if (
        error?.name !== "AbortError" &&
        state.token &&
        isCurrent()
      ) {
        handleDisconnect();
      }
    } finally {
      const ownsConnectionSlot = isCurrent();
      if (ownsConnectionSlot) {
        state.controller = null;
        if (state.token && !document.hidden) scheduleReconnect();
      }
    }
  }

  function disconnect() {
    state.connectionEpoch += 1;
    window.clearTimeout(state.retryTimer);
    state.retryTimer = null;
    if (state.controller) state.controller.abort();
    state.controller = null;
    state.connected = false;
    setIdleBlackout(false);
    stopTaskRain({ clear: true });
    stopTaskTelemetryMotion();
    deactivateWorkingWake();
  }

  function handleDisconnect() {
    state.connected = false;
    setIdleBlackout(false);
    stopTaskRain({ clear: true });
    deactivateWorkingWake();
    document.body.dataset.connectionRecovery = "true";
    renderAddressPanels();
    setConnectionStatus(
      "error",
      navigator.onLine ? t("disconnected") : t("offline"),
    );
  }

  function handleOffline() {
    disconnect();
    document.body.dataset.connectionRecovery = "true";
    renderAddressPanels();
    setConnectionStatus("error", t("offline"));
  }

  function scheduleReconnect() {
    if (
      state.retryTimer ||
      !state.token ||
      document.hidden ||
      !navigator.onLine
    ) {
      return;
    }
    handleDisconnect();
    const delay = Math.min(MAX_RETRY_MS, 1_000 * 2 ** state.retryCount);
    state.retryCount = Math.min(state.retryCount + 1, 5);
    state.retryTimer = window.setTimeout(connect, delay);
  }

  function clearDimming() {
    document.body.classList.remove("is-dimmed");
    window.clearTimeout(state.dimTimer);
    state.dimTimer = null;
  }

  function resetOLEDIdleTimer() {
    clearDimming();
    if (!state.oledProtectionEnabled || document.hidden) return;
    state.dimTimer = window.setTimeout(() => {
      if (!document.hidden && state.oledProtectionEnabled) {
        document.body.classList.add("is-dimmed");
      }
    }, DIM_AFTER_MS);
  }

  function supportsPixelShift() {
    return (
      state.oledProtectionEnabled &&
      !document.hidden &&
      !window.matchMedia("(prefers-reduced-motion: reduce)").matches
    );
  }

  function applyPixelShift() {
    if (!supportsPixelShift()) {
      document.documentElement.style.setProperty("--page-shift-x", "0px");
      document.documentElement.style.setProperty("--page-shift-y", "0px");
      return;
    }
    const offsets = [-2, -1, 0, 1, 2];
    const currentX = Number.parseInt(
      document.documentElement.style.getPropertyValue("--page-shift-x"),
      10,
    );
    const currentY = Number.parseInt(
      document.documentElement.style.getPropertyValue("--page-shift-y"),
      10,
    );
    let nextX = offsets[Math.floor(Math.random() * offsets.length)];
    let nextY = offsets[Math.floor(Math.random() * offsets.length)];
    if (nextX === currentX && nextY === currentY) {
      nextX = nextX === 2 ? -2 : nextX + 1;
    }
    document.documentElement.style.setProperty(
      "--page-shift-x",
      `${nextX}px`,
    );
    document.documentElement.style.setProperty(
      "--page-shift-y",
      `${nextY}px`,
    );
  }

  function configurePixelShift() {
    window.clearInterval(state.shiftTimer);
    state.shiftTimer = null;
    if (!supportsPixelShift()) {
      applyPixelShift();
      return;
    }
    state.shiftTimer = window.setInterval(applyPixelShift, PIXEL_SHIFT_MS);
  }

  function supportsContentRotation() {
    return (
      state.oledProtectionEnabled &&
      !document.hidden &&
      !window.matchMedia("(prefers-reduced-motion: reduce)").matches
    );
  }

  function rotateCoreContent() {
    if (!supportsContentRotation()) return;
    const matrix = elements.quotaContent.querySelector(".quota-matrix");
    const quotes = matrix?.querySelectorAll(".quota-quote-strip") || [];
    if (!matrix || quotes.length < 2) return;
    matrix.classList.add("is-rotating");
    window.setTimeout(() => {
      if (!matrix.isConnected || !supportsContentRotation()) return;
      matrix.append(quotes[0]);
      matrix.classList.remove("is-rotating");
    }, 300);
  }

  function configureContentRotation() {
    window.clearInterval(state.contentRotateTimer);
    state.contentRotateTimer = null;
    if (!supportsContentRotation()) return;
    state.contentRotateTimer = window.setInterval(
      rotateCoreContent,
      CONTENT_ROTATE_MS,
    );
  }

  async function prepareAndConnect(invalidToken = false) {
    if (!state.token) {
      await claimTokenWithoutPairingCode();
    }
    if (!state.token) {
      await claimStandaloneToken();
    }
    if (!state.token) {
      showPairingGate(invalidToken || state.installCredentialRejected);
      return;
    }
    elements.gate.hidden = true;
    elements.pairingRetryButton.hidden = true;
    delete document.body.dataset.pairingRequired;
    await refreshPWABootstrap();
    if (state.token) connect();
    else await prepareAndConnect(true);
  }

  async function handleVisibilityChange() {
    if (document.hidden) {
      disconnect();
      clearDimming();
      configurePixelShift();
      configureContentRotation();
      await suspendExperimentalWakeForBackground();
      return;
    }
    resetOLEDIdleTimer();
    configurePixelShift();
    configureContentRotation();
    await prepareAndConnect();
    resumeExperimentalWakeOnce();
  }

  function redrawCharts() {
    if (!state.snapshot || document.hidden) return;
    renderQuota(state.snapshot.quota, true);
    renderConnections(state.snapshot.connections, true);
    configureTaskRain(true);
    renderTaskTelemetryMarquee(state.activitySummary, true);
  }

  function preventViewportGesture(event) {
    const isSafariGesture = event.type.startsWith("gesture");
    const isMultiTouch = event.touches?.length > 1;
    if (isSafariGesture || isMultiTouch) event.preventDefault();
  }

  let resizeTimer = null;
  window.addEventListener("resize", () => {
    window.clearTimeout(resizeTimer);
    resizeTimer = window.setTimeout(redrawCharts, 120);
  });
  document.addEventListener("visibilitychange", handleVisibilityChange);
  for (const eventName of ["gesturestart", "gesturechange", "gestureend"]) {
    document.addEventListener(eventName, preventViewportGesture, {
      passive: false,
    });
  }
  document.addEventListener("touchmove", preventViewportGesture, {
    passive: false,
  });
  window.addEventListener("online", prepareAndConnect);
  window.addEventListener("offline", handleOffline);
  window.addEventListener("pagehide", () => {
    stopTaskRain({ clear: true });
    stopTaskTelemetryMotion();
    void suspendExperimentalWakeForBackground();
  });
  window.addEventListener("pageshow", resumeExperimentalWakeOnce);
  document.querySelectorAll("[data-address-form]").forEach((form) => {
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const addressInput = form.querySelector("[data-address-input]");
      const codeInput = form.querySelector("[data-pairing-code-input]");
      const rawValue = addressInput.value;
      const submittedCode = codeInput.value;
      addressInput.value = "";
      codeInput.value = "";
      if (submittedCode.trim()) {
        void claimWithTemporaryCode(rawValue, submittedCode);
      } else {
        addSavedAddress(rawValue);
      }
    });
  });
  document.querySelectorAll("[data-address-check-all]").forEach((button) => {
    button.addEventListener("click", () => {
      void checkAllSavedAddresses();
    });
  });
  document.querySelectorAll(".lan-address-panel").forEach((panel) => {
    panel.addEventListener("click", (event) => {
      if (!(event.target instanceof Element)) return;
      const button = event.target.closest("[data-address-action]");
      if (!button || !panel.contains(button)) return;
      const origin = button.dataset.origin || "";
      switch (button.dataset.addressAction) {
      case "check":
        if (!state.addressCheckInFlight) void checkSavedAddress(origin);
        break;
      case "connect":
        connectSavedAddress(origin);
        break;
      case "pair":
        beginPairingAddress(origin, panel);
        break;
      case "delete":
        cancelManualClaim();
        if (state.activeBaseURL === origin) {
          stopConnectionForBaseChange();
          setActiveBaseURL("");
          clearToken();
          showPairingGate(false);
        }
        state.savedAddresses = state.savedAddresses.filter(
          (entry) => entry.origin !== origin,
        );
        state.addressResults.delete(origin);
        persistSavedAddresses();
        renderAddressPanels();
        break;
      default:
        break;
      }
    });
  });
  elements.pairingRetryButton.addEventListener("click", async () => {
    if (
      (!state.installCredential && !state.installCookieClaimRetryAvailable) ||
      state.installClaimInFlight
    ) {
      return;
    }
    elements.pairingRetryButton.disabled = true;
    setConnectionStatus("waiting", t("connecting"));
    try {
      await prepareAndConnect();
    } finally {
      elements.pairingRetryButton.disabled = false;
    }
  });
  elements.wakeAmbientVideo.addEventListener("playing", () => {
    if (
      isWorkingWakeEligible() &&
      !state.suppressWakeMediaEvents
    ) {
      state.wakeFallbackInterrupted = false;
      setWakeMediaPresentation("playing");
    }
  });
  for (const eventName of ["pause", "stalled", "error"]) {
    elements.wakeAmbientVideo.addEventListener(eventName, () => {
      if (
        !isWorkingWakeEligible() ||
        state.suppressWakeMediaEvents ||
        state.wakeLockSentinel
      ) {
        return;
      }
      if (eventName !== "pause") stopWakeMedia();
      showWakeFallback(true);
    });
  }
  for (const eventName of ["pointerdown", "touchstart", "keydown", "scroll"]) {
    window.addEventListener(eventName, resetOLEDIdleTimer, { passive: true });
  }
  const motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)");
  motionPreference.addEventListener?.("change", () => {
    configurePixelShift();
    configureContentRotation();
    configureTaskRain(true);
    configureTaskTelemetryMotion();
  });
  const handleSystemColorSchemeChange = () => {
    if (state.colorScheme !== "auto") return;
    if (applyColorScheme(state.colorScheme)) refreshThemeDependentVisuals();
  };
  if (systemColorScheme.addEventListener) {
    systemColorScheme.addEventListener("change", handleSystemColorSchemeChange);
  } else {
    systemColorScheme.addListener?.(handleSystemColorSchemeChange);
  }

  async function start() {
    state.activeBaseURL = loadActiveBaseURL();
    state.token = extractToken();
    if (!state.activeBaseURL) {
      const currentBase = normalizeLANAddress(window.location.origin)?.origin;
      if (currentBase) setActiveBaseURL(currentBase);
    }
    state.savedAddresses = loadSavedAddresses();
    state.wakeIntent = loadWakeIntent();
    applyColorScheme(state.colorScheme);
    document.body.dataset.activityEffect = state.activityBackgroundEffect;
    elements.wakeAmbientVideo.muted = true;
    elements.wakeAmbientVideo.defaultMuted = true;
    elements.wakeAmbientVideo.playsInline = true;
    elements.wakeAmbientVideo.disablePictureInPicture = true;
    elements.wakeAmbientVideo.disableRemotePlayback = true;
    applyStaticCopy();
    resetOLEDIdleTimer();
    configurePixelShift();
    configureContentRotation();
    await prepareAndConnect();
  }

  start();
})();
