# AI Quota Bar - Menu Bar Model Selection

## Overview

Add ability for users to select which model with remaining quota is displayed in the menu bar, showing its remaining count and reset time.

## API Data Reference

From `GET /v1/api/openplatform/coding_plan/remains`:

```json
{
  "modelRemains": [
    {
      "modelName": "MiniMax-M*",
      "startTime": 1775631600000,
      "endTime": 1775649600000,
      "currentIntervalTotalCount": 4500,
      "currentIntervalUsageCount": 3399,
      "currentWeeklyTotalCount": 0,
      "currentWeeklyUsageCount": 0
    },
    {
      "modelName": "speech-hd",
      "currentIntervalTotalCount": 19000,
      "currentIntervalUsageCount": 19000
    }
  ]
}
```

Key fields:
- `currentIntervalTotalCount` - total quota in current interval
- `currentIntervalUsageCount` - used quota
- `endTime` - interval reset timestamp (Unix ms)
- `remaining = total - used`

## Feature 1: Dropdown Menu Sort & Collapse

### Sort Order
- **Available models** (remaining > 0): sorted by `currentIntervalPercentageRemaining` ascending (lowest/most urgent first)
- **Exhausted models** (remaining = 0): collapsed in expandable section at bottom

### Collapse Behavior
- Exhausted models section is **collapsed by default**
- Toggle via chevron button
- Header shows count: e.g., "5 exhausted"

## Feature 2: Menu Bar Model Display

### New Display Format: `modelName remaining/resetTime`

Example: `M* 1101/44.4h`

Format rules:
- `modelName`: use short name from API (e.g., "M*" instead of "MiniMax-M*")
- `remaining`: integer, e.g., `1101`
- `resetTime`: hours with 1 decimal place + "h", e.g., `44.4h`
- If reset < 60 min: show minutes, e.g., `30m`

### Settings UI

New picker in **Appearance** tab:
- Label: "Display model" (or localized equivalent)
- Shows only models with `remaining > 0`
- Dropdown with model names

### Data Flow

```
UsageData.models
  → filter(remaining > 0)
  → sort by percentageRemaining ascending
  → present as picker options

User selects model
  → store modelName in UserDefaults

StatusBar text update:
  → find selected model in models array
  → format as "modelName remaining/resetTime"
```

## UI Components

### SettingsView Changes

Add to Appearance tab:
- `modelSelectionLabel`: Text "Display model"
- `modelSelectionPicker`: Picker bound to `selectedModelName`

### UsageViewModel Changes

Add published property:
```swift
@Published var selectedModelName: String? {
    didSet {
        UserDefaults.standard.set(selectedModelName, forKey: "selectedModelName")
        updateStatusBarText()
    }
}
```

Add computed property:
```swift
var availableModels: [ModelUsageData] {
    models.filter(\.isCurrentIntervalAvailable)
        .sorted { $0.currentIntervalPercentageRemaining < $1.currentIntervalPercentageRemaining }
}
```

Update `updateStatusBarText()` to handle new format.

### AppLanguage Changes

Add new text keys:
- `modelSelectionLabel`
- `modelSelectionPlaceholder` (e.g., "Select a model")

## Localization

All new strings need both English and Simplified Chinese variants.

## Implementation Order

1. Update `UsageViewModel` - add `selectedModelName` and `availableModels`
2. Update `AppLanguage` - add new text keys
3. Update `SettingsView` - add model picker
4. Update `MenuView` - implement dropdown collapse
5. Update `UsageData.formattedRemaining()` - handle new display format
6. Test build and run

## Files to Modify

- `AIQuotaBar/ViewModels/UsageViewModel.swift`
- `AIQuotaBar/Models/AppLanguage.swift`
- `AIQuotaBar/Views/SettingsView.swift`
- `AIQuotaBar/Views/MenuView.swift`
- `AIQuotaBar/Models/UsageData.swift`
