import Foundation
import XCTest
@testable import AIQuotaBar

final class MobileDashboardFrontendTests: XCTestCase {
    func testMobileInstallIdentityAndCompactDashboardContract()
        throws
    {
        let manifest = try resourceJSON(
            name: "manifest",
            extension: "webmanifest")
        XCTAssertEqual(manifest["name"] as? String, "AI Quota")
        XCTAssertEqual(manifest["short_name"] as? String, "AI Quota")
        XCTAssertEqual(manifest["theme_color"] as? String, "#000000")
        XCTAssertEqual(
            manifest["background_color"] as? String,
            "#000000")

        let html = try resourceText(
            name: "index",
            extension: "html")
        XCTAssertTrue(html.contains("<title>AI Quota</title>"))
        XCTAssertTrue(
            html.contains(
                #"<html lang="en" data-color-scheme="auto">"#))
        XCTAssertTrue(
            html.contains(
                #"name="apple-mobile-web-app-title" content="AI Quota""#))
        XCTAssertTrue(html.contains(#"id="install-copy""#))
        XCTAssertTrue(html.contains(#"class="task-energy-field""#))
        XCTAssertTrue(
            html.contains(
                #"class="matrix-rain-canvas" id="matrix-rain-canvas""#))
        XCTAssertTrue(html.contains(#"class="matrix-idle-grain""#))
        XCTAssertEqual(occurrences(of: "<canvas", in: html), 1)
        XCTAssertEqual(
            occurrences(of: #"class="task-wave""#, in: html),
            5)
        XCTAssertFalse(html.contains("matrix-ripple"))
        XCTAssertFalse(html.contains("matrix-scan"))
        XCTAssertFalse(html.contains("wake-media-button"))
        XCTAssertFalse(html.contains("wake-media-status"))
        XCTAssertFalse(html.contains("Enable while working"))
        XCTAssertFalse(html.contains(#"id="task-state-symbol""#))
        XCTAssertTrue(html.contains(#"class="ticker-window""#))
        XCTAssertFalse(html.contains("section-index"))
    }

    func testOLEDAndSchemaV3FrontendHooksRemainPresent() throws {
        let css = try resourceText(name: "app", extension: "css")
        XCTAssertTrue(css.contains("@media (orientation: landscape)"))
        XCTAssertTrue(css.contains("env(safe-area-inset-left)"))
        XCTAssertTrue(css.contains("env(safe-area-inset-right)"))
        XCTAssertTrue(
            css.contains("@media (prefers-reduced-motion: reduce)"))
        XCTAssertTrue(css.contains(".matrix-rain-canvas"))
        XCTAssertTrue(
            css.contains(#":root[data-color-scheme="light"]"#))
        XCTAssertTrue(
            css.contains(#"@media (prefers-color-scheme: light)"#))
        XCTAssertTrue(
            css.contains(#":root[data-color-scheme="auto"]"#))
        XCTAssertTrue(css.contains("--page-background: #f6f7f4"))
        XCTAssertTrue(css.contains(".matrix-idle-grain"))
        XCTAssertTrue(
            css.contains(
                #"data-activity-effect="grainyDigitalRain""#))
        XCTAssertTrue(css.contains(#"data-activity-effect="dotWaves""#))
        XCTAssertTrue(css.contains(".task-wave.is-powered"))
        XCTAssertTrue(css.contains("@keyframes task-wave-travel"))
        XCTAssertTrue(css.contains("@keyframes matrix-idle-breathe"))
        XCTAssertTrue(css.contains("mask-image: radial-gradient"))
        XCTAssertTrue(css.contains("background: #000000"))
        XCTAssertTrue(css.contains("rgba(194, 202, 194, 0.16)"))
        XCTAssertTrue(css.contains("rgba(112, 201, 130, 0.28)"))
        XCTAssertTrue(css.contains("image-rendering: pixelated"))
        XCTAssertTrue(css.contains(".quota-quote-strip"))
        XCTAssertTrue(css.contains(".quota-model-card.has-cycles"))
        XCTAssertTrue(css.contains(".quota-cycle-bars"))
        XCTAssertTrue(css.contains("flex: 0 1 auto"))
        XCTAssertTrue(css.contains("width: 100%"))
        XCTAssertTrue(css.contains("max-width: none"))
        XCTAssertFalse(css.contains("width: min(100%, 88rem)"))
        XCTAssertTrue(
            css.contains(
                "grid-template-rows: repeat(3, minmax(0, 1fr)) 2.142857rem"))
        XCTAssertTrue(
            css.contains(
                "grid-template-rows: auto minmax(0, 1fr)"))
        XCTAssertTrue(
            css.contains(
                "grid-template-rows: auto minmax(0, 1fr) auto"))
        XCTAssertFalse(css.contains("background-clip: text"))
        XCTAssertFalse(css.contains("-webkit-background-clip: text"))
        XCTAssertFalse(css.contains("box-shadow:"))
        XCTAssertFalse(css.contains("filter:"))
        XCTAssertTrue(
            css.contains("animation: none !important"),
            "Reduce Motion must stop the task waves.")

        let script = try resourceText(name: "app", extension: "js")
        XCTAssertTrue(script.contains("snapshot?.menuBar"))
        XCTAssertTrue(script.contains("menuBar.ringPercent"))
        XCTAssertTrue(script.contains("menuBar.paceDeltaPercent"))
        XCTAssertTrue(script.contains("protection?.hasActiveTasks"))
        XCTAssertTrue(script.contains("snapshot.activitySummary"))
        XCTAssertTrue(script.contains("activityBackgroundEffect"))
        XCTAssertTrue(script.contains("COLOR_SCHEMES"))
        XCTAssertTrue(script.contains("applyColorScheme"))
        XCTAssertTrue(script.contains("resolveColorScheme"))
        XCTAssertTrue(script.contains("systemColorScheme.addEventListener"))
        XCTAssertTrue(script.contains("refreshThemeDependentVisuals"))
        XCTAssertTrue(script.contains(#"cssToken("--chart-axis""#))
        XCTAssertTrue(script.contains("taskRainProfile"))
        XCTAssertTrue(script.contains("framesPerSecond: 5"))
        XCTAssertTrue(script.contains("framesPerSecond: 7"))
        XCTAssertTrue(script.contains("model.displayOrder"))
        XCTAssertTrue(script.contains("model.rendersAreaChart === true"))
        XCTAssertTrue(script.contains(#""quota-primary""#))
        XCTAssertTrue(script.contains("renderQuotaQuote"))
        XCTAssertTrue(script.contains("renderQuotaCycles"))
        XCTAssertTrue(script.contains("cycleLeftPercent"))
        XCTAssertTrue(script.contains("connectionMapData"))
        XCTAssertTrue(script.contains("ensureConnectionsView"))
        XCTAssertTrue(script.contains("drawActiveLinkMap"))
        XCTAssertTrue(script.contains("canvas.getContext(\"2d\")"))
        XCTAssertFalse(script.contains("fitActiveLinkMap"))
        XCTAssertFalse(script.contains("className = \"link-dot\""))
        XCTAssertFalse(script.contains("wakeMediaButton"))
        XCTAssertFalse(script.contains("authorizeWorkingWake"))
        XCTAssertTrue(script.contains("slice(-60)"))
        XCTAssertTrue(script.contains("bucket.connectionAges"))
        XCTAssertTrue(script.contains("bucket.oldestConnectionAge"))
        XCTAssertTrue(script.contains("CONTENT_ROTATE_MS"))
        XCTAssertTrue(script.contains("PIXEL_SHIFT_MS"))
        XCTAssertTrue(script.contains("is-state-boosted"))
        XCTAssertTrue(script.contains(#"querySelectorAll(".task-wave")"#))
        XCTAssertTrue(
            script.contains(
                "Math.min(5, Math.max(0, Math.floor(safeNumber(tasks))))"))
    }

    private func resourceText(
        name: String,
        extension fileExtension: String
    ) throws -> String {
        let url = try XCTUnwrap(
            MobileDashboardHTTPServer.staticResourceURL(
                name: name,
                extension: fileExtension))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private func resourceJSON(
        name: String,
        extension fileExtension: String
    ) throws -> [String: Any] {
        let url = try XCTUnwrap(
            MobileDashboardHTTPServer.staticResourceURL(
                name: name,
                extension: fileExtension))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any])
    }
}
