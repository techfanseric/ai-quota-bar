import Foundation

/// 右键面板「Codex 账号」分区与账号切换服务的全部文案。
extension AppLanguage {
    // MARK: - 配额行

    /// 行内紧凑摘要（备份行文字区约 120pt，必须最短）：
    /// 英文「5h 68%→16:41 · wk 41%→09/29」，中文「5h 68%→16:41 · 周 41%→09/29」。
    /// 极端情况下由 minimumScaleFactor 收缩，不允许省略号。
    func codexAccountsQuotaShort(percent: Int, resetText: String) -> String {
        switch self {
        case .english: return "5h \(percent)%→\(resetText)"
        case .simplifiedChinese: return "5h \(percent)%→\(resetText)"
        }
    }

    func codexAccountsQuotaWeekly(percent: Int, resetText: String) -> String {
        switch self {
        case .english: return "wk \(percent)%→\(resetText)"
        case .simplifiedChinese: return "周 \(percent)%→\(resetText)"
        }
    }

    func codexAccountsQuotaSeparator() -> String {
        switch self {
        case .english: return " · "
        case .simplifiedChinese: return " · "
        }
    }

    /// 行内紧凑摘要里「明天」的前缀（悬停提示里有完整日期）。
    func codexAccountsTomorrowPrefix() -> String {
        switch self {
        case .english: return "tmr "
        case .simplifiedChinese: return "明天 "
        }
    }

    /// 悬停提示用完整表述：「5h 68%，resets 16:31；Weekly 41%，resets 09/28 14:00（captured 13:20）」。
    func codexAccountsQuotaDetail(
        shortRemaining: Int,
        shortReset: String,
        longRemaining: Int?,
        longReset: String?,
        capturedAt: String
    ) -> String {
        switch self {
        case .english:
            var parts = ["5h \(shortRemaining)% resets \(shortReset)"]
            if let longRemaining, let longReset {
                parts.append("Weekly \(longRemaining)% resets \(longReset)")
            }
            return parts.joined(separator: "; ") + " · captured " + capturedAt
        case .simplifiedChinese:
            var parts = ["5h 剩 \(shortRemaining)%，\(shortReset) 重置"]
            if let longRemaining, let longReset {
                parts.append("周 剩 \(longRemaining)%，\(longReset) 重置")
            }
            return parts.joined(separator: "；") + "（抓取于 \(capturedAt)）"
        }
    }

    func codexAccountsQuotaCapturedAt(_ text: String) -> String {
        switch self {
        case .english: return "Quota captured %@".replacingOccurrences(of: "%@", with: text)
        case .simplifiedChinese: return "配额抓取于 %@".replacingOccurrences(of: "%@", with: text)
        }
    }

    // MARK: - 分区 UI（原有文案）

    func codexAccountsSectionTitle() -> String {
        switch self {
        case .english: return "Codex accounts"
        case .simplifiedChinese: return "Codex 账号"
        }
    }

    func codexAccountsCurrentBadge() -> String {
        switch self {
        case .english: return "Current"
        case .simplifiedChinese: return "当前"
        }
    }

    func codexAccountsNotLoggedIn() -> String {
        switch self {
        case .english: return "Not logged in"
        case .simplifiedChinese: return "未登录"
        }
    }

    func codexAccountsAPIKeyMode() -> String {
        switch self {
        case .english: return "API key mode"
        case .simplifiedChinese: return "API Key 模式"
        }
    }

    func codexAccountsUnrecognizedFile() -> String {
        switch self {
        case .english: return "Unrecognized"
        case .simplifiedChinese: return "无法识别"
        }
    }

    func codexAccountsSwitchButtonTitle() -> String {
        switch self {
        case .english: return "Switch"
        case .simplifiedChinese: return "切换"
        }
    }

    func codexAccountsLoginNewButtonTitle() -> String {
        switch self {
        case .english: return "Log in a new account"
        case .simplifiedChinese: return "登录新账号"
        }
    }

