/// Правки осевого корабля. Место крепления — индекс между деталями (0…count).
/// Не создаёт топливо и не меняет сохранённый формат VesselDesign.
public enum VesselAssembly {
    public static var empty: VesselDesign { VesselDesign(name: "Новый корабль", parts: []) }

    @discardableResult
    public static func insert(_ part: PartID, into parts: inout [PartID], at attachment: Int) -> Int? {
        guard parts.count < VesselDesign.maxParts, (0...parts.count).contains(attachment) else { return nil }
        parts.insert(part, at: attachment)
        return attachment
    }

    /// Перенос к креплению исходного стека, включая перенос самой последней детали.
    @discardableResult
    public static func move(_ parts: inout [PartID], from source: Int, to attachment: Int) -> Int? {
        guard parts.indices.contains(source), (0...parts.count).contains(attachment) else { return nil }
        let destination = attachment > source ? attachment - 1 : attachment
        let part = parts.remove(at: source)
        parts.insert(part, at: destination)
        return destination
    }
}
