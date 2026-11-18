import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: UsageViewModel
    private let mobileDashboardService: MobileDashboardService
    private let lightweightMode: LightweightModeController
    let selection = PreferencesSelection()
    private var savedFrame: NSRect?
    private var hostedWindow: NSWindow?
    var hasLoadedPresentation: Bool { hostedWindow != nil }

    init(
        viewModel: UsageViewModel,
        mobileDashboardService: MobileDashboardService,
        lightweightMode: LightweightModeController? = nil
    ) {
        self.viewModel = viewModel
        self.mobileDashboardService = mobileDashboardService
        self.lightweightMode = lightweightMode ?? .shared
        super.init(window: nil)
        shouldCascadeWindows = false
        if !viewModel.hasAnyCredential && !viewModel.cloudSyncEnabled {
            selection.tab = .providers
        }
        makeWindowIfNeeded()
    }

    private func makeWindowIfNeeded() {
        guard hostedWindow == nil else { return }
        let hostingController = NSHostingController(
            rootView: PreferencesView(
                viewModel: viewModel,
                mobileDashboardService: mobileDashboardService,
                selection: selection,
                lightweightMode: lightweightMode)
        )

        let size = NSSize(width: PreferencesTab.providersWidth, height: PreferencesTab.windowHeight)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = viewModel.appLanguage.text(.preferences)
        window.setContentSize(NSSize(width: PreferencesTab.providersWidth, height: PreferencesTab.windowHeight))
        window.minSize = NSSize(width: PreferencesTab.providersWidth, height: PreferencesTab.windowHeight)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        if let savedFrame { window.setFrame(savedFrame, display: false) }
        else { window.center() }
        window.delegate = self
        hostedWindow = window
        self.window = window
        lightweightMode.register("settings", isOpen: { [weak self] in
            LightweightModeController.isOpen(self?.hostedWindow)
        }, release: { [weak self] in
            guard let self else { return }
            self.savedFrame = self.hostedWindow?.frame
            self.hostedWindow?.delegate = nil
            self.hostedWindow?.contentViewController = nil
            self.hostedWindow?.contentView = nil
            self.hostedWindow?.close()
            self.window = nil
            self.hostedWindow = nil
            CodexLocalUsageModel.shared.releasePresentationCaches()
        })
    }

    override func loadWindow() { makeWindowIfNeeded() }

    override func showWindow(_ sender: Any?) {
        makeWindowIfNeeded()
        super.showWindow(sender)
        lightweightMode.didShow("settings")
    }

    func windowWillClose(_ notification: Notification) {
        savedFrame = hostedWindow?.frame
        lightweightMode.didHide("settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
