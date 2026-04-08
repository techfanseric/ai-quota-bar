# Menu Bar Model Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to select which model with remaining quota is displayed in the menu bar, showing its remaining count and reset time in format `modelName remaining/resetTime`. Collapse exhausted models in dropdown menu.

**Architecture:** Add new `DisplayFormat.specificModel` case. Add `selectedModelName` to ViewModel for user selection. Update `formattedRemaining()` to handle new format. Add model picker to Settings appearance tab.

**Tech Stack:** SwiftUI, Combine, UserDefaults

---

## Task 1: Add specificModel case to DisplayFormat enum

**Files:**
- Modify: `MiniMaxUsageMonitor/Models/UsageData.swift:184-199`

- [ ] **Step 1: Add specificModel case to DisplayFormat**

Modify the enum at line 184 in `UsageData.swift`:

```swift
enum DisplayFormat: Int, CaseIterable, Codable {
    case numberOnly = 0
    case numberWithUnit = 1
    case leveled = 2
    case specificModel = 3

    var description: String {
        switch self {
        case .numberOnly: return "Compact model summary"
        case .numberWithUnit: return "Model availability summary"
        case .leveled: return "Risk-aware model summary"
        case .specificModel: return "Primary model detail"
        }
    }
}
```

- [ ] **Step 2: Add specificModel handling in formattedRemaining()**

Modify the `formattedRemaining` method at line 22 in `UsageData.swift`:

```swift
func formattedRemaining(format: DisplayFormat, language: AppLanguage, warningThreshold: Double) -> String {
    switch format {
    case .numberOnly:
        return language.menuBarCompactText(ready: readyModelsCount, total: modelCount)
    case .numberWithUnit:
        return language.readyModelsText(readyModelsCount)
    case .leveled:
        if exhaustedModelsCount > 0 {
            return language.fullModelsText(exhaustedModelsCount)
        }
        let lowModels = lowModelsCount(threshold: warningThreshold)
        if lowModels > 0 {
            return language.lowModelsText(lowModels)
        }
        return language.readyModelsText(readyModelsCount)
    case .specificModel:
        return "—" // Will be replaced when we have selectedModelName
    }
}
```

---

## Task 2: Add selectedModelName and availableModels to UsageViewModel

**Files:**
- Modify: `MiniMaxUsageMonitor/ViewModels/UsageViewModel.swift`

- [ ] **Step 1: Add selectedModelName published property after displayFormat (after line 30)**

```swift
@Published var selectedModelName: String? {
    didSet {
        UserDefaults.standard.set(selectedModelName, forKey: "selectedModelName")
        updateStatusBarText()
    }
}
```

- [ ] **Step 2: Add availableModels computed property after statusBarText (after line 53)**

```swift
var availableModels: [ModelUsageData] {
    guard let data = usageData else { return [] }
    return data.models
        .filter(\.isCurrentIntervalAvailable)
        .sorted { $0.currentIntervalPercentageRemaining < $1.currentIntervalPercentageRemaining }
}
```

- [ ] **Step 3: Add UserDefaults loading for selectedModelName in init() (after line 86)**

```swift
self.selectedModelName = UserDefaults.standard.string(forKey: "selectedModelName")
```

- [ ] **Step 4: Update updateStatusBarText() to handle specificModel format**

Replace the `updateStatusBarText()` method (lines 55-65):

```swift
private func updateStatusBarText() {
    guard let data = usageData else {
        statusBarText = error != nil ? "—" : "..."
        return
    }

    switch displayFormat {
    case .specificModel:
        if let modelName = selectedModelName,
           let model = data.models.first(where: { $0.modelName == modelName }) {
            statusBarText = model.formattedMenuBarText(language: appLanguage)
        } else if let firstAvailable = availableModels.first {
            statusBarText = firstAvailable.formattedMenuBarText(language: appLanguage)
        } else {
            statusBarText = "—"
        }
    default:
        statusBarText = data.formattedRemaining(
            format: displayFormat,
            language: appLanguage,
            warningThreshold: warningThreshold
        )
    }
}
```

- [ ] **Step 5: Add formattedMenuBarText() extension to ModelUsageData**

Add at the end of `UsageData.swift`:

```swift
extension ModelUsageData {
    func formattedMenuBarText(language: AppLanguage) -> String {
        let remaining = currentIntervalRemaining
        let resetMinutes = minutesUntilReset(endTime)
        let resetText = formatResetTime(minutes: resetMinutes, language: language)
        return "\(modelName) \(remaining)/\(resetText)"
    }

    private func minutesUntilReset(_ endTime: Date?) -> Int {
        guard let endTime = endTime else { return 0 }
        let interval = endTime.timeIntervalSince(Date())
        return max(0, Int(interval / 60))
    }

    private func formatResetTime(minutes: Int, language: AppLanguage) -> String {
        if minutes <= 0 {
            return "0m"
        }
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = Double(minutes) / 60.0
        return String(format: "%.1fh", hours)
    }
}
```

---

## Task 3: Add new text keys to AppLanguage

**Files:**
- Modify: `MiniMaxUsageMonitor/Models/AppLanguage.swift`

- [ ] **Step 1: Add modelSelectionLabel and modelSelectionPlaceholder to AppText enum (after line 477)**

