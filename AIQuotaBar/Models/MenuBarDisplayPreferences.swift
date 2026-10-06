import Foundation

/// Which provider or provider set should appear in the menu-bar glance target.
enum MenuBarContentSelection: String, CaseIterable, Codable, Identifiable {
    case all
    case automatic
    case codex
    case kimi
    case miniMax = "minimax"

    static let storageKey = "menuBarContentSelection"

    var id: String { rawValue }

    var provider: UsageProvider? {
        switch self {
        case .all, .automatic: return nil
        case .codex: return .codex
        case .kimi: return .kimi
        case .miniMax: return .miniMax
        }
    }
}

/// Ring preferences are separate from the legacy text-mode provider picker.
enum MenuBarRingDisplayMode: String, CaseIterable, Identifiable {
    case all
    case automatic
    static let storageKey = "menuBarRingDisplayMode"
    var id: String { rawValue }
}

struct MenuBarRingPreferences {
    static let providersKey = "menuBarRingSelectedProviders"
    static let providerOrder: [UsageProvider] = [.codex, .kimi, .miniMax, .glm]
    let mode: MenuBarRingDisplayMode
    let providers: Set<UsageProvider>

    static func load(from defaults: UserDefaults) -> Self {
        let legacy = defaults.string(forKey: MenuBarContentSelection.storageKey)
            .flatMap(MenuBarContentSelection.init(rawValue:)) ?? .automatic
        let mode = defaults.string(forKey: MenuBarRingDisplayMode.storageKey)
            .flatMap(MenuBarRingDisplayMode.init(rawValue:))
            ?? (legacy == .automatic ? .automatic : .all)
        let saved = defaults.stringArray(forKey: providersKey)
            .map { Set($0.compactMap(UsageProvider.init(rawValue:))) }
        let migrated = legacy.provider.map { Set([$0]) } ?? Set(providerOrder)
        return Self(mode: mode, providers: saved.flatMap { $0.isEmpty ? nil : $0 } ?? migrated)
    }
}

/// How the selected provider is rendered in the macOS menu bar.
enum MenuBarAppearance: String, CaseIterable, Codable, Identifiable {
    case detailedText
    case compactRing

    static let storageKey = "menuBarAppearance"

    var id: String { rawValue }
}

/// How precisely the bidirectional fan pace glyph maps a pace delta to center fill.
enum MenuBarPaceDisplayMode: String, CaseIterable, Codable, Identifiable {
    /// Preserve the three glanceable 1/3, 2/3, and full-fill levels.
    case staged
    /// Map every percentage point directly to the filled width.
    case continuous

    static let storageKey = "menuBarPaceDisplayMode"

    var id: String { rawValue }
}

/// 一个 AI 都没开时（跟随模式无活动窗口 / 显示被手动暂停），菜单栏占位显示什么。
///
/// 三选一取代了原来那个「是否显示数量」的开关 —— 那是两种形态的布尔表达，
/// 塞不进第三种。
enum MenuBarPlaceholderStyle: String, CaseIterable, Codable, Identifiable {
    /// 默认：环内一枚 OpenAI 连通性记号（对勾 / 叉 / 探测中）。
    ///
    /// 占位本来就「什么都没得显示」，但连通性是此刻唯一仍然成立、而且用户
    /// 真在意的信息 —— 它直接回答「现在能不能顺利拉起 ChatGPT 桌面端」。
    /// 否则占位期间菜单栏就是一个纯装饰的死环。
    case openAIConnectivity
    /// 哑色环 + 已启用供应商数量。
    case providerCount
    /// 复刻 App 图标构图（哑色开环 + "A" + 中心点/翼瓣）的品牌字母标。
    case brandMark

    static let storageKey = "menuBarPlaceholderStyle"

    /// 读出偏好，缺省即连通性形态。
    ///
    /// 旧的布尔 key `menuBarPlaceholderShowsCount` **刻意不读**：它只表达
    /// 「数量 vs 品牌标」两种形态，装不下第三种，迁移它等于替用户把新默认
    /// 又关回去。两个旧形态仍然都在这里，切回去是一次设置点击的事。
    static func stored(in defaults: UserDefaults = .standard) -> MenuBarPlaceholderStyle {
        defaults.string(forKey: storageKey)
            .flatMap(MenuBarPlaceholderStyle.init(rawValue:))
            ?? .openAIConnectivity
    }

