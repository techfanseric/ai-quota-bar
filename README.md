# AI Quota Bar

A macOS menu bar application for monitoring model coding plan quota across providers.

AI Quota Bar is focused on coding-plan consumption: it tracks the remaining quota for supported AI coding models, shows per-model breakdowns, and warns you before a short-interval or subscription quota runs out. It currently supports MiniMax, GLM/Z.ai, and ChatGPT/Codex GPT coding quota snapshots.

## Features

- Menu bar widget displaying remaining coding-plan quota
- Detailed per-provider and per-model usage breakdown
- Quota trend charts for short-interval model limits
- Automatic menu bar fallback to the used model with the soonest reset when the displayed quota expires
- Right-click menu bar shortcut for cycling through used short-interval models
- Configurable refresh interval
- Warning notifications when quota runs low
- Secure provider credential storage via Keychain
- Optional cloud backup of quota snapshots through your own Cloudflare Worker + D1 database

## Screenshots

<!-- Menu Bar -->
![Menu Bar](./docs/images/menubar.png)

<!-- Dropdown Menu -->
![Dropdown Menu](./docs/images/dropdown.png)

<!-- Settings -->
![Settings](./docs/images/settings.png)

## Requirements

- macOS 14+
- MiniMax API key, GLM quota curl command, ChatGPT/Codex session JSON or quota curl command, or any combination of them

## Build & Run

```bash
make build
make run
```

## License

This project is licensed under the MIT License - see [LICENSE](LICENSE) for details.

## Install

```bash
make install
```

## Configuration

1. Click the menu bar icon
2. Select **Settings**
3. Enter a MiniMax API key, paste a GLM quota curl command, paste a ChatGPT/Codex session JSON or quota curl command, or configure multiple providers
4. Configured providers refresh together and appear as separate sections in the menu
5. Adjust refresh interval as needed

## Menu bar behavior

The menu bar item shows one primary quota at a time. When the displayed model is exhausted or its reset window has already passed, AI Quota Bar automatically falls back to the eligible model whose reset time arrives soonest. Models that are still at full quota are skipped when there is already-used quota to show, so the menu bar stays focused on active limits.

Left-click the menu bar item to open the detailed dropdown. Right-click it to quickly cycle through used short-interval models, which are the models shown with trend charts in the dropdown rather than long-window progress bars.

## MiniMax support

For MiniMax, paste the bearer token used by the MiniMax coding plan remains endpoint. The app calls the MiniMax coding plan quota API and maps the returned model quota windows into the menu bar and dropdown views.

## GLM support

For GLM/Z.ai, the quota API is tied to your signed-in web session. You need to copy the request from the official website yourself:

1. Sign in to the official BigModel/Z.ai website in your browser.
2. Open the coding plan or quota page where your model quota is displayed.
3. Open the browser developer tools.
4. Refresh the quota page or trigger the quota query again.
5. In the Network panel, find the `quota/limit` request.
6. Copy that request as a curl command.
7. Paste the full curl command into AI Quota Bar Settings.

The app parses the endpoint URL, `authorization`, `bigmodel-organization`, `bigmodel-project`, and cookie fields, then stores the parsed credential in Keychain.

GLM quota fields are mapped differently from MiniMax:

- `currentValue` means used amount.
- `usage` means total amount.
- Remaining amount is calculated as `usage - currentValue`.
- `TOKENS_LIMIT` is shown as `GLM Tokens (5h)`.
- `TIME_LIMIT` is shown as `GLM MCP/Search (month)`.

Because the GLM credential comes from your browser session, it may expire. If GLM refresh fails after a while, repeat the steps above and paste a fresh curl command.

## ChatGPT/Codex GPT support

For ChatGPT/Codex GPT coding quota, the app reads ChatGPT web-session usage data and maps the Codex rate-limit windows into the menu:

- `primary_window` is shown as `5h`, with remaining quota displayed as a percentage and reset shown as a time.
- `secondary_window` is shown as `Weekly`, with remaining quota displayed as a percentage and reset shown as a date.
- Plan details such as Plus or Pro are shown when returned by the session/usage response.
- Multiple ChatGPT accounts can be configured, named, tested, and displayed separately.

The easiest setup path is to paste the ChatGPT account/session JSON that contains an `accessToken`; AI Quota Bar uses it with `https://chatgpt.com/backend-api/codex/usage`. You can also paste a copied curl command for the same endpoint from the browser Network panel.

The ChatGPT web API is not a public stable API, so response fields can change. AI Quota Bar stores provider credentials in one Keychain JSON item and uses a flexible parser that looks for common fields such as utilization percentage, remaining percentage, reset time, `primary_window`, and `secondary_window`.

Existing single-account ChatGPT credentials are migrated into the multi-account storage format automatically when loaded.

## Cloud backup

AI Quota Bar can back up quota snapshots to a Cloudflare D1 database through a small Worker in `cloudflare/`.
Provider credentials are not uploaded; MiniMax, GLM, and ChatGPT credentials remain in macOS Keychain.

See `cloudflare/README.md` for the Cloudflare setup steps, then paste the deployed Worker URL and sync token into Settings.
After setup, use **Settings -> Cloud backup -> View remote data** to open a local HTML report of the remote D1 data. The fallback command is `cloudflare/view-remote-data.command`.

## Release highlights

### 1.4.0

- Added optional Cloudflare Worker + D1 cloud backup for quota snapshots.
- Added a Settings shortcut to view remote stored quota data as a local HTML report.
- Kept provider credentials local in Keychain while storing only compact quota history remotely.
- Added launch-at-login preferences and improved model grouping for exhausted/full quota rows.

### 1.3.2

- Added right-click menu bar cycling for used short-interval quota windows.
- Improved automatic menu bar fallback so expired or exhausted selections rotate to the soonest reset among active, already-used models.
- Skipped full, unused quota windows during active-model cycling.
- Added README coverage for multi-account ChatGPT setup introduced after 1.3.0.

### 1.3.1

- Fixed ChatGPT short-window quota chart detection.
