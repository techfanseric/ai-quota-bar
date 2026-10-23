import Foundation

/// 一份文件的修改时间与大小。
///
/// 取值一律走 `FileManager.attributesOfItem`，不走 `URL.resourceValues`：
///
/// **同一个 URL 实例会缓存资源值。** 在同一个 URL 上第二次调
/// `resourceValues(forKeys:)`，拿到的还是第一次的旧值——实测连续三次写入
/// 同一个文件，三次读到的 modificationDate 完全相同，而 `stat` 显示 mtime
/// 一直在变。
///
/// 这个坑对「读前读后比对 mtime/size」的撕裂防护是致命的：两次比对的是
/// 同一个缓存值，比对恒为真，防护形同虚设。`attributesOfItem` 每次都是
/// 新鲜的 stat，没有这个问题。
struct FileStamp: Equatable {
    /// 修改时间（Unix 时间戳）。
    let modification: TimeInterval
    /// 字节数。
    let size: Int

    /// 一次新鲜的 stat。文件不存在或读不到时返回 nil。
    static func of(_ url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modification = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue
        else { return nil }
        return FileStamp(modification: modification.timeIntervalSince1970, size: size)
    }

    /// 内容被改写后必然变化的版本号。
    var generation: String { "\(modification):\(size)" }
}
