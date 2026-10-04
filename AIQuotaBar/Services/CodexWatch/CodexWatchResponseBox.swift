import Foundation

/// 关注链路应答的跨线程缓存。
///
/// 授权判定与用量都在主 actor 上，而 HTTP 端点在服务自己的队列上被调用，
/// 且**不能** await（端点是同步应答的）。这里用一个最小锁盒子把两者接起来：
/// 主 actor 只负责写入快照，读取方永远拿到一份完整的一致值，
/// 不会读到「正在被改」的中间状态。
final class CodexWatchResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: CodexWatchResponse?

    var current: CodexWatchResponse? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func update(_ response: CodexWatchResponse?) {
        lock.lock()
        storage = response
        lock.unlock()
    }
}
