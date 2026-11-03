import Foundation

public struct TimedPlacement: Identifiable {
    public var item: AgendaItem
    public var startMinute: Double
    public var endMinute: Double
    public var column: Int
    public var columns: Int
    public var id: String { item.id }
}

public enum AgendaLayout {
    public static func placements(_ items: [AgendaItem], day: Date, calendar: Calendar = .current) -> [TimedPlacement] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let values = items.filter { $0.kind == .event && $0.day == nil && $0.overlaps(DateInterval(start: start, end: end)) }
            .sorted { ($0.start ?? .distantPast, $0.id) < ($1.start ?? .distantPast, $1.id) }
        var result: [TimedPlacement] = [], group: [TimedPlacement] = [], columnEnds: [Date] = [], groupEnd = start
        func flush() {
            for var placement in group { placement.columns = columnEnds.count; result.append(placement) }
            group = []; columnEnds = []; groupEnd = start
        }
        for item in values {
            guard let begin = item.start, let finish = item.end, finish > begin else { continue }
            let clippedStart = max(start, begin), clippedEnd = min(end, finish)
            if clippedStart >= groupEnd && !group.isEmpty { flush() }
            let column = columnEnds.firstIndex { $0 <= clippedStart } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(clippedEnd) } else { columnEnds[column] = clippedEnd }
            groupEnd = max(groupEnd, clippedEnd)
            // Wall-clock components preserve the displayed hour across DST transitions.
            let components = calendar.dateComponents([.hour, .minute], from: clippedStart)
            let finishComponents = calendar.dateComponents([.hour, .minute], from: clippedEnd)
            let startMinute = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
            let endMinute = clippedEnd == end ? 1440 : Double((finishComponents.hour ?? 0) * 60 + (finishComponents.minute ?? 0))
            group.append(TimedPlacement(item: item, startMinute: startMinute, endMinute: endMinute, column: column, columns: 1))
        }
        flush(); return result
    }
    public static func conflicts(_ item: AgendaItem, among items: [AgendaItem]) -> Bool {
        guard item.kind == .event, item.day == nil, let start = item.start, let end = item.end else { return false }
        return items.contains { other in
            other.id != item.id && other.kind == .event && other.day == nil && other.response != "declined" && item.response != "declined" &&
            other.start.map { $0 < end } == true && other.end.map { $0 > start } == true
        }
    }
}
