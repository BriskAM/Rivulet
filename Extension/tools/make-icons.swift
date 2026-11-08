// Rasterizes the Rivulet icon (same geometry as src/icons/icon.svg) to PNG.
// Usage: swift tools/make-icons.swift src/icons
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "src/icons"

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let s = CGFloat(size) / 24.0
    // Flip to SVG-style coordinates (origin top-left), scaled to the 24 unit grid.
    cg.translateBy(x: 0, y: CGFloat(size))
    cg.scaleBy(x: s, y: -s)

    let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 24, height: 24),
                      cornerWidth: 5.4, cornerHeight: 5.4, transform: nil)
    cg.addPath(tile)
    cg.setFillColor(CGColor(red: 10/255, green: 132/255, blue: 255/255, alpha: 1))
    cg.fillPath()

    cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    cg.setLineWidth(1.8)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)

    cg.move(to: CGPoint(x: 12, y: 5.5)); cg.addLine(to: CGPoint(x: 12, y: 13))
    cg.strokePath()

    cg.move(to: CGPoint(x: 8.5, y: 9.8)); cg.addLine(to: CGPoint(x: 12, y: 13.3))
    cg.addLine(to: CGPoint(x: 15.5, y: 9.8))
    cg.strokePath()

    cg.move(to: CGPoint(x: 6, y: 14))
    cg.addArc(tangent1End: CGPoint(x: 6, y: 18), tangent2End: CGPoint(x: 18, y: 18), radius: 1.6)
    cg.addArc(tangent1End: CGPoint(x: 18, y: 18), tangent2End: CGPoint(x: 18, y: 14), radius: 1.6)
    cg.addLine(to: CGPoint(x: 18, y: 14))
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 48, 128] {
    let path = "\(outDir)/icon-\(size).png"
    try! render(size: size).write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
