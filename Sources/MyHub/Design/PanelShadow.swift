import AppKit
import SwiftUI

/// The open panel's drop shadow, drawn once as an image.
///
/// A SwiftUI `.shadow` is a blur over the whole outline, and it is worked out
/// again every time anything in the panel redraws: a clock ticking, a row
/// lighting up under the pointer. Measured offscreen it was more than half of
/// every frame. The open outline never changes while open, so its shadow is
/// rendered here once per size and kept; each frame then only copies pixels.
@MainActor
enum PanelShadow {
    struct Key: Hashable {
        let width: CGFloat, height: CGFloat
        let topRadius: CGFloat, bottomRadius: CGFloat
        let position: PanelPosition
        let offsetY: CGFloat
        let scale: CGFloat
    }

    static let radius: CGFloat = 25
    static let opacity: CGFloat = 0.45

    private static var cache: [Key: CGImage] = [:]

    /// Room around the outline for the blur to fade out, in points.
    static func padding(offsetY: CGFloat) -> CGFloat { radius * 3 + abs(offsetY) }

    /// The outline filled black with its shadow, on a transparent canvas that
    /// is `padding` larger on every side, so it centres on the outline.
    static func image(for key: Key) -> CGImage? {
        if let cached = cache[key] { return cached }
        let pad = padding(offsetY: key.offsetY)
        let pixelsWide = Int(((key.width + 2 * pad) * key.scale).rounded(.up))
        let pixelsHigh = Int(((key.height + 2 * pad) * key.scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw in SwiftUI's orientation (y down) and in points.
        context.translateBy(x: 0, y: CGFloat(pixelsHigh))
        context.scaleBy(x: key.scale, y: -key.scale)
        // Shadow offset and blur are given in device pixels, unaffected by the
        // transform above: a negative height moves the shadow down. Core
        // Graphics' blur is about twice SwiftUI's radius for the same look.
        context.setShadow(offset: CGSize(width: 0, height: -key.offsetY * key.scale),
                          blur: radius * 2 * key.scale,
                          color: CGColor(gray: 0, alpha: opacity))
        let outline = IslandShape(topRadius: key.topRadius, bottomRadius: key.bottomRadius, position: key.position)
            .path(in: CGRect(x: pad, y: pad, width: key.width, height: key.height))
        context.addPath(outline.cgPath)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        if cache.count > 16 { cache.removeAll() }   // sizes and displays change rarely
        cache[key] = image
        return image
    }
}

/// The cached shadow as a view, centred on the outline it belongs to.
struct PanelShadowView: View {
    let key: PanelShadow.Key

    var body: some View {
        if let image = PanelShadow.image(for: key) {
            let pad = PanelShadow.padding(offsetY: key.offsetY)
            Image(decorative: image, scale: key.scale)
                .frame(width: key.width + 2 * pad, height: key.height + 2 * pad)
                .allowsHitTesting(false)
        }
    }
}
