# MiniMax Usage Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu-bar app that monitors MiniMax API usage quota with configurable display and warning notifications.

**Architecture:** MVVM with SwiftUI, single app target, LSUIElement mode. Services layer handles API/Keychain, ViewModels manage state, Views render UI.

**Tech Stack:** Swift, SwiftUI (macOS 14+), AppKit (menu bar integration), native URLSession, Keychain Services

---

## File Structure

```
MiniMaxUsageMonitor/
├── App/
│   ├── main.swift                    # Manual app entry point
│   ├── AppDelegate.swift             # App lifecycle, LSUIElement
│   └── StatusBarController.swift     # NSStatusItem management
├── Views/
│   ├── MenuView.swift                # Dropdown menu content
│   ├── SettingsView.swift            # Settings window SwiftUI view
│   └── WarningPanelView.swift       # Warning panel SwiftUI view
├── ViewModels/
│   └── UsageViewModel.swift         # State management, timer, threshold logic
├── Services/
│   ├── UsageService.swift            # API fetch, JSON parsing
│   └── KeychainService.swift        # Secure API key storage
├── Models/
│   └── UsageData.swift              # API response model
└── Resources/
    └── Assets.xcassets              # App icon assets

Makefile                              # SPM build targets
Package.swift                         # SPM manifest
```

---

## Task 1: Project Setup

**Files:**
- Create: `Package.swift`
- Create: `Makefile`
- Create: `MiniMaxUsageMonitor/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`

- [ ] **Step 1: Create SPM Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MiniMaxUsageMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "MiniMaxUsageMonitor",
            targets: ["MiniMaxUsageMonitor"],
            type: .application
        )
    ],
    targets: [
        .executableTarget(
            name: "MiniMaxUsageMonitor",
            dependencies: [],
            path: "MiniMaxUsageMonitor"
        )
    ]
)
```

- [ ] **Step 2: Create Makefile**

```makefile
.PHONY: build run install clean

BUILD_DIR = .build
PRODUCT = MiniMaxUsageMonitor.app

build:
	swift build -c release --product MiniMaxUsageMonitor

run: build
	.open $(BUILD_DIR)/release/$(PRODUCT)

install: build
	cp -R $(BUILD_DIR)/release/$(PRODUCT) /Applications/

clean:
	swift package reset
	rm -rf $(BUILD_DIR)
```

- [ ] **Step 3: Create Assets.xcassets structure**

Create `MiniMaxUsageMonitor/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:
```json
{
  "images" : [
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 4: Create Assets.xcassets Contents.json**

Create `MiniMaxUsageMonitor/Resources/Assets.xcassets/Contents.json`:
```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 5: Commit**

```bash
git add Package.swift Makefile MiniMaxUsageMonitor/Resources/
git commit -m "chore: add SPM project setup and Makefile

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 2: Models

**Files:**
- Create: `MiniMaxUsageMonitor/Models/UsageData.swift`

- [ ] **Step 1: Create UsageData model**

```swift
import Foundation

/// API response model for MiniMax usage data
/// Endpoint: GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains
struct UsageData: Codable {
    /// Remaining tokens/credits
    let remains: Int
    /// Total allocated amount (for percentage calculation)
    let total: Int
    /// Timestamp of the response
    let timestamp: Date

    /// Percentage remaining (0-100)
    var percentageRemaining: Double {
        guard total > 0 else { return 0 }
        return (Double(remains) / Double(total)) * 100
    }

    /// Formatted remaining display string
    func formattedRemaining(format: DisplayFormat) -> String {
        switch format {
        case .numberOnly:
            return "\(Int(percentageRemaining))%"
        case .numberWithUnit:
            return "\(Int(percentageRemaining))% remaining"
        case .leveled:
            if percentageRemaining > 50 {
                return "\(Int(percentageRemaining))%"
            } else {
                let days = estimateDaysRemaining()
                return "⚠️ \(Int(percentageRemaining))% (~\(days) days)"
            }
        }
    }