    func codexAccountsCancelButtonTitle() -> String {
        switch self {
        case .english: return "Cancel"
        case .simplifiedChinese: return "取消"
        }
    }

    func codexAccountsRenameAccessibilityLabel() -> String {
        switch self {
        case .english: return "Rename account backup"
        case .simplifiedChinese: return "重命名账号备份"
        }
    }

    func codexAccountsDeleteAccessibilityLabel() -> String {
        switch self {
        case .english: return "Delete account backup"
        case .simplifiedChinese: return "删除账号备份"
        }
    }

    func codexAccountsRenamePlaceholder() -> String {
        switch self {
        case .english: return "Account name"
        case .simplifiedChinese: return "账号名称"
        }
    }

    func codexAccountsDeleteConfirmationTitle(_ label: String) -> String {
        switch self {
        case .english: return "Delete backup “\(label)”?"
        case .simplifiedChinese: return "删除备份“\(label)”？"
        }
    }

    func codexAccountsDeleteConfirmationMessage() -> String {
        switch self {
        case .english:
            return "The backup moves to the Trash. Switching back to this account later requires logging in again."
        case .simplifiedChinese:
            return "备份会移到废纸篓；之后想切回该账号需要重新登录。"
        }
    }

    func codexAccountsDeleteConfirmationButton() -> String {
        switch self {
        case .english: return "Delete"
        case .simplifiedChinese: return "删除"
        }
    }

    func codexAccountsLegacyImportTitle(_ fileName: String) -> String {
        switch self {
        case .english: return "Found legacy backup \(fileName)"
        case .simplifiedChinese: return "发现旧备份 \(fileName)"
        }
    }

    func codexAccountsLegacyImportButton() -> String {
        switch self {
        case .english: return "Import"
        case .simplifiedChinese: return "导入"
        }
    }

    func codexAccountsRefreshAccessibilityLabel() -> String {
        switch self {
        case .english: return "Refresh accounts"
        case .simplifiedChinese: return "刷新账号列表"
        }
    }

    /// 等待用户自行退出时的横幅文案；不代劳退出，只提示自动接力的条件。
    func codexAccountsPendingBanner(desktopAppRunning: Bool, cliRunning: Bool) -> String {
        switch self {
        case .english:
            switch (desktopAppRunning, cliRunning) {
            case (true, true):
                return "Quit ChatGPT and the codex CLI — the switch finishes automatically."
            case (true, false):
                return "Quit ChatGPT — the switch finishes automatically."
            case (false, true):
                return "Quit the running codex CLI — the switch finishes automatically."
            case (false, false):
                return "Finishing automatically…"
            }
        case .simplifiedChinese:
            switch (desktopAppRunning, cliRunning) {
            case (true, true):
                return "退出 ChatGPT 和 codex 命令行后将自动完成切换"
            case (true, false):
                return "退出 ChatGPT 后将自动完成切换"
            case (false, true):
                return "退出正在运行的 codex 命令行后将自动完成切换"
            case (false, false):
                return "正在自动完成切换…"
            }
        }
    }

    // MARK: - 通知

    func codexAccountsSwitchNotificationTitle() -> String {
        switch self {
        case .english: return "Codex account switched"
        case .simplifiedChinese: return "Codex 账号已切换"
        }
    }

    func codexAccountsSwitchNotificationBody(_ label: String) -> String {
        switch self {
        case .english: return "Now using %@. Opening ChatGPT for you.".replacingOccurrences(of: "%@", with: label)
        case .simplifiedChinese: return "当前账号：%@，正在为你打开 ChatGPT。".replacingOccurrences(of: "%@", with: label)
        }
    }

    func codexAccountsLoginNewNotificationTitle() -> String {
        switch self {
        case .english: return "Ready for a new Codex login"
        case .simplifiedChinese: return "可以登录新的 Codex 账号了"
        }
    }

