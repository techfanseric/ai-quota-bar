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
