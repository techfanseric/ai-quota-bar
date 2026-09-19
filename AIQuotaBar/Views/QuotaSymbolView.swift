import AppKit
import SwiftUI

/// SwiftUI surfaces share the menu-bar renderer, including appearance changes.
struct QuotaSymbolView: NSViewRepresentable {
    let provider: UsageProvider
    let remainingPercent: Double?
    var lowQuota = false

    func makeNSView(context: Context) -> SymbolView { SymbolView() }
    func updateNSView(_ view: SymbolView, context: Context) {
        switch provider {
        case .codex: view.initial = "C"
        case .kimi: view.initial = "K"
        case .miniMax: view.initial = "M"
        case .glm: view.initial = "G"
        }
        view.remaining = remainingPercent.map { $0 / 100 }
        view.lowQuota = lowQuota
        view.needsDisplay = true
    }
    final class SymbolView: NSView {
        var initial = "A"
        var remaining: Double?
        var lowQuota = false
        override func draw(_ dirtyRect: NSRect) {
            QuotaSymbolRenderer.draw(in: bounds, initial: initial, remaining: remaining,
                                     signedFill: nil, lowQuota: lowQuota)
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}
