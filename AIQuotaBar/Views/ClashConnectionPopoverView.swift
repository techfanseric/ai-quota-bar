import SwiftUI

struct ClashConnectionPopoverView: View {
    @Bindable var viewModel: ClashConnectionViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var language: AppLanguage {
        viewModel.language
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(language.clashConnectionsTitle())
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(viewModel.isLive ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(
                        viewModel.isLive
                            ? language.clashConnectionsLive()
                            : language.clashConnectionsBackground())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(language.clashConnectionsFixedFilter())
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loading:
            centeredState(
                icon: "point.3.connected.trianglepath.dotted",
                title: language.clashConnectionsLoading(),
                message: nil,
                showsProgress: true)

        case let .unavailable(message):
            centeredState(
                icon: "network.slash",
                title: language.clashUnavailableTitle(),
                message: "\(message)\n\(language.clashUnavailableHelp())",
                actionTitle: language.clashRetry()) {
                    viewModel.retry()
                }

        case .ready:
            readyContent
        }
    }

    private var readyContent: some View {
        VStack(spacing: 0) {
            metrics
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(language.clashConnectionsActivityTitle())
                        .font(.system(size: 10, weight: .semibold))

                    Spacer()

                    HStack(spacing: 4) {
                        Text(language.clashConnectionAgeNew())
                        LinearGradient(
                            colors: [
                                ClashConnectionActivityChart
                                    .newConnectionColor,
                                ClashConnectionActivityChart
                                    .oldConnectionColor,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing)
                            .frame(width: 38, height: 4)
                            .clipShape(Capsule())
                        Text(language.clashConnectionAgeLong())
                    }
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                ClashConnectionActivityChart(
                    samples: viewModel.history,
                    relativeTo: viewModel.observedAt ?? Date())
                    .frame(height: 78)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 7)

            Divider()

            HStack {
                Text(language.clashActiveConnections())
                    .font(.system(size: 10, weight: .semibold))

                Spacer()

                Text(
                    language.clashActiveConnectionCount(
                        viewModel.activeConnectionCount))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider()

            if viewModel.connections.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "network")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(language.clashNoActiveConnections())
                        .font(.system(size: 11, weight: .medium))
                    Text(language.clashNoActiveConnectionsHelp())
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.connections) { connection in
                            connectionRow(connection)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                }
                .frame(
                    minHeight:
                        ClashPopoverLayout.connectionListMinimumHeight)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 7) {
            metric(
                title: language.clashDownloadSpeed(),
                value: ClashConnectionFormat.rate(
                    viewModel.downloadSpeed),
                systemImage: "arrow.down",
                color: .blue)
            metric(
                title: language.clashUploadSpeed(),
                value: ClashConnectionFormat.rate(
                    viewModel.uploadSpeed),
                systemImage: "arrow.up",
                color: .purple)
            metric(
                title: language.clashConnectionCount(),
                value: String(viewModel.activeConnectionCount),
                systemImage: "point.3.connected.trianglepath.dotted",
                color: .orange)
        }
    }

    private func metric(
        title: String,
        value: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 1)
        }
    }

    private func connectionRow(
        _ connection: ClashActiveConnection
    ) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(
                    ClashConnectionActivityChart.color(
                        forAge: connection.duration).opacity(0.16))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: "network")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(
                            ClashConnectionActivityChart.color(
                                forAge: connection.duration))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.host)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail = ClashConnectionFormat.detail(
                    network: connection.network,
                    chain: connection.primaryChain
                ) {
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ClashConnectionFormat.duration(connection.duration))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        ClashConnectionActivityChart.color(
                            forAge: connection.duration))
                    .monospacedDigit()

                Text(
                    "↓\(ClashConnectionFormat.rate(connection.downloadSpeed))  "
                        + "↑\(ClashConnectionFormat.rate(connection.uploadSpeed))")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 40)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))

            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 24)
            }

            if let actionTitle,
               let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(
                    viewModel.phase == .ready
                        ? Color.green.opacity(0.65)
                        : Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)

            Text(language.clashConnectionsReadOnly())
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Spacer()

            Text(viewModel.clientName ?? "Clash / Mihomo")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 29)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct ClashConnectionActivityChart: View {
    static let newConnectionColor = Color(
        red: 0.20,
        green: 0.78,
        blue: 0.35)
    static let oldConnectionColor = Color(
        red: 1.00,
        green: 0.49,
        blue: 0.05)

    let samples: [ClashConnectionHistorySample]
    let relativeTo: Date

    var body: some View {
        Canvas { context, size in
            let leftInset: CGFloat = 25
            let bottomInset: CGFloat = 17
            let topInset: CGFloat = 5
            let plot = CGRect(
                x: leftInset,
                y: topInset,
                width: max(0, size.width - leftInset - 2),
                height: max(0, size.height - topInset - bottomInset))
            guard plot.width > 0, plot.height > 0 else { return }

            let buckets = minuteBuckets()
            let maximumCount = max(
                1,
                buckets.compactMap { $0?.connectionCount }.max() ?? 0)
            drawGrid(
                context: &context,
                plot: plot,
                maximumCount: maximumCount)
            drawBars(
                context: &context,
                plot: plot,
                buckets: buckets,
                maximumCount: maximumCount)
            drawXAxis(context: &context, plot: plot)
        }
        .accessibilityLabel(
            Text("OpenAI active connection history"))
    }

    static func color(forAge age: TimeInterval) -> Color {
        let progress = ClashConnectionAgeScale.progress(for: age)
        let start = (red: 0.20, green: 0.78, blue: 0.35)
        let end = (red: 1.00, green: 0.49, blue: 0.05)
        return Color(
            red: start.red + (end.red - start.red) * progress,
            green: start.green + (end.green - start.green) * progress,
            blue: start.blue + (end.blue - start.blue) * progress)
    }

    private func minuteBuckets()
        -> [ClashConnectionHistorySample?]
    {
        let currentMinute = ClashConnectionHistory.minuteStart(
            for: relativeTo)
        let samplesByMinute = Dictionary(
            uniqueKeysWithValues: samples.map {
                (
                    Int64($0.timestamp.timeIntervalSince1970),
                    $0
                )
            })

        return (0 ..< ClashConnectionHistory.retainedSampleCount)
            .map { index in
                let offset = ClashConnectionHistory.retainedSampleCount
                    - 1 - index
                let timestamp = currentMinute.addingTimeInterval(
                    -Double(offset)
                        * ClashConnectionHistory.sampleInterval)
                return samplesByMinute[
                    Int64(timestamp.timeIntervalSince1970)]
            }
    }

    private func drawGrid(
        context: inout GraphicsContext,
        plot: CGRect,
        maximumCount: Int
    ) {
        let middle = Int(ceil(Double(maximumCount) / 2))
        let ticks = Array(Set([0, middle, maximumCount])).sorted()

        for tick in ticks {
            let fraction = CGFloat(tick) / CGFloat(maximumCount)
            let y = plot.maxY - plot.height * fraction
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(
                path,
                with: .color(Color.primary.opacity(0.075)),
                style: StrokeStyle(
                    lineWidth: 0.5,
                    dash: tick == 0 ? [] : [2, 2]))

            let label = context.resolve(
                Text(String(tick))
                    .font(.system(size: 7))
                    .foregroundStyle(Color.secondary))
            context.draw(
                label,
                at: CGPoint(x: plot.minX - 4, y: y),
                anchor: .trailing)
        }
    }

    private func drawBars(
        context: inout GraphicsContext,
        plot: CGRect,
        buckets: [ClashConnectionHistorySample?],
        maximumCount: Int
    ) {
        let step = plot.width / CGFloat(buckets.count)
        let barWidth = max(1, step - min(1.5, step * 0.28))
        let unitHeight = plot.height / CGFloat(maximumCount)

        for (index, sample) in buckets.enumerated() {
            guard let sample else { continue }
            let x = plot.minX + CGFloat(index) * step
                + (step - barWidth) / 2
            let ages = sample.connectionAges.sorted(by: >)

            for (unitIndex, age) in ages.enumerated() {
                let gap = min(0.6, unitHeight * 0.16)
                let rect = CGRect(
                    x: x,
                    y: plot.maxY
                        - CGFloat(unitIndex + 1) * unitHeight
                        + gap / 2,
                    width: barWidth,
                    height: max(0.5, unitHeight - gap))
                context.fill(
                    Path(
                        roundedRect: rect,
                        cornerRadius: min(1.2, rect.height / 3)),
                    with: .color(Self.color(forAge: age)))
            }
        }
    }

    private func drawXAxis(
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        let labels: [(String, CGFloat, UnitPoint)] = [
            ("−60m", plot.minX, .topLeading),
            ("−30m", plot.midX, .top),
            ("now", plot.maxX, .topTrailing),
        ]

        for (text, x, anchor) in labels {
            let label = context.resolve(
                Text(text)
                    .font(.system(size: 7))
                    .foregroundStyle(Color.secondary))
            context.draw(
                label,
                at: CGPoint(x: x, y: plot.maxY + 4),
                anchor: anchor)
        }
    }
}

enum ClashConnectionFormat {
    static func detail(
        network: String?,
        chain: String?
    ) -> String? {
        let parts: [String] = [
            network?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
            chain?
                .trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        .compactMap { part -> String? in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var scaled = value
        var unitIndex = 0
        while scaled >= 1_000, unitIndex < units.count - 1 {
            scaled /= 1_000
            unitIndex += 1
        }

        let format: String
        if scaled >= 100 || unitIndex == 0 {
            format = "%.0f"
        } else if scaled >= 10 {
            format = "%.1f"
        } else {
            format = "%.2f"
        }
        return String(format: format, scaled) + " " + units[unitIndex]
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m \(seconds % 60)s"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h \(minutes % 60)m"
        }

        let days = hours / 24
        return "\(days)d \(hours % 24)h"
    }
}
