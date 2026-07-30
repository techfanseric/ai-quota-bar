# AI Quota Bar

<p align="center">
  Know how much AI coding time you have left, keep long Codex tasks running, and recover OpenAI connections without leaving the menu bar.
</p>

<p align="center">
  <a href="https://github.com/techfanseric/ai-quota-bar/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/techfanseric/ai-quota-bar?display_name=tag"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/release-Apple%20Silicon-6f42c1">
  <a href="./LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
</p>

<p align="center">
  <a href="./README.zh-CN.md">简体中文</a> ·
  <a href="https://github.com/techfanseric/ai-quota-bar/releases/latest/download/AIQuotaBar.dmg">Download DMG</a> ·
  <a href="https://github.com/techfanseric/ai-quota-bar/releases">Release notes</a>
</p>

AI coding work is hard to manage when quota, network routes, and Mac sleep settings live in different places. AI Quota Bar brings them together: left-click to see whether your quota can support the work ahead, and right-click to keep Codex running or repair a slow or broken OpenAI connection.

<p align="center">
  <img src="./docs/images/control-center.png" alt="AI Quota Bar control center" width="342">
</p>

## What’s new in v1.7.0

This release makes both sides of the menu bar easier to read and turns the compact quota ring into a live answer to “is Codex still working?”

- **See active work without opening a menu.** When Codex is working, the remaining-quota arc softens and shows one directional energy wave per active task, up to five. When work stops, the arc returns to solid white.
- **Find the right route with less scanning.** Compact one-line rows show the protocol, route, and latency together. Recent switches keep the route change on the left and the time on the right.
- **Understand OpenAI activity faster.** Route controls, totals, the 60-minute age chart, and active connections stay in one vertical flow, with less secondary text competing for attention.
- **Get predictable native menu behavior.** The left-click dashboard uses the real macOS menu material and sizes itself for the display where it opens. The right-click control center keeps a consistent arrow-free frame.

People who enable **Reduce Motion** get a static task highlight instead of a travelling wave.

## What it helps you do

| Your goal | How AI Quota Bar helps |
| --- | --- |
| Plan work before quota runs out | See remaining Codex and MiniMax quota, reset times, recent usage, and whether your current pace is sustainable |
| Get OpenAI working again quickly | Test and switch Clash/Mihomo routes from the menu bar, or let the app recover automatically after a real outage |
| Understand a slow connection | See whether OpenAI has active traffic, whether data is moving, and whether old connections are piling up |
| Let long Codex tasks finish | Keep the Mac awake only while Codex is working, then return to normal automatically |
| Close the lid when necessary | Optionally keep a task running with safety cutoffs for battery, heat, lost contact, and maximum duration |
| Keep useful history | Optionally sync recent quota snapshots so trends remain available across Macs |

## Screenshots

### Quota dashboard

See every account in one place. The remaining percentage answers “how much is left,” while the trend and reserve/deficit message answer the more useful question: “at this pace, am I likely to make it to the reset?”

<p align="center">
  <img src="./docs/images/dropdown.png" alt="Quota dashboard" width="464">
</p>

### A quick answer without opening the menu

The menu bar ring shows Weekly quota at a glance. Its center tells you whether you have room to spare or are spending faster than the quota can sustain. While Codex is working, one flowing highlight per active task travels only through the remaining part of the ring, up to five waves. If both OpenAI sites become unreachable, the ring changes to an offline warning.

<p align="center">
  <img src="./docs/images/menu-bar-self-test-preview.png" alt="Compact Codex quota ring states" width="792">
</p>

### Cloud sync and retention

Choose how long recent quota history is kept, inspect the stored data, or delete one account without disturbing the others.

<p align="center">
  <img src="./docs/images/cloud-sync-settings.png" alt="Cloud sync settings" width="720">
</p>

## Requirements

- macOS 14 Sonoma or later.
- Apple Silicon for the prebuilt DMG. Source builds target the architecture of the build Mac.
- At least one quota provider:
  - Codex CLI installed and signed in.
  - MiniMax coding-plan bearer token.
