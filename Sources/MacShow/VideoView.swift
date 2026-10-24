import AppKit
import SwiftUI

/// Hosts the player's Metal layer, which mpv renders into.
struct VideoView: NSViewRepresentable {
    let layer: MetalLayer

    func makeNSView(context: Context) -> LayerHostView { LayerHostView(metalLayer: layer) }
    func updateNSView(_ view: LayerHostView, context: Context) {}
}

final class LayerHostView: NSView {
    private let metalLayer: MetalLayer

    init(metalLayer: MetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

/// MoltenVK sometimes sets drawableSize to 1x1 to force a present, which makes
/// the picture flicker; ignore those sizes. Same workaround as mpv and MPVKit's demo:
/// https://github.com/mpv-player/mpv/pull/13651
final class MetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
