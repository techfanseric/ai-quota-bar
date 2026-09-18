import AppKit
import SwiftUI
import XCTest
import CodexLocalUsageCore
@testable import AIQuotaBar

@MainActor final class TeamSettingsRenderingTests: XCTestCase {
    func testTeamEntryAndConnectedStatesRenderInBothLanguages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "TeamSettingsRenderingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = CodexLocalUsageModel(defaults: defaults, databaseURL: directory.appendingPathComponent("usage.sqlite"))
        let vm = UsageViewModel(providerPresence: { _ in false })
        let previousLanguage = vm.appLanguage
        defer { vm.appLanguage = previousLanguage }
        for language in AppLanguage.allCases {
            vm.appLanguage = language
            for connected in [false, true] {
                if connected {
                    let identity = try JSONDecoder().decode(UsageIdentity.self, from: Data("{\"team_id\":\"fixture-team\",\"team_name\":\"Design Team · 设计团队\",\"member_id\":\"fixture\",\"member_name\":\"Alice\",\"device_id\":\"fixture-device\"}".utf8))
                    local.connection = LocalUsageConnection(endpoint: "https://fixture.invalid", identity: identity, since: Date())
                } else { local.connection = nil }
                let root = ScrollView { TeamSettingsSection(viewModel: vm, model: local).padding(20) }.frame(width: 720, height: 570).background(Color.white).environment(\.colorScheme, .light)
                let view = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 570), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = view; window.orderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1)); view.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(view.fittingSize.height, 0)
                if let output = ProcessInfo.processInfo.environment["USAGE_SCREENSHOT_DIR"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("team-\(connected ? "connected" : "entry")-\(language.rawValue).png"))
                }
                window.close()
            }
        }
    }
}