    /// Estimate days until quota exhaustion (simplified)
    private func estimateDaysRemaining() -> Int {
        // Placeholder calculation based on typical usage
        // Real implementation would track usage trend over time
        return max(1, Int(Double(remains) / Double(total) * 30))
    }
}

/// Menu bar display format options
enum DisplayFormat: Int, CaseIterable, Codable {
    case numberOnly = 0
    case numberWithUnit = 1
    case leveled = 2

    var description: String {
        switch self {
        case .numberOnly: return "Number only (e.g., 85%)"
        case .numberWithUnit: return "Number with unit (e.g., 85% remaining)"
        case .leveled: return "Leveled (detailed when low)"
        }
    }
}

/// Error types for usage fetching
enum UsageError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case apiError(String)
    case keychainError
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .invalidResponse: return "Invalid response from server"
        case .apiError(let message): return "API error: \(message)"
        case .keychainError: return "Keychain access error"
        case .notConfigured: return "API key not configured"
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add MiniMaxUsageMonitor/Models/UsageData.swift
git commit -m "feat: add UsageData model with DisplayFormat enum

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 3: Services - KeychainService

**Files:**
- Create: `MiniMaxUsageMonitor/Services/KeychainService.swift`

- [ ] **Step 1: Create KeychainService**

```swift
import Foundation
import Security

/// Service for secure API key storage using Keychain
final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.minimax.usagemonitor"
    private let account = "apiKey"

    private init() {}

    /// Save API key to Keychain
    func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        // Delete existing item first
        deleteAPIKey()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve API key from Keychain
    func getAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// Delete API key from Keychain
    @discardableResult
    func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if API key exists
    var hasAPIKey: Bool {
        return getAPIKey() != nil
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add MiniMaxUsageMonitor/Services/KeychainService.swift
git commit -m "feat: add KeychainService for secure API key storage

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 4: Services - UsageService

**Files:**
- Create: `MiniMaxUsageMonitor/Services/UsageService.swift`

- [ ] **Step 1: Create UsageService**

```swift
import Foundation

/// Service for fetching MiniMax API usage data
final class UsageService {
    static let shared = UsageService()

    private let apiURL = "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"

    private init() {}