    var id: String { rawValue }
}

/// 任务能量波在紧凑环上的排布模式。`.chaseQueue` 是可整体摘除的实验布局：
/// 移除时删除本枚举、各渲染层的 `taskWaveLayout` 参数、
/// `MenuBarTaskChaseQueueMotion` 与设置项即可完整回落到 `.evenlySpaced` 行为。
enum MenuBarTaskWaveLayout: String, CaseIterable, Codable, Identifiable {
    /// 波头沿完整圆周均匀分布（历史行为；部分时刻会被顶部缺口遮挡）。
    case evenlySpaced
    /// 追逐队列：波在可见弧上首尾相接成队行进，波头永不被缺口遮挡。
    case chaseQueue

    static let storageKey = "menuBarTaskWaveLayout"

    var id: String { rawValue }
}

/// Which quota window supplies the compact ring's outer arc. Providers without
/// a weekly window keep using their current window. `.total` is the provider's
/// monthly overall quota (Kimi "Total usage").
enum MenuBarRingQuotaWindow: String, CaseIterable, Codable, Identifiable {
    case weekly
    case current
    case total

    static let storageKey = "menuBarRingQuotaWindow"

    var id: String { rawValue }
}

/// Which quota window supplies the bidirectional fan center's reserve/deficit pace.
enum MenuBarReserveQuotaWindow: String, CaseIterable, Codable, Identifiable {
    case synchronized
    case weekly
    case current
    case total

    static let storageKey = "menuBarReserveQuotaWindow"

    var id: String { rawValue }

    func resolved(outerRing: MenuBarRingQuotaWindow) -> MenuBarRingQuotaWindow {
        switch self {
        case .synchronized: return outerRing
        case .weekly: return .weekly
        case .current: return .current
        case .total: return .total
        }
    }
}

extension UsageProvider {
    /// Ring data windows this provider can actually supply. MiniMax only has a
    /// current window; only Kimi exposes a monthly total ("Total usage").
    var supportedRingWindows: [MenuBarRingQuotaWindow] {
        switch self {
        case .kimi: return [.current, .weekly, .total]
        case .codex, .glm: return [.current, .weekly]
        case .miniMax: return [.current]
        }
    }
}

/// Per-provider ring data-source overrides. A nil field follows the global
/// `menuBarRingQuotaWindow` / `menuBarReserveQuotaWindow` defaults, so existing
/// users keep their previous behavior until they customize a provider.
struct MenuBarProviderRingWindows: Codable, Equatable {
    var outer: MenuBarRingQuotaWindow?
    var center: MenuBarReserveQuotaWindow?

    static let storageKey = "menuBarProviderRingWindows"

    static func load(from defaults: UserDefaults) -> [UsageProvider: MenuBarProviderRingWindows] {
        guard let data = defaults.data(forKey: storageKey),
              let raw = try? JSONDecoder().decode([String: MenuBarProviderRingWindows].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            UsageProvider(rawValue: key).map { ($0, value) }
        })
    }

    static func save(_ map: [UsageProvider: MenuBarProviderRingWindows], to defaults: UserDefaults) {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(raw), forKey: storageKey)
    }
}

enum MenuBarCompactLayoutPreferences {
    static let horizontalPaddingKey = "menuBarCompactHorizontalPadding"
    static let ringSpacingKey = "menuBarCompactRingSpacing"
    static let defaultHorizontalPadding = 0.0
    static let defaultRingSpacing = 1.0
    static let horizontalPaddingRange = 0.0...8.0
    static let ringSpacingRange = 0.0...8.0

    static func horizontalPadding(_ value: Double) -> Double {
        min(horizontalPaddingRange.upperBound,
            max(horizontalPaddingRange.lowerBound, value))
    }

    static func ringSpacing(_ value: Double) -> Double {
        min(ringSpacingRange.upperBound,
            max(ringSpacingRange.lowerBound, value))
    }
}

