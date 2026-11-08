import Foundation

/// Helpers for the torrent piece map and availability readout.
public enum PieceMap {
    /// Reads aria2's hex bitfield into one Bool per piece.
    public static func bits(_ hex: String, pieces: Int) -> [Bool] {
        var out: [Bool] = []
        out.reserveCapacity(pieces)
        for ch in hex {
            guard let v = ch.hexDigitValue else { continue }
            for shift in stride(from: 3, through: 0, by: -1) {
                if out.count == pieces { return out }
                out.append((v >> shift) & 1 == 1)
            }
        }
        while out.count < pieces { out.append(false) }
        return out
    }

    /// Collapses the piece bitfield into `count` cells, each holding the fraction of its pieces that are present.
    public static func cells(bitfield: String?, pieces: Int, count: Int) -> [Double] {
        guard let bitfield, pieces > 0, count > 0 else { return [] }
        let have = bits(bitfield, pieces: pieces)
        let n = min(count, pieces)
        return (0..<n).map { i in
            let lo = i * pieces / n
            let hi = max(lo + 1, (i + 1) * pieces / n)
            let slice = have[lo..<min(hi, pieces)]
            return Double(slice.filter { $0 }.count) / Double(slice.count)
        }
    }

    /// Fraction of pieces that exist either locally or on at least one connected peer, and the
    /// minimum number of copies of the rarest piece (a whole number of full copies plus a fraction).
    public static func availability(own: String?, peers: [String], pieces: Int) -> (reachable: Double, copies: Double) {
        guard pieces > 0 else { return (0, 0) }
        var counts = [Int](repeating: 0, count: pieces)
        for hex in peers + [own ?? ""] {
            let b = bits(hex, pieces: pieces)
            for i in 0..<pieces where b[i] { counts[i] += 1 }
        }
        let reachable = Double(counts.filter { $0 > 0 }.count) / Double(pieces)
        let minCount = counts.min() ?? 0
        let atMin = counts.filter { $0 == minCount }.count
        let copies = Double(minCount) + (1 - Double(atMin) / Double(pieces))
        return (reachable, copies)
    }
}
