// Writes MyHub's app icon as .icns through ImageIO — no iconset folder, no
// iconutil.
//
//   swift Scripts/make-icon.swift [Resources/AppIcon.icns] [Resources/logo.png]
//
// With a logo image, that artwork is used: scaled into the 824-unit body
// macOS icons occupy, with transparent margins, so it matches the size of
// other apps' icons. Without one, the fallback below is drawn.
//
// The picture: a dark rounded tile, the black island hanging from its top
// edge, and three meters at different levels.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let destinationPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let logoPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/logo.png"
let logo: CGImage? = CGImageSourceCreateWithURL(URL(fileURLWithPath: logoPath) as CFURL, nil)
    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws on a 1024-unit canvas scaled to `pixels`, y pointing up.
func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high

    if let logo {
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.3))
        ctx.draw(logo, in: body)
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    // Tile — inset to the 824-unit body macOS icons use, lifted by a shadow.
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0x171A21))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let shade = CGGradient(colorsSpace: space, colors: [rgb(0x2B2E3A), rgb(0x0D0F14)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 512, y: tileRect.maxY), end: CGPoint(x: 512, y: tileRect.minY), options: [])

    // Island: flares into the top edge, rounded where it ends.
    let edge = tileRect.maxY, half: CGFloat = 200, drop: CGFloat = 150, flare: CGFloat = 30, round: CGFloat = 74
    let island = CGMutablePath()
    island.move(to: CGPoint(x: 512 - half - flare, y: edge))
    island.addQuadCurve(to: CGPoint(x: 512 - half, y: edge - flare), control: CGPoint(x: 512 - half, y: edge))
    island.addArc(tangent1End: CGPoint(x: 512 - half, y: edge - drop), tangent2End: CGPoint(x: 512, y: edge - drop), radius: round)
    island.addArc(tangent1End: CGPoint(x: 512 + half, y: edge - drop), tangent2End: CGPoint(x: 512 + half, y: edge), radius: round)
    island.addLine(to: CGPoint(x: 512 + half, y: edge - flare))
    island.addQuadCurve(to: CGPoint(x: 512 + half + flare, y: edge), control: CGPoint(x: 512 + half, y: edge))
    island.closeSubpath()
    ctx.addPath(island)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()

    // Meters: full-width track, coloured fill at three levels.
    let meters: [(level: CGFloat, color: UInt32)] = [(0.78, 0x59D98C), (0.52, 0xFFBF4D), (0.30, 0xFF736B)]
    for (row, meter) in meters.enumerated() {
        let track = CGRect(x: 250, y: 548 - CGFloat(row) * 118, width: 524, height: 58)
        var filled = track
        filled.size.width *= meter.level
        for (rect, color) in [(track, rgb(0xFFFFFF, 0.10)), (filled, rgb(meter.color))] {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 29, cornerHeight: 29, transform: nil))
            ctx.setFillColor(color)
            ctx.fillPath()
        }
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

// Each point size at 1x and 2x; ImageIO tells them apart by DPI.
let variants = [16, 32, 128, 256, 512].flatMap { points in [(points, 1), (points, 2)] }
let url = URL(fileURLWithPath: destinationPath)
guard let icns = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, variants.count, nil) else {
    fatalError("ImageIO cannot write .icns here")
}
for (points, scale) in variants {
    let dpi = 72 * scale
    let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(icns, render(pixels: points * scale), properties)
}
guard CGImageDestinationFinalize(icns) else { fatalError("could not write \(destinationPath)") }

print("wrote \(destinationPath)")