/// 菜单栏占位（`.placeholder`）的原因。
enum MenuBarPlaceholderReason {
    /// 跟随模式下没有供应商的应用在运行。
    case followMode
    /// 供应商显示被手动全部暂停。
    case manuallyPaused
}

enum MenuBarSnapshotState: Equatable {
    case needsSetup
    case loading
    case ready
    case unavailable
    case failed
    /// 主动隐藏的占位（跟随模式下应用未运行，或供应商显示被手动暂停）。
    /// 与 `.unavailable`（刷新失败/无数据，红色警示）刻意区分。
    case placeholder
}

enum MenuBarPaceDirection: Equatable {
    case deficit
    case onTrack
    case reserve
}

enum MenuBarCompactSnapshotSelector {
    static func select(
        mode: MenuBarRingDisplayMode,
        snapshots: [MenuBarSnapshot],
        activeProviders: Set<UsageProvider>
    ) -> [MenuBarSnapshot] {
        guard mode == .automatic else { return snapshots }
        let supported = snapshots.filter {
            $0.provider == .codex || $0.provider == .kimi
        }

        let active = supported.filter {
            activeProviders.contains($0.provider)
        }
        let persistent = snapshots.filter {
            $0.provider == .miniMax || $0.provider == .glm
        }
        if !active.isEmpty {
            return snapshots.filter { active.contains($0) || persistent.contains($0) }
        }
        guard let lowestRemaining = supported.min(by: {
            ($0.ringPercent ?? $0.remainingPercent ?? .greatestFiniteMagnitude)
                < ($1.ringPercent ?? $1.remainingPercent ?? .greatestFiniteMagnitude)
        }) else {
            return persistent
        }
        return snapshots.filter { $0 == lowestRemaining || persistent.contains($0) }
    }
}

/// Pace encoding for the bidirectional fan bars. Weekly pace deviation is normalized
/// so one day fills the inner sector of the active side and two days fill it completely.
struct MenuBarPaceGlyph: Equatable {
    static let weeklyCycleDays = 7.0
    static let fullScaleDeviationDays = 2.0
    static let percentPointsPerDay = 100 / weeklyCycleDays
    static let fullScaleDeltaPercent = percentPointsPerDay * fullScaleDeviationDays

    let direction: MenuBarPaceDirection
    let fillFraction: Double
    /// The active-side outline is reserved for deviation beyond the two-day
    /// fill scale. At or below two days, fill alone communicates magnitude.
    let showsActiveBorder: Bool

    init(deltaPercent: Double?, mode: MenuBarPaceDisplayMode = .staged) {
        guard let deltaPercent else {
            direction = .onTrack
            fillFraction = 0
            showsActiveBorder = false
            return
        }

        let magnitude = abs(deltaPercent)
        let continuousFraction = min(1, magnitude / Self.fullScaleDeltaPercent)
        showsActiveBorder = magnitude > Self.fullScaleDeltaPercent

        switch mode {
        case .staged:
            guard magnitude > 2 else {
                direction = .onTrack
                fillFraction = 0
                return
            }

            direction = deltaPercent < 0 ? .deficit : .reserve
            // Bias staged rendering upward so it remains an alerting view:
            // 25 / 50 / 75 / 100%, with exact one- and two-day anchors.
            fillFraction = min(1, ceil(continuousFraction * 4) / 4)
        case .continuous:
            guard magnitude > 0.0001 else {
                direction = .onTrack
                fillFraction = 0
                return
            }
            direction = deltaPercent < 0 ? .deficit : .reserve
            fillFraction = continuousFraction
        }
    }
}

/// 紧凑环内那条趋势曲线的数据点。
///
/// 横轴是样本在**本窗口时间轴**上的位置，不是它在数组里的序号：窗口第一天的
/// 采样就该贴在左边，今天的采样贴在右边，历史因此是从左往右长出来的。按序号
/// 排会让两个点横跨整个环，看上去像一周走了个来回，那是假的。
struct MenuBarRingTrendPoint: Equatable {
    /// 0...1，相对窗口起点
    let x: Double
    /// 0...1，剩余百分比
    let y: Double
}