- Optional: Clash Verge Rev, Mihomo, or Clash with a loopback-bound external controller.
- Optional: administrator approval to install the closed-lid helper.

## Install

1. Download the latest [`AIQuotaBar.dmg`](https://github.com/techfanseric/ai-quota-bar/releases/latest/download/AIQuotaBar.dmg).
2. Open the image and drag **AI Quota Bar** into **Applications**.
3. Launch the app and choose **Settings** from the left-click menu.

### Gatekeeper note

The public build is ad-hoc signed because the project does not currently use a paid Apple Developer certificate. It is not Apple-notarized. On first launch, macOS may require Control-clicking the app and choosing **Open**, or allowing it in **System Settings → Privacy & Security**. Do not disable Gatekeeper globally.

## Quick start

### Codex

If Codex already works in Terminal, setup is almost finished. Sign in once with the official CLI, then refresh AI Quota Bar:

```bash
codex
```

Your Codex accounts appear automatically and stay grouped separately. Credentials remain in the local Codex/CodexBar account store.

<details>
<summary>Advanced: choose where Codex quota is read from</summary>

AI Quota Bar uses [`CodexBarCore`](https://github.com/steipete/CodexBar) and offers these source choices:

- **Auto** — OAuth, CLI data, then local web session.
- **OAuth** — Codex CLI OAuth credentials only.
- **CLI** — local Codex/CodexBar configuration only.
- **Web** — local OpenAI browser session only.

</details>

### MiniMax

Open **Settings → Providers → MiniMax**, paste your MiniMax coding-plan token, and refresh. The token stays in macOS Keychain.

## Plan work before quota runs out

AI Quota Bar does more than show a percentage. It combines remaining quota, reset time, and recent pace so you can decide whether to continue a large task now, slow down, or move work to another account.

- Track Codex and MiniMax from one menu, including multiple Codex accounts.
- See both short limits such as **5h** and longer limits such as **Weekly**.
- Use the trend line to see how quickly quota is falling.
- Use the reserve/deficit message to see whether your current pace can last until reset.
- Receive a warning before a limit becomes a surprise.
- Use the compact ring when you only need a quick glance.

You can pin one provider in the menu bar or let Automatic mode surface whichever account needs attention first.

## Get OpenAI working again without opening Clash

When ChatGPT or Codex stops connecting, right-click the menu bar icon. AI Quota Bar finds the relevant local Clash/Mihomo group, tests its routes, and puts the fastest working choices first.

- Search by country in the way that feels natural: `🇯🇵`, `日本`, and `JP` all work.
- Turn on regex when you need precise route-name rules.
- Recognize common protocols such as Hysteria2, VLESS, and AnyTLS from compact badges without opening a second line of detail.
- Switch manually with one click and review the last three changes.
- Keep a filter such as a preferred country, then optionally let the app choose the fastest match when OpenAI is genuinely down.

Automatic recovery is intentionally cautious. It does nothing when you merely open the panel, run a speed test, or enable the option. It starts only after both `openai.com` and `chatgpt.com` fail twice in a row, tries filtered routes from fastest to slowest, stops as soon as connectivity returns, and then sends a notification.

For safety, AI Quota Bar accepts only Clash/Mihomo controllers on this Mac (`127.0.0.1`, `localhost`, or `::1`).

## Understand slow or stuck OpenAI traffic

When ChatGPT feels slow, the connection panel helps answer three quick questions:

- **Is anything connected?** See the active OpenAI/ChatGPT connection count.
- **Is data actually moving?** See total upload and download speed.
- **Is this a fresh request or a long-lived connection?** New connections are green and gradually turn orange as they age.

The 60-minute chart makes spikes, quiet periods, and connections that remain active unusually long easy to spot. The list below shows the host, protocol, route, age, and speed when Clash/Mihomo provides them.

This view is read-only: it never closes or changes your connections.

## Let long Codex tasks finish unattended

Start a long Codex task and step away without changing the Mac’s sleep settings for the whole day. AI Quota Bar detects when Codex is actually working and can keep the display awake, block the screen saver, and prevent idle sleep only for that active period.

When the last task finishes—or when you disable protection or quit the app—the Mac immediately returns to its normal behavior. Multiple simultaneous tasks are counted, so protection does not end early while another task is still running. The compact ring mirrors that count with up to five flowing waves, so you can confirm work is still active without opening the control center.

### Continue with the lid closed

If you occasionally need to close a MacBook while a task finishes, you can enable closed-lid mode separately. It is off by default and asks for administrator approval the first time.

The helper restores your previous sleep setting when:

- The Codex task finishes.
- The app disconnects or stops sending heartbeats.
- Battery falls below the safety threshold.
- macOS reports serious or critical thermal pressure.
- The 12-hour maximum lease expires.
- The user disables the feature.

This is a safety net, not a replacement for ventilation. A closed MacBook can cool less effectively, so use the option only when the machine has suitable airflow and power.

## Keep recent quota history available

If you use more than one Mac, or want recent charts to survive a reinstall, you can enable cloud sync. It backs up compact quota snapshots after successful refreshes and restores useful recent history on another device.

You stay in control:

- Keep data for 30 to 180 days.
- Hide stale cloud-only charts automatically.
- Inspect what is stored in a local report.
- Delete one account or clear all local/remote history.

Cloud sync is off by default. It uploads quota metadata and account labels, but never uploads MiniMax or Codex credentials. The exact data boundary is documented below.

## Privacy and security boundaries

- MiniMax credentials are stored in macOS Keychain.
- Codex credentials are managed locally by Codex/CodexBar.
- Clash/Mihomo access is limited to a loopback external controller.
- Connection monitoring is read-only.
- Codex task detection reads local lifecycle state and does not upload task content.
- Cloud sync is opt-in and never uploads provider credentials, but it does upload the quota metadata listed above.
- Closed-lid changes require explicit administrator approval and are automatically restored by the helper.

## Build from source

The Swift package currently expects CodexBar as a sibling checkout:

```bash
mkdir ai-quota-bar-workspace
cd ai-quota-bar-workspace
git clone https://github.com/steipete/CodexBar.git codexbar
git clone https://github.com/techfanseric/ai-quota-bar.git
cd ai-quota-bar

make build
make install
```

Build requirements:

- Xcode Command Line Tools with Swift 5.9 or later.
- macOS 14 SDK or later.
- `hdiutil`, `iconutil`, `sips`, and `codesign`, which ship with macOS/Xcode tools.

Useful commands:

```bash
swift test       # run the test suite
make build       # release binaries
make app         # assemble dist/AIQuotaBar.app
make install     # replace /Applications/AIQuotaBar.app and relaunch
make package     # create dist/AIQuotaBar.dmg
```

By default, `make package` uses ad-hoc signing. Set `CODESIGN_IDENTITY` to a suitable Developer ID identity if you maintain a signed/notarized distribution pipeline.

## Troubleshooting

### Clash routes are unavailable

- Confirm Clash/Mihomo is running.
- Enable its external controller.
- Bind the controller to a loopback address.
- Ensure the active rules for `openai.com` or `chatgpt.com` lead to a switchable strategy group.

### Automatic recovery does not switch

- Both public domains must fail twice.
- The auto-recovery switch must be on.
- The route filter must be non-empty and valid.
- At least one matching route must complete a latency test.

### Codex protection says no task is active

- Confirm Codex is currently executing, not waiting for input.
- Keep the Codex state directory at the default `~/.codex`, or set `CODEX_HOME` consistently.
- Restart AI Quota Bar once after upgrading so its bundled lifecycle hook can be registered.

### Closed-lid mode is unavailable

Use the feature switch once while the app is in the foreground and approve the administrator prompt. Installing a new app build changes the helper fingerprint, so the helper may require a one-time update.

## Acknowledgements

- [`CodexBar`](https://github.com/steipete/CodexBar) for `CodexBarCore`.
- Clash, Mihomo, and Clash Verge Rev for the local controller APIs used by route and connection monitoring.

## License

AI Quota Bar is released under the [MIT License](./LICENSE).