    func codexAccountsLoginNewNotificationBody(previousLabel: String?) -> String {
        switch self {
        case .english:
            if let previousLabel {
                return "Previous account %@ is saved in the pool. Log in inside ChatGPT."
                    .replacingOccurrences(of: "%@", with: previousLabel)
            }
            return "Log in inside ChatGPT; the new account becomes the current one."
        case .simplifiedChinese:
            if let previousLabel {
                return "原账号 %@ 已存入账号池，请在 ChatGPT 中登录新账号。"
                    .replacingOccurrences(of: "%@", with: previousLabel)
            }
            return "请在 ChatGPT 中登录新账号，登录后即成为当前账号。"
        }
    }

    // MARK: - 面板状态行

    func codexAccountsStatusSwitched(_ label: String) -> String {
        switch self {
        case .english: return "Switched to %@.".replacingOccurrences(of: "%@", with: label)
        case .simplifiedChinese: return "已切换到 %@。".replacingOccurrences(of: "%@", with: label)
        }
    }

    func codexAccountsStatusSwitchFailed(_ label: String, _ reason: String) -> String {
        switch self {
        case .english: return "Could not switch to \(label): \(reason)"
        case .simplifiedChinese: return "切换到 \(label) 失败：\(reason)"
        }
    }

    func codexAccountsStatusAlreadyCurrent(_ label: String) -> String {
        switch self {
        case .english: return "%@ is already the active account.".replacingOccurrences(of: "%@", with: label)
        case .simplifiedChinese: return "%@ 已经是当前账号。".replacingOccurrences(of: "%@", with: label)
        }
    }

    func codexAccountsStatusStashed(_ label: String) -> String {
        switch self {
        case .english: return "Saved %@ to the account pool.".replacingOccurrences(of: "%@", with: label)
        case .simplifiedChinese: return "已将 %@ 存入账号池。".replacingOccurrences(of: "%@", with: label)
        }
    }

    func codexAccountsStatusPendingCancelled() -> String {
        switch self {
        case .english: return "Switch cancelled."
        case .simplifiedChinese: return "已取消切换。"
        }
    }

    func codexAccountsStatusImported(_ label: String) -> String {
        switch self {
        case .english: return "Imported %@.".replacingOccurrences(of: "%@", with: label)
        case .simplifiedChinese: return "已导入 %@。".replacingOccurrences(of: "%@", with: label)
        }
    }

    func codexAccountsStatusImportAlreadyInPool(_ label: String) -> String {
        switch self {
        case .english: return "This account is already in the pool as %@."
            .replacingOccurrences(of: "%@", with: label)
        case .simplifiedChinese: return "该账号已在账号池中（%@），未重复导入。"
            .replacingOccurrences(of: "%@", with: label)
        }
    }

    func codexAccountsStatusImportNotLoggedIn() -> String {
        switch self {
        case .english: return "That file is not a logged-in auth backup."
        case .simplifiedChinese: return "该文件不是已登录的 auth 备份。"
        }
    }

    func codexAccountsStatusRenamed() -> String {
        switch self {
        case .english: return "Backup renamed."
        case .simplifiedChinese: return "备份已重命名。"
        }
    }

    func codexAccountsStatusDeleted(_ label: String) -> String {
        switch self {
        case .english: return "Deleted backup %@.".replacingOccurrences(of: "%@", with: label)
        case .simplifiedChinese: return "已删除备份 %@。".replacingOccurrences(of: "%@", with: label)
        }
    }

    func codexAccountsStatusTargetMissing(_ label: String) -> String {
        switch self {
        case .english: return "Backup %@ no longer exists.".replacingOccurrences(of: "%@", with: label)
        case .simplifiedChinese: return "备份 %@ 已不存在。".replacingOccurrences(of: "%@", with: label)
        }
    }

    func codexAccountsStatusOperationFailed(_ reason: String) -> String {
        switch self {
        case .english: return "Operation failed: %@".replacingOccurrences(of: "%@", with: reason)
        case .simplifiedChinese: return "操作失败：%@".replacingOccurrences(of: "%@", with: reason)
        }
    }
}