/// 紧凑环内那条趋势曲线的取值约束。
///
/// 只有 Weekly、没有 5h 的账号才用得上：5h 短窗口看的是「这一轮烧得快不快」，
/// 用环内扇形节奏表达就够了；周窗口跨好几天，单一节奏值看不出形状，只能看趋势。
enum MenuBarRingTrend {
    /// 环内圈要画趋势，至少得有两个点 —— 一个点画不出线，只会在扇形的位置上
    /// 留下一个孤零零的圆点，看着像渲染坏了。
    ///
    /// 注意这和**左键菜单那行**的规则是两回事：那一行是「进度条还是曲线图」的
    /// 结构性选择，来回跳会让人分不清今天看到的是规则变了还是数据没攒够，所以
    /// 那边一个点也照画曲线。环内圈本来就是节奏扇形的地盘，只有真的画得出线
    /// 才让位给它，否则老老实实继续显示扇形。
    static let minimumPoints = 2
    /// 菜单栏图标只有二十几像素宽，点数再多也分辨不出来，反而挤成锯齿。
    static let maximumPoints = 24
}

/// One deterministic frame in the refresh self-test loop.
/// The outer Weekly ring sweeps continuously while the center demonstrates
/// deficit, on-pace, and reserve in three equal phases.
struct MenuBarSelfTestFrame: Equatable {
    static let cycleDuration: TimeInterval = 3

    let ringPercent: Double
    let paceDeltaPercent: Double

    static func frame(
        elapsed: TimeInterval,
        paceDisplayMode: MenuBarPaceDisplayMode = .staged
    ) -> MenuBarSelfTestFrame {
        let safeElapsed = max(0, elapsed)
        let cyclePosition = safeElapsed
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        let ringPercent = 50 - 42 * cos(cyclePosition * 2 * .pi)
        let phasePosition = cyclePosition * 3
        let phase = min(2, Int(phasePosition))
        let localPosition = phasePosition - Double(phase)
        let easedPosition = localPosition * localPosition * (3 - 2 * localPosition)
        let demonstratedDelta: Double
        switch paceDisplayMode {
        case .staged:
            // Cross all four alerting levels and finish at two days of deviation.
            demonstratedDelta = 3
                + (MenuBarPaceGlyph.fullScaleDeltaPercent - 3) * easedPosition
        case .continuous:
            // Sweep nearly the full two-day scale while preserving a fine start.
            demonstratedDelta = 1
                + (MenuBarPaceGlyph.fullScaleDeltaPercent - 1) * easedPosition
        }

        switch phase {
        case 0:
            return MenuBarSelfTestFrame(
                ringPercent: ringPercent,
                paceDeltaPercent: -demonstratedDelta)
        case 1:
            return MenuBarSelfTestFrame(
                ringPercent: ringPercent,
                paceDeltaPercent: 0)
        default:
            return MenuBarSelfTestFrame(
                ringPercent: ringPercent,
                paceDeltaPercent: demonstratedDelta)
        }
    }
}

/// Structured menu-bar data shared by text and graphical renderers.
/// Keeping the semantics here avoids parsing the formatted status-bar string.
struct MenuBarSnapshot: Equatable {
    let provider: UsageProvider
    let modelName: String?
    let remainingPercent: Double?
    /// Direct fraction for the compact ring. All providers use remaining percent;
    /// Codex specifically sources it from the Weekly quota window.
    let ringPercent: Double?
    let paceDeltaPercent: Double?
    /// 环内趋势曲线的采样点，按采样时间从左到右。
    ///
    /// 非 nil 时环内画曲线、**不**画双向节奏扇形 —— 两者抢占同一块内圈，
    /// 同时画只会互相糊住。只有 Weekly 没有 5h 的 Codex 账号走这条：
    /// 周窗口的「快慢」单值没有信息量，形状才有。
    let ringTrend: [MenuBarRingTrendPoint]?
    let resetsAt: Date?
    let state: MenuBarSnapshotState
    let isLowQuota: Bool
    let tooltip: String
    /// 仅 `.placeholder` 状态使用：已启用的供应商数量（计数徽标开关用）。
    var placeholderProviderCount: Int? = nil

    var providerInitial: String {
        switch provider {
        case .codex: return "C"
        case .kimi: return "K"
        case .miniMax: return "M"
        case .glm: return "G"
        }
    }
}
