import SwiftUI

/// The island's silhouette: concave shoulders where it meets the screen edge
/// it is docked to, rounded corners on the side that faces the screen.
///
/// Drawn once for the top edge and turned for the others: on the left edge
/// the same outline is transposed (along-the-edge becomes vertical), on the
/// right it is transposed and mirrored. The frame is longer than the body by
/// `topRadius` at each end of the docked edge — that slack is where the
/// shoulders curve out.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var position: PanelPosition = .center

    /// Both radii morph between the closed and open outlines.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { (topRadius, bottomRadius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        switch position {
        case .center:
            return Self.topOutline(length: rect.width, depth: rect.height, top: topRadius, bottom: bottomRadius)
                .offsetBy(dx: rect.minX, dy: rect.minY)
        case .left:
            // (along, depth) → (x: depth, y: along)
            let outline = Self.topOutline(length: rect.height, depth: rect.width, top: topRadius, bottom: bottomRadius)
            return outline.applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: rect.minX, ty: rect.minY))
        case .right:
            // (along, depth) → (x: width − depth, y: along)
            let outline = Self.topOutline(length: rect.height, depth: rect.width, top: topRadius, bottom: bottomRadius)
            return outline.applying(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.maxX, ty: rect.minY))
        }
    }

    /// The outline for an island hanging from the top edge, in a box `length`
    /// along the edge and `depth` away from it.
    private static func topOutline(length: CGFloat, depth: CGFloat, top: CGFloat, bottom: CGFloat) -> Path {
        let top = min(top, depth / 2)
        let bottom = min(bottom, (depth - top) / 2, (length - 2 * top) / 2)
        let left = top
        let right = length - top

        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: left, y: top), control: CGPoint(x: left, y: 0))
        path.addLine(to: CGPoint(x: left, y: depth - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: depth), control: CGPoint(x: left, y: depth))
        path.addLine(to: CGPoint(x: right - bottom, y: depth))
        path.addQuadCurve(to: CGPoint(x: right, y: depth - bottom), control: CGPoint(x: right, y: depth))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: right, y: 0))
        path.closeSubpath()
        return path
    }
}
