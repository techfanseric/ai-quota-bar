# Website UI fidelity audit — v1.19.0

Baseline: the current native implementations, native SwiftUI rendering fixtures, and the shipped MobileDashboard frontend. Website examples use fictional data; they do not access the visitor's app, credentials or usage.

| Website region | Reference | Finding and correction |
| --- | --- | --- |
| Left-click menu | `MenuView.swift`, `CodexUsageTrend.swift` | Current account goes above local usage. Restore provider artwork, compact typography and native 296-point panel structure. |
| Menu local usage | `CodexUsageActivityView` | Replace obsolete 30-day matrix plus hourly bars with current-month calendar beside 24 × 12 five-minute cells. Show Month and Last 24h totals beneath. |
| Usage settings | `CodexLocalUsageSection`, `CodexUsageAccountPicker` | Remove redundant Local header and obsolete member disclosure. Restore compact account picker, unknown-account explanation, token breakdown, price coverage, model/scan details and price-import label. Chart stays at most 420 points wide. |
| Metrics and data | `UsageHistory`, `UsageSummary`, `UsageTokens` | Shared deterministic fixture computes input + output totals, input-weighted cache rates and account scopes. No cost tab without priced nonempty buckets. Unpriced coverage is 0/N, not an inconsistent 84/84. Future days, renewal marker and hover semantics match the component. |
| Quota curves | `QuotaAreaChart` in `MenuView.swift` | Current samples stop at the sampled time; projections continue separately. Historical cycles hide current pace guides and forecasts. |
| Cycle bars | `ModelUtilizationBarsView` | Chronological order is oldest to newest. Height represents used quota; labels and callouts show remaining quota. Hover exposes remaining percentages. |
| Menu bar rings | `CodexRingView` in `StatusBarController.swift` | Restore pace core at rest and provider initial on hover. Hero and state examples now share a renderer; task waves and reduced-motion handling retained. |
| Team | `TeamSettingsSection`, `TeamSettingsRenderingTests` | Replace invented management table with an actual native rendering using a fictional team; paused sharing is explicitly labelled. Management console remains linked separately. |
| Model display | `ModelDisplaySettings` | Verify account master switch preserves model choices, menu counts, independent mobile choices, min 1/max 2 selections and chart style choices. |
| Task protection and routes | `ClashRoutePopoverView`, status/protection views | Check headings, switches, optional closed-lid mode, route rows, latency states and filter-dependent recovery. Static sample controls are presentation only. |
| Connections | `ClashConnectionPopoverView` | Check download/upload/count ordering, age-coloured connection history, active rows and read-only status. |
| Phone/tablet dashboard | `Resources/MobileDashboard/{index.html,app.css,app.js}` | Build continues to reuse actual app source. Only initialization is replaced with fictional data. Explicit page language now controls preview language; release and reset-time labels corrected. |

Validation: 67 backend/fixture tests; browser checks of both languages, 390/768/1440 CSS-pixel widths, 288 recent cells per chart, account/metric selection, hover intervals, cycle preview, display selection limits, image loading and both real dashboard embeds. A tablet-width overflow in the English ring examples was corrected. The hour labels also exposed an intrinsic CSS grid track sizing bug: 9.28px inner tracks overflowed 7px allocated columns in the hero. Explicit minmax(0, 1fr) inner tracks eliminate this. All 288 cells in both charts were measured at each of the three viewport widths: zero cell overflow and zero adjacent-column overlap.

The browser is not macOS SwiftUI: native font rasterization, system dropdown chrome and vibrancy may differ. Explicit examples of empty/unpriced, current-account versus all-account data, sharing paused, light landscape and dark portrait states are intentional. No live account data is embedded.
