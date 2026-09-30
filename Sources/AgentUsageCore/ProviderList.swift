import Foundation

/// Display order for the five providers. Disabled accounts keep their place in the full order.
public enum ProviderList {
    public static func normalizedOrder(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in raw.split(separator: ",").map(String.init) where ProviderID.all.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        for id in ProviderID.all where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    /// `enabledRaw == nil` means every provider. An empty string means none.
    public static func enabled(order: [String], enabledRaw: String?) -> [String] {
        let order = normalizedOrder(order.joined(separator: ","))
        guard let enabledRaw else { return order }
        let allowed = Set(enabledRaw.split(separator: ",").map(String.init))
        return order.filter { allowed.contains($0) }
    }

    /// Writes `visible` into the slots those ids already occupy, leaving everyone else put.
    public static func applyVisible(_ visible: [String], to full: [String]) -> [String] {
        let full = normalizedOrder(full.joined(separator: ","))
        var seen = Set<String>()
        let visible = visible.filter { ProviderID.all.contains($0) && seen.insert($0).inserted && full.contains($0) }
        let set = Set(visible)
        let slots = full.indices.filter { set.contains(full[$0]) }
        guard slots.count == visible.count else { return full }
        var result = full
        for (slot, id) in zip(slots, visible) {
            result[slot] = id
        }
        return result
    }

    public static func moved(_ ids: [String], from index: Int, by delta: Int) -> [String] {
        var ids = normalizedOrder(ids.joined(separator: ","))
        let target = index + delta
        guard ids.indices.contains(index), ids.indices.contains(target) else { return ids }
        let id = ids.remove(at: index)
        ids.insert(id, at: target)
        return ids
    }
}
