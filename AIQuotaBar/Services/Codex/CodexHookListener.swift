import Foundation

final class CodexHookListener {
    static let notificationName = Notification.Name(
        "com.techfanseric.aiquotabar.codex-hook"
    )

    private let center: DistributedNotificationCenter
    private let onEvent: @MainActor (CodexHookEvent) -> Void
    private var isStarted = false

    init(
        center: DistributedNotificationCenter = .default(),
        onEvent: @escaping @MainActor (CodexHookEvent) -> Void
    ) {
        self.center = center
        self.onEvent = onEvent
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        center.addObserver(
            self,
            selector: #selector(receiveNotification(_:)),
            name: Self.notificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    func stop() {
        guard isStarted else { return }
        center.removeObserver(
            self,
            name: Self.notificationName,
            object: nil
        )
        isStarted = false
    }

    @objc private func receiveNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let event = CodexHookEvent(notificationUserInfo: userInfo) else {
            return
        }
        Task { @MainActor [weak self] in
            self?.onEvent(event)
        }
    }

    deinit {
        stop()
    }
}
