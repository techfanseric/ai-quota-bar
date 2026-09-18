import Foundation

extension AppLanguage {
    func modelDisplayTabTitle() -> String {
        self == .simplifiedChinese ? "显示" : "Display"
    }
    func modelDisplayTitle() -> String {
        self == .simplifiedChinese ? "模型与额度显示" : "Models & quota display"
    }
    func modelDisplayManageTitle() -> String {
        self == .simplifiedChinese ? "调整显示内容…" : "Customize display…"
    }
}
