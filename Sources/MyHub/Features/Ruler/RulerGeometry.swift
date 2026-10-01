import CoreGraphics
import Foundation

/// The arithmetic behind the screen ruler, kept apart from drawing so it can
/// be tested.
enum RulerGeometry {
    /// The rectangle spanned by a drag, whichever way it went, snapped to
    /// whole points.
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let minX = min(start.x, end.x).rounded(), minY = min(start.y, end.y).rounded()
        let maxX = max(start.x, end.x).rounded(), maxY = max(start.y, end.y).rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// "320 × 48 pt", plus pixels on a Retina display: "320 × 48 pt · 640 × 96 px".
    static func label(for rect: CGRect, scale: CGFloat) -> String {
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
        guard scale > 1 else { return "\(w) × \(h) pt" }
        return "\(w) × \(h) pt · \(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded())) px"
    }

    /// Text for the clipboard: "320×48".
    static func copyText(for rect: CGRect) -> String {
        "\(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))"
    }

    /// A point in a view whose origin is bottom-left, as a pixel in a
    /// screenshot of the same screen (origin top-left).
    static func pixel(for point: CGPoint, viewHeight: CGFloat, scale: CGFloat) -> (x: Int, y: Int) {
        (Int((point.x * scale).rounded(.down)), Int(((viewHeight - point.y) * scale).rounded(.down)))
    }

    /// The square of pixels the loupe magnifies, centred on `pixel` and kept
    /// inside the image.
    static func loupeRegion(around pixel: (x: Int, y: Int), radius: Int, imageSize: (width: Int, height: Int)) -> CGRect {
        let side = radius * 2 + 1
        let x = min(max(0, pixel.x - radius), max(0, imageSize.width - side))
        let y = min(max(0, pixel.y - radius), max(0, imageSize.height - side))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// "#1A2B3C" from 8-bit components.
    static func hex(red: UInt8, green: UInt8, blue: UInt8) -> String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Where to put a label box of `size` next to `point` so it stays on
    /// screen: below-right by default, flipped when it would overflow.
    static func labelOrigin(near point: CGPoint, size: CGSize, bounds: CGRect, offset: CGFloat = 14) -> CGPoint {
        var x = point.x + offset
        var y = point.y - offset - size.height
        if x + size.width > bounds.maxX { x = point.x - offset - size.width }
        if y < bounds.minY { y = point.y + offset }
        return CGPoint(x: max(bounds.minX, x), y: min(bounds.maxY - size.height, y))
    }
}