    /// Fetch current usage data from MiniMax API
    func fetchUsage() async throws -> UsageData {
        guard let apiKey = KeychainService.shared.getAPIKey() else {
            throw UsageError.notConfigured
        }

        guard let url = URL(string: apiURL) else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw UsageError.apiError("Status \(httpResponse.statusCode): \(message)")
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UsageData.self, from: data)
        } catch {
            throw UsageError.invalidResponse
        }
    }

    /// Test API connection with given key
    func testConnection(apiKey: String) async throws -> Bool {
        guard let url = URL(string: apiURL) else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        return (200...299).contains(httpResponse.statusCode)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add MiniMaxUsageMonitor/Services/UsageService.swift
git commit -m "feat: add UsageService for API requests

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 5: ViewModels - UsageViewModel

**Files:**
- Create: `MiniMaxUsageMonitor/ViewModels/UsageViewModel.swift`

- [ ] **Step 1: Create UsageViewModel**

```swift
import Foundation
import AppKit
import Combine

/// Main view model managing usage state and refresh logic
@MainActor
final class UsageViewModel: ObservableObject {
    // MARK: - Published State

    @Published var usageData: UsageData?
    @Published var error: UsageError?
    @Published var isLoading: Bool = false
    @Published var lastRefreshTime: Date?
    @Published var showWarningPanel: Bool = false

    // MARK: - Settings

    @Published var refreshInterval: Int {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            restartTimer()
        }
    }

    @Published var displayFormat: DisplayFormat {
        didSet {
            UserDefaults.standard.set(displayFormat.rawValue, forKey: "displayFormat")
        }
    }

    @Published var warningThreshold: Double {
        didSet {
            UserDefaults.standard.set(warningThreshold, forKey: "warningThreshold")
        }
    }

    @Published var autoRefreshOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoRefreshOnLaunch, forKey: "autoRefreshOnLaunch")
        }
    }

    // MARK: - Computed Properties

    var statusBarText: String {
        guard let data = usageData else {
            return error != nil ? "—" : "..."
        }
        return data.formattedRemaining(format: displayFormat)
    }

    var hasAPIKey: Bool {
        KeychainService.shared.hasAPIKey
    }

    // MARK: - Private

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {
        self.refreshInterval = UserDefaults.standard.object(forKey: "refreshInterval") as? Int ?? 60
        self.displayFormat = DisplayFormat(rawValue: UserDefaults.standard.integer(forKey: "displayFormat")) ?? .leveled
        self.warningThreshold = UserDefaults.standard.double(forKey: "warningThreshold") > 0
            ? UserDefaults.standard.double(forKey: "warningThreshold")
            : 20.0
        self.autoRefreshOnLaunch = UserDefaults.standard.bool(forKey: "autoRefreshOnLaunch")

        setupWarningObserver()
    }

    // MARK: - Public Methods

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil

        do {
            let data = try await UsageService.shared.fetchUsage()
            usageData = data
            lastRefreshTime = Date()
            checkThreshold()
        } catch let usError as UsageError {
            error = usError
        } catch {
            self.error = .networkError(error)
        }

        isLoading = false
    }

    func startAutoRefresh() {
        guard autoRefreshOnLaunch || !hasAPIKey else { return }
        restartTimer()
        Task {
            await refresh()
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func saveAPIKey(_ key: String) -> Bool {
        let success = KeychainService.shared.saveAPIKey(key)
        if success {
            Task {
                await refresh()
            }
        }
        return success
    }

    func testAPIKey(_ key: String) async throws -> Bool {
        return try await UsageService.shared.testConnection(apiKey: key)
    }

    // MARK: - Private Methods

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    private func setupWarningObserver() {
        $usageData
            .compactMap { $0 }
            .sink { [weak self] data in
                self?.checkThreshold()
            }
            .store(in: &cancellables)
    }

    private func checkThreshold() {
        guard let data = usageData else {
            showWarningPanel = false
            return
        }

        showWarningPanel = data.percentageRemaining <= warningThreshold
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add MiniMaxUsageMonitor/ViewModels/UsageViewModel.swift
git commit -m "feat: add UsageViewModel with state management and timer

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 6: App Entry Point

**Files:**
- Create: `MiniMaxUsageMonitor/App/main.swift`
- Create: `MiniMaxUsageMonitor/App/AppDelegate.swift`

- [ ] **Step 1: Create main.swift (manual app entry, no @main)**

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 2: Create AppDelegate with LSUIElement**

```swift
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var warningPanelController: WarningPanelController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set LSUIElement to hide from Dock
        NSApp.setActivationPolicy(.accessory)

        // Initialize status bar
        statusBarController = StatusBarController()

        // Setup warning panel controller
        warningPanelController = WarningPanelController()

        // Observe view model for warning panel display
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showWarningIfNeeded),
            name: .showWarningPanel,
            object: nil
        )

        // Start auto-refresh
        statusBarController?.viewModel.startAutoRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.viewModel.stopAutoRefresh()
    }

    @objc private func showWarningIfNeeded(_ notification: Notification) {
        guard let usageData = notification.object as? UsageData else { return }
        warningPanelController?.show(usageData: usageData)
    }

    // MARK: - Window Controllers

    func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showWarningPanel = Notification.Name("showWarningPanel")
}
```

- [ ] **Step 3: Commit**

```bash
git add MiniMaxUsageMonitor/App/main.swift MiniMaxUsageMonitor/App/AppDelegate.swift
git commit -m "feat: add app entry point with LSUIElement mode

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 7: StatusBarController

