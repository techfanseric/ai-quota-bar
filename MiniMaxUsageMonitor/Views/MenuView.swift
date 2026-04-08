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
