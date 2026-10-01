import AppKit
import QuickLookThumbnailing

/// QuickLook previews as `Sendable` values. QuickLook calls back on its own
/// queue; only a `CGImage` and its point size cross back to the main actor —
/// `NSImage` is not `Sendable` and is built on the receiving side.
enum ThumbnailLoader {
    struct Thumbnail: Sendable {
        let image: CGImage
        let size: CGSize
    }

    static func thumbnail(for url: URL, side: CGFloat, scale: CGFloat = 2) async -> Thumbnail? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            // Explicitly @Sendable: this closure runs on QuickLook's queue and
            // must not inherit any actor isolation from its surroundings.
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { @Sendable representation, _ in
                let result = representation.map { Thumbnail(image: $0.cgImage, size: $0.nsImage.size) }
                continuation.resume(returning: result)
            }
        }
    }
}
