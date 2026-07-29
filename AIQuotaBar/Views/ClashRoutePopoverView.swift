import AppKit
import SwiftUI

struct ClashRoutePopoverView: View {
    @Bindable var viewModel: ClashRouteViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            footer
        }
        .frame(width: 376, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
    }

    private var language: AppLanguage {
        viewModel.language
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(language.clashRoutesTitle())
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                if viewModel.isSpeedTesting {
                    ProgressView()
                        .controlSize(.small)
                } else if case .ready = viewModel.phase {
                    Button {
                        Task {
                            await viewModel.testRoutes()
                        }
                    } label: {
                        Label(
                            language.clashTestAgain(),
                            systemImage: "gauge.with.dots.needle.50percent")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)

                    TextField(
                        language.clashSearchPlaceholder(),
                        text: $viewModel.filterQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($isSearchFocused)

                    if !viewModel.filterQuery.isEmpty {
                        Button {
                            viewModel.filterQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Clear"))
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.055)))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            viewModel.filterErrorMessage == nil
                                ? Color.primary.opacity(0.09)
                                : Color.red.opacity(0.65),
                            lineWidth: 1)
                }

                Toggle(
                    language.clashRegexToggle(),
                    isOn: $viewModel.usesRegularExpression)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .font(.system(size: 10, weight: .semibold))
                    .help(language.clashRegexHelp())
            }

            if let filterError = viewModel.filterErrorMessage {
                Label {
                    Text(language.clashRegexError(filterError))
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    language.clashAutoSelectBest(),
                    isOn: $viewModel.autoRecoveryEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11, weight: .medium))

                if viewModel.autoRecoveryEnabled,
                   !viewModel.hasActiveFilter {
                    Text(language.clashAutoSelectNeedsFilter())
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loading:
            centeredState(
                icon: "point.3.connected.trianglepath.dotted",
                title: language.clashLoading(),
                message: nil,
                showsProgress: true)

        case let .unavailable(message):
            centeredState(
                icon: "network.slash",
                title: language.clashUnavailableTitle(),
                message: "\(message)\n\(language.clashUnavailableHelp())",
                actionTitle: language.clashRetry(),
                action: {
                    Task {
                        await viewModel.prepareForDisplay(automaticallyTest: true)
                    }
                })

        case .ready:
            readyContent
        }
    }

    private var readyContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(viewModel.groupName ?? "—")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Text(
                    language.clashRouteCount(
                        visible: viewModel.filteredRoutes.count,
                        total: viewModel.routes.count))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if viewModel.filteredRoutes.isEmpty {
                centeredState(
                    icon: "line.3.horizontal.decrease.circle",
                    title: language.clashNoMatches(),
                    message: language.clashNoMatchesHelp())
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.filteredRoutes) { route in
                            routeRow(route)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private func routeRow(_ route: ClashRoute) -> some View {
        Button {
            Task {
                _ = await viewModel.selectRoute(route.name)
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(
                            route.isSelected
                                ? Color.accentColor.opacity(0.14)
                                : Color.primary.opacity(0.045))
                        .frame(width: 22, height: 22)

                    Image(systemName: route.isSelected ? "checkmark" : "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(
                            route.isSelected
                                ? Color.accentColor
                                : Color.secondary.opacity(0.7))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(route.name)
                        .font(.system(size: 11, weight: route.isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        Text(route.type)
                        if route.isSelected {
                            Text("·")
                            Text(language.clashCurrentRoute())
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                Text(delayText(for: route))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(delayColor(for: route))
            }
            .padding(.horizontal, 7)
            .frame(height: 40)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        route.isSelected
                            ? Color.accentColor.opacity(0.065)
                            : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSwitching)
        .accessibilityLabel(
            Text("\(route.name), \(delayText(for: route))"))
    }

    @ViewBuilder
    private func centeredState(
        icon: String,
        title: String,
        message: String?,
        showsProgress: Bool = false,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private var footer: some View {
        if let statusMessage = viewModel.statusMessage {
            Divider()
            HStack(spacing: 7) {
                if viewModel.isSpeedTesting || viewModel.isSwitching {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 5, height: 5)
                }

                Text(statusMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if let clientName = viewModel.clientName {
                    Text(clientName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
    }

    private func delayText(for route: ClashRoute) -> String {
        guard let delay = route.delay else { return "—" }
        guard delay > 0 else { return language.clashDelayUnavailable() }
        return "\(delay) ms"
    }

    private func delayColor(for route: ClashRoute) -> Color {
        guard let delay = route.delay, delay > 0 else {
            return .secondary.opacity(0.65)
        }
        switch delay {
        case ..<120:
            return .green
        case ..<300:
            return .orange
        default:
            return .red
        }
    }
}
