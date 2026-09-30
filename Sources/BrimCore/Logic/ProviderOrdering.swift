import Foundation

/// The order the notch draws providers in, as the user arranged it.
public enum ProviderOrdering {
    /// `ids` sorted by where each appears in `order`. Anything the order does
    /// not mention keeps its relative position after everything it does.
    public static func apply(order: [String], to ids: [String]) -> [String] {
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        return ids.enumerated().sorted { a, b in
            switch (rank[a.element], rank[b.element]) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// A provider switched back on joins the end rather than reclaiming an old
    /// place, so nothing that was hidden jumps ahead of what is on screen.
    public static func enabling(_ id: String, in order: [String]) -> [String] {
        order.filter { $0 != id } + [id]
    }

    /// Moves the items at `offsets` to before `destination`, the way a list
    /// reorder reports it.
    public static func move(_ order: [String], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [String] {
        let moving = offsets.sorted().compactMap { order.indices.contains($0) ? order[$0] : nil }
        var remaining: [String] = []
        var insertAt = destination
        for (index, id) in order.enumerated() {
            if offsets.contains(index) {
                if index < destination { insertAt -= 1 }
            } else {
                remaining.append(id)
            }
        }
        insertAt = min(max(insertAt, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
    }

    /// Drops duplicates, keeping the first occurrence.
    public static func deduplicated(_ order: [String]) -> [String] {
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }
    }
}
