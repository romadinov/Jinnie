import AppKit
import ImageIO
import UniformTypeIdentifiers

// Draws Jinnie's app icon in Uberdoer's style: a dark tile with a blue rim, a stack of glossy cards (what Jinnie
// knows) and a brain on the front one. Usage: swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
// iOS gets the full-bleed tile (iOS masks it); macOS gets an 824 px squircle on a transparent 1024 canvas.

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// The 1024 × 1024 artwork, drawn into `ctx` inside `rect` (the tile).
func drawTile(_ ctx: CGContext, _ rect: CGRect, corner: CGFloat) {
    let s = rect.width / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
    }
    let tile = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Background: deep navy, a little lighter in the middle.
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.setFillColor(rgb(0x060A1C)); ctx.fill(rect)
    ctx.drawRadialGradient(gradient([rgb(0x16224F), rgb(0x060A1C, 0)]),
                           startCenter: CGPoint(x: rect.midX, y: rect.midY + 40 * s), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.midY + 40 * s), endRadius: 560 * s, options: [])
    // Blue rim light along the edge.
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 10 * s, dy: 10 * s), cornerWidth: corner - 10 * s, cornerHeight: corner - 10 * s, transform: nil))
    ctx.setLineWidth(5 * s)
    ctx.setStrokeColor(rgb(0x3D6BFF, 0.55))
    ctx.setShadow(offset: .zero, blur: 28 * s, color: rgb(0x3D6BFF, 0.9))
    ctx.strokePath()
    ctx.restoreGState()

    // Cards: back ones darker and lower, each tilted a little.
    let cards: [(dx: CGFloat, dy: CGFloat, top: UInt32, bottom: UInt32)] = [
        (60, -150, 0x3A2FB8, 0x241C7A),
        (40, -100, 0x4A3EE0, 0x2D2496),
        (20, -50, 0x5A55F5, 0x3530B0),
    ]
    let cardRect = r(190, 340, 640, 440)
    let cardCorner = 78 * s
    func cardPath(_ dx: CGFloat, _ dy: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: cardRect.midX + dx * s, y: cardRect.midY + dy * s)
            .rotated(by: -0.07)
            .translatedBy(x: -cardRect.midX, y: -cardRect.midY)
        return CGPath(roundedRect: cardRect, cornerWidth: cardCorner, cornerHeight: cardCorner, transform: &t)
    }
    for c in cards {
        let p = cardPath(c.dx, c.dy)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 40 * s, color: rgb(0x000000, 0.55))
        ctx.addPath(p); ctx.setFillColor(rgb(c.bottom)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(c.top), rgb(c.bottom)]), start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
                               end: CGPoint(x: cardRect.maxX, y: cardRect.minY - 150 * s), options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        ctx.addPath(p); ctx.setLineWidth(3 * s); ctx.setStrokeColor(rgb(0x9AA8FF, 0.35)); ctx.strokePath()
    }

    // Front card: bright blue to violet, glossy.
    let front = cardPath(0, 0)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 50 * s, color: rgb(0x000000, 0.6))
    ctx.addPath(front); ctx.setFillColor(rgb(0x3E7BFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(front); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x56C2FF), rgb(0x3E7BFF), rgb(0x6A4BFF)], [0, 0.5, 1]),
                           start: CGPoint(x: cardRect.minX, y: cardRect.maxY), end: CGPoint(x: cardRect.maxX, y: cardRect.minY), options: [])
    // Gloss on the upper half.
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.32), rgb(0xFFFFFF, 0.0)]),
                           start: CGPoint(x: 0, y: cardRect.maxY), end: CGPoint(x: 0, y: cardRect.midY + 20 * s), options: [])
    // A soft green-cyan glow in the top-right corner, like Uberdoer's.
    ctx.drawRadialGradient(gradient([rgb(0x6CFFD0, 0.55), rgb(0x6CFFD0, 0)]),
                           startCenter: CGPoint(x: cardRect.maxX - 70 * s, y: cardRect.maxY - 40 * s), startRadius: 0,
                           endCenter: CGPoint(x: cardRect.maxX - 70 * s, y: cardRect.maxY - 40 * s), endRadius: 190 * s, options: [])
    ctx.restoreGState()
    ctx.addPath(front); ctx.setLineWidth(4 * s); ctx.setStrokeColor(rgb(0xCFE6FF, 0.55)); ctx.strokePath()

    // The brain, white with a slight blue shade, raised off the card.
    let config = NSImage.SymbolConfiguration(pointSize: 300 * s, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "brain.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config),
       let cg = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let aspect = CGFloat(cg.width) / CGFloat(cg.height)
        let h = 380 * s, w = h * aspect
        let glyph = CGRect(x: cardRect.midX - w / 2 + 6 * s, y: cardRect.midY - h / 2 + 6 * s, width: w, height: h)
        ctx.saveGState()
        ctx.translateBy(x: glyph.midX, y: glyph.midY); ctx.rotate(by: -0.07); ctx.translateBy(x: -glyph.midX, y: -glyph.midY)
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: rgb(0x10166B, 0.7))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.clip(to: glyph, mask: cg)
        ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xD8E6FF)]), start: CGPoint(x: 0, y: glyph.maxY),
                               end: CGPoint(x: 0, y: glyph.minY), options: [])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

func render(_ size: Int, tileInset: CGFloat, corner: CGFloat, opaque: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    ctx.interpolationQuality = .high
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let S = CGFloat(size)
    let tile = CGRect(x: 0, y: 0, width: S, height: S).insetBy(dx: tileInset * S, dy: tileInset * S)
    if !opaque {
        // The macOS drop shadow under the squircle.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * S / 1024), blur: 24 * S / 1024, color: rgb(0x000000, 0.35))
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: corner * S, cornerHeight: corner * S, transform: nil))
        ctx.setFillColor(rgb(0x060A1C)); ctx.fillPath()
        ctx.restoreGState()
    }
    drawTile(ctx, tile, corner: corner * S)
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/\(name)") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

write(render(1024, tileInset: 0, corner: 0, opaque: true), "icon-1024.png")
let mac = render(1024, tileInset: 100.0 / 1024, corner: 185.0 / 1024, opaque: false)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(mac, in: CGRect(x: 0, y: 0, width: px, height: px))
    write(ctx.makeImage()!, "mac-\(px).png")
}
