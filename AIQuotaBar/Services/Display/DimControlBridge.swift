import Foundation

@MainActor
protocol DimControlling: AnyObject {
    var isActive: Bool { get }
    var isTransitioning: Bool { get }
    func dim()
}

extension StepAwayDimController: DimControlling {}

/// A local, dim-only control surface for automation in this login session.
/// There is deliberately no restore command: restoration remains owned by AI Quota Bar.
enum DimControlProtocol {
    static let requestName = Notification.Name(
        "com.techfanseric.aiquotabar.control.dim.request.v1")
    static let responseName = Notification.Name(
        "com.techfanseric.aiquotabar.control.dim.response.v1")
    static let requestIDKey = "requestID"
    static let successKey = "success"
    static let sourceKey = "source"
    static let settleTimeout: TimeInterval = 8
}

final class DimControlBridge {
    private let center: DistributedNotificationCenter
    private let controllerProvider: @MainActor () -> any DimControlling
    private var requestObserver: NSObjectProtocol?

    init(
        center: DistributedNotificationCenter = .default(),
        controllerProvider: @escaping @MainActor () -> any DimControlling = {
            StepAwayDimController.shared
        }
    ) {
        self.center = center
        self.controllerProvider = controllerProvider
    }

    func start() {
        guard requestObserver == nil else { return }
        requestObserver = center.addObserver(
            forName: DimControlProtocol.requestName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let requestID = notification.userInfo?[
                DimControlProtocol.requestIDKey] as? String,
                !requestID.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.handleRequest(requestID: requestID) { [weak self] success in
                    self?.center.postNotificationName(
                        DimControlProtocol.responseName,
                        object: nil,
                        userInfo: [
                            DimControlProtocol.requestIDKey: requestID,
                            DimControlProtocol.successKey: success,
                        ],
                        deliverImmediately: true
                    )
                }
            }
        }
    }

    func stop() {
        guard let requestObserver else { return }
        center.removeObserver(requestObserver)
        self.requestObserver = nil
    }

    @MainActor
    func handleRequest(
        requestID: String,
        reply: @escaping (Bool) -> Void
    ) {
        let controller = controllerProvider()
        if controller.isActive && !controller.isTransitioning {
            reply(true)
            return
        }

        controller.dim()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(
                DimControlProtocol.settleTimeout)
            while controller.isTransitioning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            reply(controller.isActive && !controller.isTransitioning)
        }
    }
}