```swift
case modelSelectionLabel
case modelSelectionPlaceholder
```

- [ ] **Step 2: Add text cases in english switch (after case .unknownError: return "Unknown error")**

```swift
case .modelSelectionLabel: return "Display model"
case .modelSelectionPlaceholder: return "Select a model"
```

- [ ] **Step 3: Add text cases in simplifiedChinese switch (after case .unknownError)**

```swift
case .modelSelectionLabel: return "显示模型"
case .modelSelectionPlaceholder: return "选择模型"
```

- [ ] **Step 4: Update DisplayFormat title() to handle specificModel**

Modify the `title()` method in `DisplayFormat` extension:

```swift
case (.specificModel, .english):
    return "Primary Model"
case (.specificModel, .simplifiedChinese):
    return "主模型"
```

- [ ] **Step 5: Update DisplayFormat caption() to handle specificModel**

Modify the `caption()` method:

```swift
case (.specificModel, .english):
    return "Show selected model's remaining count and reset time."
case (.specificModel, .simplifiedChinese):
    return "显示所选模型的剩余次数和重置时间。"
```

- [ ] **Step 6: Update DisplayFormat preview() to handle specificModel**

Modify the `preview()` method:

```swift
case (.specificModel, .english):
    return "M* 1101/44.4h"
case (.specificModel, .simplifiedChinese):
    return "M* 1101/44.4h"
```

---

## Task 4: Add model picker to SettingsView appearance tab

**Files:**
- Modify: `MiniMaxUsageMonitor/Views/SettingsView.swift`

- [ ] **Step 1: Add selectedModelName state variable (after line 15)**

```swift
@State private var selectedModelName: String = ""
```

- [ ] **Step 2: Add computed property for available model names (after line 43)**

```swift
private var availableModelNames: [String] {
    viewModel.availableModels.map(\.modelName)
}
```

- [ ] **Step 3: Update loadCurrentSettings() to load selectedModelName (after line 328)**

```swift
selectedModelName = viewModel.selectedModelName ?? ""
```

- [ ] **Step 4: Add model picker UI to displaySection after the ForEach loop (before Divider at line 278)**

```swift
if !availableModelNames.isEmpty {
    VStack(alignment: .leading, spacing: 10) {
        Text(language.text(.modelSelectionLabel))
            .font(.system(size: 14, weight: .semibold))

        Picker(language.text(.modelSelectionPlaceholder), selection: $selectedModelName) {
            Text(language.text(.modelSelectionPlaceholder)).tag("")
            ForEach(availableModelNames, id: \.self) { modelName in
                Text(modelName).tag(modelName)
            }
        }
        .pickerStyle(.menu)
    }
}
```

- [ ] **Step 5: Update saveSettings() to save selectedModelName (after line 357)**

```swift
viewModel.selectedModelName = selectedModelName.isEmpty ? nil : selectedModelName
```

---

## Task 5: Update MenuView to collapse exhausted models

**Files:**
- Modify: `MiniMaxUsageMonitor/Views/MenuView.swift`

- [ ] **Step 1: Update modelsCard to separate available and exhausted models (lines 151-200)**

Replace the `modelsCard` computed property:

```swift
@ViewBuilder
private var modelsCard: some View {
    if let data = viewModel.usageData, !data.models.isEmpty {
        let availableModels = data.models.filter { $0.isCurrentIntervalAvailable }
            .sorted { $0.currentIntervalPercentageRemaining < $1.currentIntervalPercentageRemaining }
        let exhaustedModels = data.models.filter { !$0.isCurrentIntervalAvailable }
            .sorted { $0.currentIntervalPercentageRemaining < $1.currentIntervalPercentageRemaining }

        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(language.text(.models))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                // Available models first (sorted by percentage remaining, lowest first)
                ForEach(availableModels) { model in
                    ModelUsageRow(
                        model: model,
                        language: language,
                        warningThreshold: viewModel.warningThreshold
                    )

                    if model.id != availableModels.last?.id {
                        Divider()
                    }
                }

                // Collapsed section for exhausted models
                if !exhaustedModels.isEmpty {
                    CollapsibleSection(
                        title: language.fullModelsText(exhaustedModels.count),
                        count: exhaustedModels.count
                    ) {
                        ForEach(exhaustedModels) { model in
                            ModelUsageRow(
                                model: model,
                                language: language,
                                warningThreshold: viewModel.warningThreshold
                            )

                            if model.id != exhaustedModels.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify CollapsibleSection exists (lines 470-517)**

The `CollapsibleSection` component should already exist from previous work. Verify it's present.

---

## Task 6: Build and test

**Files:**
- None (build verification)

- [ ] **Step 1: Build the project**

Run: `swift build -c release --product MiniMaxUsageMonitor`
Expected: Build complete!

- [ ] **Step 2: Run the app**

Run: `make run`
Expected: App launches successfully

---

## Implementation Notes

- The model picker in Settings only shows when `availableModelNames` is not empty
- If `selectedModelName` is empty or the model no longer has quota, fallback to first available model
- The `formattedMenuBarText` method formats reset time as hours with 1 decimal (e.g., `44.4h`) or minutes if < 60 min
- Exhausted models are sorted by percentage remaining ascending in their collapsed section
