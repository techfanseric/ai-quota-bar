import Foundation

extension AppLanguage {
    var lightweightModeTitle: String {
        self == .simplifiedChinese ? "轻量模式" : "Lightweight mode"
    }

    var lightweightModeDescription: String {
        self == .simplifiedChinese
            ? "默认开启。界面关闭 1 分钟后释放，下次点击重建；额度环、模型流光与后台功能继续运行。未保存的临时输入可能清空。"
            : "On by default. Releases closed interfaces after one minute and rebuilds them on click. Quota rings, model activity and background services keep running. Unsaved temporary input may be cleared."
    }
}
