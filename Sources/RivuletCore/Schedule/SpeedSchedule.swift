import Foundation

public enum ScheduleAction: Codable, Sendable, Hashable {
    case alternateLimits
    case limits(downKBps: Int, upKBps: Int)
    case pauseAll
}

public struct ScheduleEntry: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    /// 1 = Sunday ... 7 = Saturday (Calendar weekday numbering).
    public var days: Set<Int>
    /// Minutes since midnight. If endMinute <= startMinute the window wraps past midnight
    /// (equal values mean a full 24 hours); the post-midnight part belongs to the start day.
    public var startMinute: Int
    public var endMinute: Int
    public var action: ScheduleAction
    public var enabled: Bool

    public init(id: UUID = UUID(), days: Set<Int>, startMinute: Int, endMinute: Int, action: ScheduleAction, enabled: Bool = true) {
        self.id = id
        self.days = days
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.action = action
        self.enabled = enabled
    }

    func contains(weekday: Int, minute: Int) -> Bool {
        let prev = weekday == 1 ? 7 : weekday - 1
        if startMinute < endMinute {
            return days.contains(weekday) && minute >= startMinute && minute < endMinute
        }
        if startMinute == endMinute {
            return days.contains(weekday)
        }
        return (days.contains(weekday) && minute >= startMinute) || (days.contains(prev) && minute < endMinute)
    }
}

public struct SpeedSchedule: Codable, Sendable {
    public var entries: [ScheduleEntry]

    public init(entries: [ScheduleEntry] = []) {
        self.entries = entries
    }

    /// The first enabled entry whose window contains `date` (entries earlier in the list win).
    public func active(at date: Date, calendar: Calendar = .current) -> ScheduleEntry? {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, let hour = c.hour, let minute = c.minute else { return nil }
        let m = hour * 60 + minute
        return entries.first { $0.enabled && $0.contains(weekday: weekday, minute: m) }
    }
}
