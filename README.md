# MiniMax Usage Monitor

A macOS menu bar application for monitoring MiniMax and GLM API usage and quota.

## Features

- Menu bar widget displaying remaining quota
- Detailed usage view with per-model breakdown
- Quota trend charts for short-interval models
- Configurable refresh interval
- Warning notifications when quota runs low
- Secure provider credential storage via Keychain

## Screenshots

<!-- Menu Bar -->
![Menu Bar](./docs/images/menubar.png)

<!-- Dropdown Menu -->
![Dropdown Menu](./docs/images/dropdown.png)

<!-- Settings -->
![Settings](./docs/images/settings.png)

## Requirements

- macOS 14+
- MiniMax API key or GLM quota curl command

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
3. Enter a MiniMax API key, paste a GLM quota curl, or configure both
4. Configured providers refresh together and appear as separate sections in the menu
5. Adjust refresh interval as needed

## GLM support

For GLM, open the BigModel/Z.ai coding plan page, copy the `quota/limit` request as curl, and paste the full command into Settings. The app parses the endpoint URL, `authorization`, `bigmodel-organization`, `bigmodel-project`, and cookie fields, then stores the parsed credential in Keychain.

GLM quota fields are mapped differently from MiniMax:

- `currentValue` means used amount.
- `usage` means total amount.
- Remaining amount is calculated as `usage - currentValue`.
- `TOKENS_LIMIT` is shown as `GLM Tokens (5h)`.
- `TIME_LIMIT` is shown as `GLM MCP (month)`.