**Files:**
- Create: `MiniMaxUsageMonitor/App/StatusBarController.swift`

- [ ] **Step 1: Create StatusBarController**

```swift
import AppKit
import SwiftUI

final class StatusBarController {
    let viewModel = UsageViewModel()
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var hostingView: NSHostingView<MenuView>?

    init() {
        setupStatusItem()
        setupMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = viewModel.statusBarText
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        // Observe status bar text changes
        viewModel.$statusBarText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.statusItem?.button?.title = text
            }
            .store(in: &cancellables)
    }

    private func setupMenu() {
        menu = NSMenu()

        let menuView = MenuView(viewModel: viewModel, onOpenSettings: { [weak self] in
            self?.openSettings()
        })

        hostingView = NSHostingView(rootView: menuView)
        hostingView?.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

        let menuItem = NSMenuItem()
        menuItem.view = hostingView!
        menu?.addItem(menuItem)

        statusItem?.menu = menu
    }

    private var cancellables = Set<AnyCancellable>()

    private func openSettings() {
        NSApp.delegate?.openSettings()
    }
}

import Combine
```

- [ ] **Step 2: Commit**

```bash
git add MiniMaxUsageMonitor/App/StatusBarController.swift
git commit -m "feat: add StatusBarController for menu bar integration

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 8: MenuView

**Files:**
- Create: `MiniMaxUsageMonitor/Views/MenuView.swift`

- [ ] **Step 1: Create MenuView**

```swift
import SwiftUI

