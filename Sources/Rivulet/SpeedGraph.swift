import SwiftUI

/// A small filled line graph of recent download speed, with upload drawn as a thin line over it.
struct SpeedGraph: View {
    static let samples = 120

    let down: [Int64]
    let up: [Int64]

    var body: some View {
        Canvas { ctx, size in
            let peak = Double(max(down.max() ?? 0, up.max() ?? 0, 64 * 1024))
            func points(_ v: [Int64]) -> [CGPoint] {
                let n = max(v.count - 1, 1)
                return v.enumerated().map { i, s in
                    CGPoint(x: size.width * CGFloat(i) / CGFloat(n),
                            y: size.height - 1 - (size.height - 2) * CGFloat(Double(s) / peak))
                }
            }
            func line(_ pts: [CGPoint]) -> Path {
                var p = Path()
                guard let first = pts.first else { return p }
                p.move(to: first)
                pts.dropFirst().forEach { p.addLine(to: $0) }
                return p
            }

            let d = points(down)
            var area = line(d)
            if let last = d.last, let first = d.first {
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
            }
            ctx.fill(area, with: .color(Color.accentColor.opacity(0.22)))
            ctx.stroke(line(d), with: .color(Color.accentColor), lineWidth: 1)
            if up.contains(where: { $0 > 0 }) {
                ctx.stroke(line(points(up)), with: .color(Color.secondary.opacity(0.8)), lineWidth: 0.75)
            }
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityLabel("Transfer speed graph")
    }
}
