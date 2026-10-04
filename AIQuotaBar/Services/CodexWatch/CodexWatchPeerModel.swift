import Foundation

/// 识别「从别的 Mac 关注来的」Codex 模型。
///
/// 这条判据是权限边界的一部分，不只是显示细节：`CodexWatchProjector`
/// 必须能把本机自己的账号与转发来的账号区分开，否则一台关注了第三方的
/// 机器就能把第三方的额度再转手分享出去，而第三方从未授权过这种二次传播。
enum CodexWatchPeerModel {
    /// 关注链路写入的 detail 源前缀。
    static let sourcePrefix = "Peer "

    static func isRelayed(_ model: ModelUsageData) -> Bool {
        guard let source = model.parsedDetail.source else { return false }
        return source.hasPrefix(sourcePrefix)
    }
}