struct MenuView: View {
    @ObservedObject var viewModel: UsageViewModel
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("MiniMax Usage")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowHeaderColor))

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 12) {
                // Status section
                if let data = viewModel.usageData {
                    StatusRow(title: "Remaining", value: "\(data.remains)")
                    StatusRow(title: "Percentage", value: "\(Int(data.percentageRemaining))%")
                    StatusRow(title: "Total", value: "\(data.total)")
                } else if let error = viewModel.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Loading...")
                        .foregroundColor(.secondary)
                }

                Divider()

                // Last refresh
                if let lastRefresh = viewModel.lastRefreshTime {
                    HStack {
                        Text("Last refresh:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(lastRefresh, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Refresh button
                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    HStack {
                        if viewModel.isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.isLoading)

                Divider()

                // Settings button
                Button(action: onOpenSettings) {
                    HStack {
                        Image(systemName: "gear")
                        Text("Settings")
                    }
                    .frame(maxWidth: .infinity)
                }

                Divider()

                // Quit button
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack {
                        Image(systemName: "power")
                        Text("Quit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .foregroundColor(.red)
            }
            .padding(16)
        }
        .frame(width: 300)
        .fixedSize()
    }
}

struct StatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add MiniMaxUsageMonitor/Views/MenuView.swift
git commit -m "feat: add MenuView for dropdown menu content

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 9: SettingsView

**Files:**
- Create: `MiniMaxUsageMonitor/Views/SettingsView.swift`
- Create: `MiniMaxUsageMonitor/App/SettingsWindowController.swift`

- [ ] **Step 1: Create SettingsView**

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var apiKey: String = ""
    @State private var testResult: String?
    @State private var isTesting: Bool = false
    @State private var isSaving: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // API Settings Group
            GroupBox(label: Text("API Settings").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Test Connection") {
                            Task {
                                await testConnection()
                            }
                        }
                        .disabled(apiKey.isEmpty || isTesting)

                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                        }

                        if let result = testResult {
                            Image(systemName: result == "Success" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result == "Success" ? .green : .red)
                            Text(result)
                                .font(.caption)
                                .foregroundColor(result == "Success" ? .green : .red)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            // Refresh Settings Group
            GroupBox(label: Text("Refresh Settings").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Interval:")
                        TextField("seconds", value: $viewModel.refreshInterval, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("seconds")
                    }

                    Toggle("Auto-refresh on launch", isOn: $viewModel.autoRefreshOnLaunch)
                }
                .padding(.vertical, 8)
            }

            // Display Settings Group
            GroupBox(label: Text("Display Settings").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Menu bar format:")
                    Picker("Format", selection: $viewModel.displayFormat) {
                        ForEach(DisplayFormat.allCases, id: \.self) { format in
                            Text(format.description).tag(format)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    HStack {
                        Text("Warning threshold:")
                        TextField("percentage", value: $viewModel.warningThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("%")
                    }
                }
                .padding(.vertical, 8)
            }

            // Save button
            HStack {
                Spacer()
                Button("Save") {
                    saveSettings()
                }
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
        .onAppear {
            loadCurrentSettings()
        }
    }

    private func loadCurrentSettings() {
        if let key = KeychainService.shared.getAPIKey() {
            apiKey = key
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil

        do {
            let success = try await viewModel.testAPIKey(apiKey)
            testResult = success ? "Success" : "Failed"
        } catch {
            testResult = "Error"
        }

        isTesting = false
    }

    private func saveSettings() {
        isSaving = true

        if !apiKey.isEmpty {
            _ = viewModel.saveAPIKey(apiKey)
        }

        isSaving = false
    }
}
```

- [ ] **Step 2: Create SettingsWindowController**

```swift
import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let viewModel = UsageViewModel()
        let settingsView = SettingsView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "MiniMax Usage Monitor - Settings"
        window.setContentSize(NSSize(width: 480, height: 400))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()

        self.init(window: window)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add MiniMaxUsageMonitor/Views/SettingsView.swift MiniMaxUsageMonitor/App/SettingsWindowController.swift
git commit -m "feat: add SettingsView and SettingsWindowController

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 10: WarningPanel

**Files:**
- Create: `MiniMaxUsageMonitor/Views/WarningPanelView.swift`
- Create: `MiniMaxUsageMonitor/App/WarningPanelController.swift`

- [ ] **Step 1: Create WarningPanelView**

```swift
import SwiftUI

struct WarningPanelView: View {
    let usageData: UsageData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                Text("Low Quota Warning")
                    .font(.headline)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Remaining:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(usageData.remains) (\(Int(usageData.percentageRemaining))%)")
                        .fontWeight(.bold)
                }

                HStack {
                    Text("Time:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(usageData.timestamp, style: .time)
                }

                HStack {
                    Text("Est. exhaustion:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(estimatedExhaustion)
                        .fontWeight(.medium)
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var estimatedExhaustion: String {
        let days = max(1, Int(Double(usageData.remains) / Double(usageData.total) * 30))
        return "~ \(days) day\(days == 1 ? "" : "s")"
    }
}
```

- [ ] **Step 2: Create WarningPanelController**

```swift
import AppKit
import SwiftUI

final class WarningPanelController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<WarningPanelView>?

    func show(usageData: UsageData) {
        if panel == nil {
            createPanel()
        }

        hostingView?.rootView = WarningPanelView(usageData: usageData)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = true

        // Position at bottom-right
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelX = screenFrame.maxX - 300
            let panelY = screenFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        }

        let hostingView = NSHostingView(rootView: WarningPanelView(usageData: UsageData(remains: 0, total: 100, timestamp: Date())))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add MiniMaxUsageMonitor/Views/WarningPanelView.swift MiniMaxUsageMonitor/App/WarningPanelController.swift
git commit -m "feat: add WarningPanelView and WarningPanelController

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Task 11: Build Verification

- [ ] **Step 1: Attempt to build the project**

Run: `swift build -c release`
Expected: Successful build without errors

- [ ] **Step 2: Fix any compilation errors if they occur**

Document any issues and fixes applied.

- [ ] **Step 3: Commit any fixes**

```bash
git add .
git commit -m "fix: resolve build issues

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## Implementation Complete

Plan saved to `docs/superpowers/plans/YYYY-MM-DD-minimax-usage-monitor-implementation.md`

Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
