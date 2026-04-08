# MiniMax Usage Monitor - Design Specification

**Date**: 2026-04-08
**Version**: 1.0

## 1. Project Overview

**Name**: MiniMax Usage Monitor
**Bundle ID**: com.minimax.usagemonitor
**Type**: macOS menu-bar application (LSUIElement mode)
**Target**: macOS 14.0+

Monitor MiniMax API usage quota and display remaining balance in the menu bar with configurable warning notifications.

---

## 2. Technical Stack

- **Language**: Swift
- **UI Framework**: SwiftUI (primary), AppKit (menu bar integration)
- **Architecture**: MVVM
- **Dependencies**: None (native URLSession, Keychain)
- **Build**: Swift Package Manager + Makefile

---

## 3. Core Features

### 3.1 Menu Bar Display
- Display remaining quota in status bar (configurable format)
- Click to open dropdown menu

### 3.2 Dropdown Menu Contents
- Current account remaining quota (tokens/credits)
- Last refresh timestamp
- Manual refresh button
- Settings entry
- Quit button

### 3.3 Settings Window (NSWindow with SwiftUI)
- MiniMax API Key input (Keychain secure storage)
- Refresh interval setting (seconds, default 60)
- Auto-refresh on launch toggle
- Menu bar display format selector (three options)
- Save / Test Connection button

### 3.4 Real-time Monitoring & Warning
- Threshold configuration (e.g., below 20% remaining)
- NSPanel warning notification (bottom-right corner, .hudWindow material, borderless capsule)
- Display content: current remaining amount, timestamp, estimated exhaustion time

---

## 4. Data Flow

```
API (minimaxi.com)
    → UsageService (fetch + parse)
        → UsageViewModel (state management)
            → StatusBarController (status item)
            → MenuView (dropdown)
            → WarningPanel (threshold alert)
```

- **Keychain**: Secure API key storage
- **UserDefaults**: Preferences (refresh interval, display format, threshold)

---

## 5. Project Structure

```
MiniMaxUsageMonitor/
├── App/
│   ├── main.swift
│   ├── AppDelegate.swift
│   └── StatusBarController.swift
├── Views/
│   ├── MenuView.swift
│   ├── SettingsView.swift
│   └── WarningPanelView.swift
├── ViewModels/
│   └── UsageViewModel.swift
├── Services/
│   ├── UsageService.swift
│   └── KeychainService.swift
├── Models/
│   └── UsageData.swift
└── Resources/
    └── Assets.xcassets
```

---

## 6. Error Handling

- API request failure: Menu bar shows `—`, dropdown shows error state with retry button
- Keychain access failure: Alert dialog, guide user to re-enter API Key
- Network unavailable: Auto-pause polling, resume when connection restored

---

## 7. Security Considerations

- API Key stored only in Keychain, never in UserDefaults or code
- HTTPS encrypted transmission
- LSUIElement mode (no Dock icon), reduces accidental exposure

---

## 8. Window & Panel Specifications

| Window/Panel | Type | Size | Features |
|--------------|------|------|----------|
| Menu bar status item | NSStatusItem | System default | Text/symbol |
| Dropdown menu | NSMenu | System default | Native menu |
| Settings window | NSWindow (SwiftUI) | 480×360 | Titled, closable, minimizable |
| Warning panel | NSPanel | 280×120 | .hudWindow, .nonactivatingPanel, bottom-right |

---

## 9. Display Format Options (Configurable)

1. **Number only** — e.g., `85%` or `1523K`, minimal space
2. **Number + unit** — e.g., `85% remaining` or `1.5M tokens`, clear meaning
3. **Leveled display** — Show simple when sufficient, detailed when low (e.g., `⚠️ 18% (~2 days)`)

---

## 10. Build & Distribution

- **Target**: macOS 14.0+
- **Build**: Swift Package Manager + Makefile
- **Makefile targets**: build / run / install / clean
- **Code signing**: .app bundle signed (ad-hoc for local development)
