import Foundation

public enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()

    public static func bytes(_ n: Int64) -> String {
        if n <= 0 { return "0 KB" }
        return byteFormatter.string(fromByteCount: n)
    }

    public static func speed(_ n: Int64) -> String {
        "\(bytes(n))/s"
    }

    public static func percent(_ f: Double) -> String {
        let p = f * 100
        if p >= 100 { return "100%" }
        if p == 0 { return "0%" }
        return String(format: "%.2f%%", floor(p * 100) / 100)
    }

    public static func ratio(_ r: Double) -> String {
        r <= 0 ? "0.00" : String(format: "%.2f", r)
    }

    /// Transmission style: "3 hr 20 min remaining".
    public static func eta(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s.isFinite else { return "remaining time unknown" }
        let total = Int(s.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        var parts: [String] = []
        if days > 0 { parts = ["\(days) day", hours > 0 ? "\(hours) hr" : ""] }
        else if hours > 0 { parts = ["\(hours) hr", minutes > 0 ? "\(minutes) min" : ""] }
        else if minutes > 0 { parts = ["\(minutes) min", secs > 0 && minutes < 5 ? "\(secs) sec" : ""] }
        else { parts = ["\(max(secs, 1)) sec"] }
        return parts.filter { !$0.isEmpty }.joined(separator: " ") + " remaining"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h) hr \(m) min" }
        if m > 0 { return "\(m) min \(s) sec" }
        return "\(s) sec"
    }
}
