import AppKit
import SwiftUI

/// codexbar.app/logos 的 provider 图标（Simple Icons 风格 SVG），随包分发在 Resources/ProviderLogos/。
/// `-dark` 结尾的是白色单色版，按 template 渲染跟随菜单深浅色；品牌彩色的保持原色。
enum ProviderLogo {
    private static let cache = NSCache<NSString, NSImage>()

    /// UsageProvider 对应的 logo 文件名（不含扩展名）。
    static func assetName(for provider: UsageProvider) -> String {
        switch provider {
        case .miniMax: return "minimax"
        case .codex: return "codex-dark"
        case .glm: return "zai-dark"
        case .kimi: return "kimi"
        }
    }

    /// 单色白 logo 走 template 渲染，前景色由使用方决定。
    static func isMonochrome(assetName: String) -> Bool {
        assetName.hasSuffix("-dark")
    }

    static func image(for provider: UsageProvider) -> NSImage? {
        let name = assetName(for: provider)
        if let cached = cache.object(forKey: name as NSString) {
            return cached
        }
        guard
            let url = Bundle.module.url(
                forResource: name,
                withExtension: "svg",
                subdirectory: "ProviderLogos")
                ?? Bundle.module.url(forResource: name, withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.setName(name)
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

/// provider 品牌图标，左键菜单组名和设置侧栏共用；找不到资源时占位空白保持布局稳定。
struct ProviderLogoIcon: View {
    let provider: UsageProvider
    var pointSize: CGFloat = 12

    var body: some View {
        Group {
            if let image = ProviderLogo.image(for: provider) {
                let base = Image(nsImage: image).resizable()
                if ProviderLogo.isMonochrome(assetName: ProviderLogo.assetName(for: provider)) {
                    base.renderingMode(.template)
                } else {
                    base.renderingMode(.original)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: pointSize, height: pointSize)
    }
}
