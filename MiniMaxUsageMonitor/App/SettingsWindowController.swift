import AppKit
import SwiftUI
import Combine

final class SettingsWindowController: NSWindowController {
    private let windowWidth: CGFloat = 700
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: UsageViewModel) {
        let hostingController = NSHostingController(
            rootView: SettingsView(viewModel: viewModel, onPreferredHeightChange: nil)
        )

        let window = NSWindow(contentViewController: hostingController)
        window.title = viewModel.appLanguage.text(.preferences)
        window.setContentSize(NSSize(width: windowWidth, height: 520))
        window.minSize = NSSize(width: windowWidth, height: 420)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        hostingController.rootView = SettingsView(
            viewModel: viewModel,
            onPreferredHeightChange: { [weak self] preferredHeight in
                self?.updateWindowHeight(preferredHeight)
            }
        )

        viewModel.$appLanguage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] language in
                self?.window?.title = language.text(.preferences)
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateWindowHeight(_ preferredHeight: CGFloat) {
        guard let window else { return }

        let clampedHeight = max(420, min(preferredHeight, 760))
        let contentSize = NSSize(width: windowWidth, height: clampedHeight)
        guard abs(window.frame.height - window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).height) > 1 else {
            return
        }

        var frame = window.frame
        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin.y += frame.height - targetFrame.height
        frame.size = targetFrame.size
        window.setFrame(frame, display: true, animate: true)
    }
}
