import AppKit
import SwiftUI
import XCTest
@testable import AIQuotaBar

@MainActor
final class SettingsWindowSmokeTests: XCTestCase {
    func testSettingsWindowCanBeCreatedAndShown() throws {
        let suiteName = "SettingsWindowSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let service = MobileDashboardService(
            defaults: defaults,
            snapshotProvider: { _, _, _, _ in
                fatalError(
                    "A disabled dashboard must not request a snapshot.")
            },
            onViewerActivityChanged: { _ in },
            refreshRoute: {},
            testRoutes: {})
        let controller = SettingsWindowController(
            viewModel: UsageViewModel(),
            mobileDashboardService: service)
        controller.showWindow(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(controller.window?.isVisible == true)
        controller.close()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMobileDashboardPaneRendersAvailableAndOrphanedModels()
        throws
    {
        let suiteName = "SettingsWindowSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let viewModel = UsageViewModel()
        let available = makeModel(
            account: "Full.Name@example.com",
            name: "5h")
        viewModel.providerUsageData = [
            .codex: UsageData(
                provider: .codex,
                remains: 1,
                total: 1,
                timestamp: Date(),
                models: [available],
                subscribeTitle: nil,
                subscribeEndTime: nil),
        ]
        defaults.set(true, forKey: "mobileDashboardEnabled")
        let service = makeService(defaults: defaults)
        let orphan = MobileDashboardModelSelectionKey(
            providerRaw: UsageProvider.codex.rawValue,
            normalizedAccount: "old@example.com",
            normalizedModel: "weekly")
        XCTAssertTrue(service.setSelectedModelKeys([orphan]))

        let hostingView = NSHostingView(
            rootView: MobileDashboardPane(
                viewModel: viewModel,
                service: service))
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 744,
                height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFront(nil)
        RunLoop.main.run(
            until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(service.selectedModelKeys, [orphan])
        XCTAssertGreaterThan(hostingView.frame.height, 0)
        window.close()
    }

    func testMobileDashboardSelectionBehaviorProtectsOneAndCapsTwo()
        throws
    {
        let suiteName = "SettingsWindowSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let service = makeService(defaults: defaults)
        let models = [
            makeModel(account: "one@example.com", name: "5h"),
            makeModel(account: "one@example.com", name: "Weekly"),
            makeModel(account: "two@example.com", name: "5h"),
        ]

        service.initializeModelSelectionIfNeeded(candidates: models)
        XCTAssertEqual(service.selectedModelKeys.count, 2)
        XCTAssertFalse(
            service.toggleModelSelection(
                models[2].mobileDashboardSelectionKey))
        XCTAssertTrue(
            service.toggleModelSelection(
                models[0].mobileDashboardSelectionKey))
        XCTAssertEqual(service.selectedModelKeys.count, 1)
        XCTAssertFalse(
            service.toggleModelSelection(
                models[1].mobileDashboardSelectionKey))
    }

    func testExperimentalWakeMediaDefaultsOffAndPersistsInIsolatedSuite()
        throws
    {
        let suiteName = "SettingsWindowSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let service = makeService(defaults: defaults)
        XCTAssertFalse(service.experimentalWakeMediaEnabled)

        service.experimentalWakeMediaEnabled = true

        let restored = makeService(defaults: defaults)
        XCTAssertTrue(restored.experimentalWakeMediaEnabled)
        XCTAssertTrue(
            defaults.bool(
                forKey:
                    "mobileDashboardExperimentalWakeMediaEnabled"))
    }

    func testActivityBackgroundEffectDefaultsPersistsAndRejectsInvalidValue()
        throws
    {
        let suiteName = "SettingsWindowSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(
            makeService(defaults: defaults).activityBackgroundEffect,
            .grainyDigitalRain)

        let service = makeService(defaults: defaults)
        service.activityBackgroundEffect = .taskTelemetryMarquee
        XCTAssertEqual(
            makeService(defaults: defaults).activityBackgroundEffect,
            .taskTelemetryMarquee)
        XCTAssertEqual(
            defaults.string(
                forKey: "mobileDashboardActivityBackgroundEffect"),
            MobileDashboardActivityBackgroundEffect
                .taskTelemetryMarquee.rawValue)

        defaults.set(
            "hostile-unknown-effect",
            forKey: "mobileDashboardActivityBackgroundEffect")
        XCTAssertEqual(
            makeService(defaults: defaults).activityBackgroundEffect,
            .grainyDigitalRain)
    }

    func testTaskTelemetryFieldsDefaultToAllAndPersistIndividualChoices()
        throws
    {
        let suiteName = "SettingsWindowSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(
            makeService(defaults: defaults).taskTelemetryFields,
            Set(MobileDashboardTaskTelemetryField.allCases))

        let service = makeService(defaults: defaults)
        service.setTaskTelemetryField(.model, enabled: false)
        service.setTaskTelemetryField(.progress, enabled: false)
        let restored = makeService(defaults: defaults)
        XCTAssertFalse(restored.taskTelemetryFields.contains(.model))
        XCTAssertFalse(restored.taskTelemetryFields.contains(.progress))
        XCTAssertTrue(restored.taskTelemetryFields.contains(.title))

        defaults.set(
            ["title", "hostile-unknown-field"],
            forKey: "mobileDashboardTaskTelemetryFields")
        XCTAssertEqual(
            makeService(defaults: defaults).taskTelemetryFields,
            [.title])
    }

    func testMobileDashboardColorSchemeDefaultsPersistsAndRejectsInvalidValue()
        throws
    {
        let suiteName = "SettingsWindowSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(
            makeService(defaults: defaults).colorScheme,
            .automatic)
        XCTAssertNil(
            defaults.object(forKey: "mobileDashboardColorScheme"),
            "Reading the default must not persist a user selection.")

        let service = makeService(defaults: defaults)
        service.colorScheme = .light
        XCTAssertEqual(makeService(defaults: defaults).colorScheme, .light)
        XCTAssertEqual(
            defaults.string(forKey: "mobileDashboardColorScheme"),
            MobileDashboardColorScheme.light.rawValue)

        defaults.set(
            "hostile-unknown-color-scheme",
            forKey: "mobileDashboardColorScheme")
        XCTAssertEqual(
            makeService(defaults: defaults).colorScheme,
            .automatic)
    }

    private func makeService(
        defaults: UserDefaults
    ) -> MobileDashboardService {
        MobileDashboardService(
            defaults: defaults,
            snapshotProvider: { _, _, _, _ in
                fatalError(
                    "A disabled dashboard must not request a snapshot.")
            },
            onViewerActivityChanged: { _ in },
            refreshRoute: {},
            testRoutes: {})
    }

    private func makeModel(
        account: String,
        name: String
    ) -> ModelUsageData {
        ModelUsageData(
            provider: .codex,
            accountName: account,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: 50,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 3_600_000,
            startTime: Date().addingTimeInterval(-3_600),
            endTime: Date().addingTimeInterval(3_600),
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: 50,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil)
    }
}
