// Usage: swift Scripts/make-app-icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size, flipped: false) { rect in
        let inset = rect.width * 0.08
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
        NSGradient(colors: [NSColor(red: 0.20, green: 0.52, blue: 0.98, alpha: 1),
                            NSColor(red: 0.08, green: 0.30, blue: 0.80, alpha: 1)])!.draw(in: tile, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.46, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
