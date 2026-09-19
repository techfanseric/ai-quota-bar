# Quota symbol family

Source artwork: `AIQuotaBar/Resources/QuotaSymbols/{reserve,deficit,pace,disable}.svg`, supplied on 2026-09-19. The source files are preserved unchanged. The accepted B refinement uses two 110° sectors per direction (radii 42–69 and 82–109), a 38-unit center dot, and a letter raised by 10 units. Runtime geometry lives in `QuotaSymbolRenderer.swift`; it scales the 367 × 410 design to a 20pt-high menu-bar symbol and adapts foreground/track contrast to appearance.

| Channel | Meaning |
| --- | --- |
| C / K / M / G in the top opening | Codex / Kimi / MiniMax / GLM, always visible; independent of state |
| Clockwise 256° arc (104° top opening) | Remaining quota, driven by the selected quota window; the letter opening remains even at 100% |
| Upper fan sectors filled | Reserve: consumption is behind the budgeted pace |
| Lower fan sectors filled | Deficit: consumption is ahead of the budgeted pace |
| Center dot only | Confirmed on-pace; inactive sectors remain visible |
| All sectors muted | Pace unknown, loading, or setup required; never represented as confirmed on-pace |
| Yellow arc | Existing low-quota flag (configured warning threshold, or existing 20% fallback); independent of deficit |
| Red arc and horizontal dash | Failed/unavailable data or confirmed Codex connectivity outage; retain last known quota when present |
| Pulsing red dash | Codex offline; provider identity and quota remain steady |
| Moving arc waves | Active tasks, capped at five; stay on the open arc, clear of the letter |

Loading uses a muted partial arc; setup uses the empty track. Tooltips retain the exact error/setup/network explanation. The three-second refresh self-test continues to sweep quota and demonstrate deficit → pace → reserve, including a yellow low-quota example; it uses the same renderer. Actual offline state is not overwritten after the self-test ends.

Pace uses the existing selected cycle and deviation scale: four staged levels, or continuous fill. Fill grows from the waist outward through the two annular sectors on the relevant side, with symmetric angular fill, saturating at the existing two-day scale. The source artwork depicts fully filled reserve/deficit examples, not a particular provider's permanent status.

The launch icon uses A for AI Quota Bar, a neutral on-pace center, and a 75% illustrative arc. It is branding, not live telemetry. macOS assets, mobile dashboard home-screen icons, and the website logo share this shape; provider-owned logos remain provider identities. `favicon.svg` is regenerated with the same open ring, fan geometry, and A.

Regenerate bitmap assets from the same native vector renderer:

```sh
swiftc AIQuotaBar/Models/QuotaSymbolRenderer.swift scripts/generate-quota-icons.swift -o /tmp/generate-quota-icons
/tmp/generate-quota-icons
make app
```

`make app` packages all asset-catalog sizes into AppIcon.icns. Tests cover directional sectors, unknown pace, persistent provider initials, live task frames, low-quota/error precedence, Codex-only offline scope, and light/dark appearance at 1×/2×.

Final status-button images are non-template bitmaps so macOS retains yellow/red. They are regenerated when the menu bar appearance or backing scale changes. Cached frame sequences include self-test and offline pulses, not only task waves; Reduce Motion produces a still frame. Hover retains both pace and task animation.

Task-motion refinement: cached frames retain native 1× and 2× representations simultaneously, with integral image bounds and pixel-aligned placement. Playback uses elapsed time at 30 fps and keeps phase through refreshes. The quota arc remains opaque; a thin contrasting trace moves inside it using 16 gradient segments, following a complete physical orbit masked at the 104° opening. No adaptive spatial-resolution reduction is used.
