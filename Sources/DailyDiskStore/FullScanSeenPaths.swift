/// Sparse exact bitmap: storage depends on populated chunks, never maximum inode/path ID.
/// The payload cap is explicit; overflow aborts without advancing the baseline.
struct W6SeenPaths: Sendable {
    private var chunks: [Int64: [UInt64]] = [:]
    var allocatedBytes: Int { chunks.count * 512 }
    mutating func insert(_ id: Int64) throws {
        guard id > 0 else { throw StoreInvariantError.corruptStoredValue("W6 seen path ID") }
        let chunk = id >> 12
        let word = Int((id & 4095) >> 6)
        if chunks[chunk] == nil {
            guard chunks.count < 131072 else { throw StoreInvariantError.corruptStoredValue("W6 seen bitmap limit") }
            chunks[chunk] = Array(repeating: 0, count: 64)
        }
        chunks[chunk]![word] |= UInt64(1) << UInt64(id & 63)
    }
    func contains(_ id: Int64) -> Bool {
        guard id > 0, let words = chunks[id >> 12] else { return false }
        return words[Int((id & 4095) >> 6)] & (UInt64(1) << UInt64(id & 63)) != 0
    }
}
